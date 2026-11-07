-module(simple_kv_replicacion).
-export([nueva_version/0, elegir_mayor/2, replicar_delete/3, replicar_put/3]).

nueva_version() ->
    erlang:unique_integer([monotonic]).

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

replicar_put(Peers, Key, Entry) ->
    lists:foreach(fun(Pid) -> Pid ! {replica_put, Key, Entry} end, Peers).

replicar_delete(Peers, Key, Entry) ->
    lists:foreach(fun(Pid) -> Pid ! {replica_delete, Key, Entry} end, Peers).
