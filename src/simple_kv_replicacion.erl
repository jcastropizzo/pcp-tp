-module(simple_kv_replicacion).
-export([nueva_version/0, replicar/3, elegir_mayor/2]).

nueva_version() ->
    erlang:unique_integer([monotonic]).

replicar(Peers, Key, Entry) ->
    lists:foreach(fun(Pid) -> Pid ! {replica, Key, Entry} end, Peers).

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
