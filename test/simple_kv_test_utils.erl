-module(simple_kv_test_utils).
-export([esperar_valor/4, iniciar/2, replica_con_par_falso/1, escribir/2,
         lecturas/2, consultar_local/2, get_async/2, esperar_get/1,
         esperar_consulta/1, responder_consulta/3]).
-include_lib("eunit/include/eunit.hrl").

obtener_plazo_ms(Ms)->erlang:monotonic_time(millisecond) + Ms.

esperar_valor(Pid, Clave, Esperado, Ms) ->
    Plazo = obtener_plazo_ms(Ms),
    esperar_valor_hasta(Pid, Clave, Esperado, Plazo).

esperar_valor_hasta(Pid, Clave, Esperado, Plazo) ->
    Actual = simple_kv:get(Pid, Clave),
    case Actual =:= Esperado of
        true ->
            ok;
        false ->
            case erlang:monotonic_time(millisecond) >= Plazo of
                true ->
                    ?assertEqual(Esperado, Actual);
                false ->
                    timer:sleep(10),
                    esperar_valor_hasta(Pid, Clave, Esperado, Plazo)
            end
    end.

iniciar(N, Alfa) ->
    {ok, Pids} = simple_kv:start_link(N, Alfa),
    Pids.

%% Replica cuyo unico par es el proceso del test.
replica_con_par_falso(Alfa) ->
    Rep = spawn_link(fun simple_kv_replica:init/0),
    Rep ! {configurar, [self()], Alfa},
    Rep.

escribir(P, Claves) ->
    lists:foreach(fun(Clave) -> ok = simple_kv:put(P, Clave, Clave) end, Claves).

lecturas(P, Claves) ->
    [simple_kv:get(P, Clave) || Clave <- Claves].

consultar_local(P, Clave) ->
    Ref = make_ref(),
    P ! {consultar, self(), Ref, Clave},
    receive
        {respuesta_consulta, Ref, P, Resultado} -> Resultado
    after 1000 -> error({sin_respuesta_local, Clave})
    end.

%% El get se hace desde otro proceso: si la replica le consulta al test
%% (par falso), el test tiene que estar libre para responder.
get_async(Rep, Clave) ->
    Yo = self(),
    spawn_link(fun() -> Yo ! {resultado_get, Clave, simple_kv:get(Rep, Clave)} end),
    ok.

esperar_get(Clave) ->
    receive
        {resultado_get, Clave, Resultado} -> Resultado
    after 1000 ->
        erlang:error({get_sin_respuesta, Clave})
    end.

%% Espera el {consultar, ...} que la replica le manda al par falso.
esperar_consulta(Clave) ->
    receive
        {consultar, Rep, RefConsulta, Clave} -> {Rep, RefConsulta}
    after 1000 ->
        erlang:error({sin_consulta, Clave})
    end.

responder_consulta(Rep, RefConsulta, Resultado) ->
    Rep ! {respuesta_consulta, RefConsulta, self(), Resultado},
    ok.
