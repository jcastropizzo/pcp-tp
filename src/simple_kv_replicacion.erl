-module(simple_kv_replicacion).
-export([nueva_version/0, replicar/3, ofrecer/3, elegir_mayor/2]).

nueva_version() ->
    erlang:unique_integer([monotonic]).

%% Propaga un cambio (put o delete) a todas las demas replicas. No espera respuesta.
replicar(Peers, Key, Entry) ->
    lists:foreach(fun(Pid) -> Pid ! {replica, Key, Entry} end, Peers).

%% Antes de desalojar un valor vigente, se lo ofrece a las demas replicas (4.7).
%% No espera respuesta: quien lo recibe decide si lo guarda.
ofrecer(Peers, Key, Entry) ->
    lists:foreach(fun(Pid) -> Pid ! {ofrecer, Key, Entry} end, Peers).

elegir_mayor(error, Otra) ->
    Otra;
elegir_mayor(Una, error) ->
    Una;
elegir_mayor({ok, {V, desalojado}}, {ok, {V, {value, _, _}}} = Valor) ->
    Valor;
elegir_mayor({ok, {V, {value, _, _}}} = Valor, {ok, {V, desalojado}}) ->
    Valor;
elegir_mayor({ok, {V1, _}} = Una, {ok, {V2, _}} = Otra) ->
    case V1 >= V2 of
        true -> Una;
        false -> Otra
    end.
