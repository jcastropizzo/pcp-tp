-module(simple_kv).
-export([start_link/1, stop/1, put/3, put/4, delete/2, get/2]).

-spec start_link(pos_integer()) -> {ok, [pid()]}.
-spec stop([pid()]) -> ok.
-spec put(pid(), term(), term()) -> ok.
-spec put(pid(), term(), term(), non_neg_integer() | infinity) -> ok.
-spec delete(pid(), term()) -> ok.
-spec get(pid(), term()) -> {ok, term()} | not_found.

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

loop(Map) ->
    receive
        stop -> ok;
        {put, Client, Ref, Key, Val, Time} ->
            NewMap = maps:put(Key, {Val, expira(Time)}, Map),
            Client ! {Ref, ok},
            loop(NewMap);
        {delete, Client, Ref, Key} ->
            NewMap = maps:remove(Key, Map),
            Client ! {Ref, ok},
            loop(NewMap);
        {get, Client, Ref, Key} ->
            case maps:find(Key, Map) of
                {ok, {Value, Vencimiento}} ->
                case vigente(Vencimiento) of
                    true ->
                        Client ! {Ref, ok, Value};
                    false ->
                        Client ! {Ref, not_found}
                end;
                error ->
                    Client ! {Ref, not_found}
            end,
            loop(Map);
        _ ->
            loop(Map)
    end.

start_link(N) when is_integer(N), N >= 1 ->
    Pids = lists:map(
        fun(_) -> spawn_link(fun() -> loop(#{}) end) end,
        lists:seq(1, N)
    ),
    {ok, Pids}.

stop(Pids) ->
    lists:foreach(
        fun(Pid) ->
            Monitor = erlang:monitor(process, Pid),
            Pid ! stop,
            receive
                {'DOWN', Monitor, process, Pid, _Motivo} -> ok
            after 1000 -> erlang:error(timeout)
            end
        end,
        Pids
    ).

%%% ============ TTL ============

expira(infinity) -> infinity;
expira(Time) -> erlang:monotonic_time(millisecond) + Time.

vigente(infinity) -> true;
vigente(Expira) -> erlang:monotonic_time(millisecond) < Expira.