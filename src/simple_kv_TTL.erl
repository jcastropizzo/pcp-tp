-module(simple_kv).
-export([start_link/1, stop/1, put/3, put/4, delete/2, get/2]).

-spec start_link(pos_integer()) -> {ok, [pid()]}.
-spec stop([pid()]) -> ok.
-spec put(pid(), term(), term()) -> ok.
-spec put(pid(), term(), term(), non_neg_integer() | infinity) -> ok.
-spec delete(pid(), term()) -> ok.
-spec get(pid(), term()) -> {ok, term()} | not_found.

%%% ============ API (lo que usa el cliente) ============

put(A, B, C) ->
    put(A, B, C, infinity).

put(Pid, Key, Val, Time) when
    is_integer(Time), Time >= 0; Time =:= infinity
->
    Ref = make_ref(),
    Pid ! {put, self(), Ref, Key, Val, Time},
    receive
        {Ref, ok} -> ok
    end.

get(Pid, Key) ->
    Ref = make_ref(),
    Pid ! {get, self(), Ref, Key},
    receive
        {Ref, ok, Val} -> {ok, Val};
        {Ref, not_found} -> not_found
    end.

delete(Pid, Key) ->
    Ref = make_ref(),
    Pid ! {delete, self(), Ref, Key},
    receive
        {Ref, ok} -> ok
    end.

start_link(N) when is_integer(N), N >= 1 ->
    Pids = lists:map(
        fun(_) -> spawn_link(fun() -> init() end) end,
        lists:seq(1, N)
    ),
    lists:foreach(
        fun(Pid) -> Pid ! {peers, lists:delete(Pid, Pids)} end,
        Pids
    ),
    {ok, Pids}.

stop(Pids) ->
    lists:foreach(
        fun(Pid) ->
            Ref = make_ref(),
            Pid ! {stop, Ref, self()},
            receive
                {Ref, ok} -> ok
            end
        end,
        Pids
    ).

%%% ============ Réplica (el proceso) ============

init() ->
    receive
        {peers, Peers} -> loop(Peers, #{})
    end.

loop(Peers, Map) ->
    receive
        {stop, Ref, Pid} ->
            Pid ! {Ref, ok};
        {put, Client, Ref, Key, Val, Time} ->
            Entry = {nueva_version(), {value, Val, expira(Time)}},
            NewMap = maps:put(Key, Entry, Map),
            Client ! {Ref, ok},
            replicar(Peers, Key, Entry),
            loop(Peers, NewMap);
        {delete, Client, Ref, Key} ->
            Entry = {nueva_version(), tombstone},
            NewMap = maps:put(Key, Entry, Map),
            Client ! {Ref, ok},
            replicar(Peers, Key, Entry),
            loop(Peers, NewMap);
        {replica, Key, Entry} ->
            loop(Peers, merge(Key, Entry, Map));
        {get, Client, Ref, Key} ->
            case maps:find(Key, Map) of
                {ok, {_Version, {value, Value, Expira}}} ->
                    case vigente(Expira) of
                        true  -> Client ! {Ref, ok, Value};
                        false -> Client ! {Ref, not_found}
                    end;
                {ok, {_Version, tombstone}} ->
                    Client ! {Ref, not_found};
                error ->
                    Client ! {Ref, not_found}
            end,
            loop(Peers, Map);
        _ ->
            loop(Peers, Map)
    end.

%%% ============ Versiones y conflictos ============

nueva_version() ->
    erlang:unique_integer([monotonic]).

replicar(Peers, Key, Entry) ->
    lists:foreach(fun(P) -> P ! {replica, Key, Entry} end, Peers).

merge(Key, {VersionNueva, _} = Nueva, Map) ->
    case maps:find(Key, Map) of
        {ok, {VersionActual, _}} when VersionActual >= VersionNueva ->
            Map;
        _ ->
            maps:put(Key, Nueva, Map)
    end.

%%% ============ TTL ============

expira(infinity) -> infinity;
expira(Time) -> erlang:monotonic_time(millisecond) + Time.

vigente(infinity) -> true;
vigente(Expira) -> erlang:monotonic_time(millisecond) < Expira.