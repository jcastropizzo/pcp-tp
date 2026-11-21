-module(simple_kv_replicacion).
-export([nueva_version/0, replicar/5, ofrecer/3, elegir_mayor/2]).

nueva_version() ->
    erlang:unique_integer([monotonic]).

%% La propagación es asincrónica: el origen no espera confirmaciones.
replicar(Pares, Clave, Reserva, Id, Entrada) ->
    lists:foreach(fun(Pid) -> Pid ! {replicar, Clave, Reserva, Id, Entrada} end, Pares).

%% El informe de aplicación incluye una referencia por destinatario.
ofrecer(_Pares, _Id, ninguna) -> [];
ofrecer(Pares, Id, {Clave, Reserva, Entrada}) ->
    lists:map(fun(Pid) ->
        Ref = make_ref(),
        Pid ! {ofrecer, Clave, Reserva, Id, Ref, Entrada},
        {Ref, Clave}
    end, Pares).

elegir_mayor(error, Otra) ->
    Otra;
elegir_mayor(Una, error) ->
    Una;
elegir_mayor({ok, {V, desalojado}}, {ok, {V, {valor, _, _}}} = Valor) ->
    Valor;
elegir_mayor({ok, {V, {valor, _, _}}} = Valor, {ok, {V, desalojado}}) ->
    Valor;
elegir_mayor({ok, {V1, _}} = Una, {ok, {V2, _}} = Otra) ->
    case V1 >= V2 of
        true -> Una;
        false -> Otra
    end.
