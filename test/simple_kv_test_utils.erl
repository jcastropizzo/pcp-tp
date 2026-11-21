-module(simple_kv_test_utils).
-export([esperar_valor/4, iniciar/2, replicas_con_pares_controlados/3, escribir/2,
         lecturas/2, consultar_local/2, get_async/2, esperar_get/1,
         esperar_consulta/2, responder_consulta/4, esperar/1]).
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

%% Los pares controlados participan del protocolo de cupos. El test decide
%% las respuestas de lectura y puede observar las ofertas reales.
replicas_con_pares_controlados(Reales, Simulados, Alfa) ->
    Padre = self(),
    Replicas = [spawn_link(fun simple_kv_replica:init/0) || _ <- lists:seq(1, Reales)],
    Pares = [spawn_link(fun() ->
        receive {configurar, Cupos} -> par_controlado(Padre, Cupos, Alfa, #{}) end
    end) || _ <- lists:seq(1, Simulados)],
    Todos = Replicas ++ Pares,
    Cupos = spawn_link(fun() -> simple_kv_cupos:init(Todos, Alfa) end),
    lists:foreach(fun(P) -> P ! {configurar, lists:delete(P, Todos), Alfa, Cupos} end, Replicas),
    lists:foreach(fun(P) -> P ! {configurar, Cupos} end, Pares),
    {Replicas, Pares}.

par_controlado(Padre, Cupos, Alfa, Residentes) ->
    receive
        {replicar, Clave, _, Id, {_, borrado}} ->
            Bajas = [Clave || is_map_key(Clave, Residentes)],
            Cupos ! {aplicado, Id, self(), [], Bajas, []},
            par_controlado(Padre, Cupos, Alfa, maps:remove(Clave, Residentes));
        {replicar, _, _, Id, _} ->
            Cupos ! {aplicado, Id, self(), [], [], []},
            par_controlado(Padre, Cupos, Alfa, Residentes);
        {ofrecer, Clave, _, Id, Ref, Entrada} ->
            Padre ! {ofrecer, Clave, Entrada},
            Altas = [Clave || not is_map_key(Clave, Residentes), map_size(Residentes) < Alfa],
            Cupos ! {oferta_resuelta, Id, Ref, self(), Altas, []},
            Nuevos = lists:foldl(fun(K, M) -> M#{K => true} end, Residentes, Altas),
            par_controlado(Padre, Cupos, Alfa, Nuevos);
        {consultar, Rep, Ref, Clave} ->
            Padre ! {consulta, self(), Rep, Ref, Clave},
            par_controlado(Padre, Cupos, Alfa, Residentes);
        {preparar_olvido, Clave, Reserva} ->
            Cupos ! {lecturas_drenadas, Clave, Reserva, self()},
            par_controlado(Padre, Cupos, Alfa, Residentes);
        {olvidar, Clave, Reserva} ->
            Cupos ! {olvidada, Clave, Reserva, self()},
            par_controlado(Padre, Cupos, Alfa, Residentes);
        stop ->
            simple_kv_cupos:detener_replica(Cupos)
    end.

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

esperar_consulta(Par, Clave) ->
    receive
        {consulta, Par, Rep, RefConsulta, Clave} -> {Rep, RefConsulta}
    after 1000 ->
        erlang:error({sin_consulta, Clave})
    end.

responder_consulta(Rep, RefConsulta, Par, Resultado) ->
    Rep ! {respuesta_consulta, RefConsulta, Par, Resultado},
    ok.

esperar(Condicion) ->
    esperar(Condicion, erlang:monotonic_time(millisecond) + 1500).

esperar(Condicion, Plazo) ->
    case Condicion() of
        true -> ok;
        false ->
            ?assert(erlang:monotonic_time(millisecond) < Plazo),
            timer:sleep(1),
            esperar(Condicion, Plazo)
    end.
