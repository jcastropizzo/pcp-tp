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

put(Pid, Key, Val, Time)
    when is_integer(Time), Time >= 0; Time =:= infinity ->
    Ref = make_ref(),
    Pid ! {put, self(), Ref, Key, Val, Time},
    receive
        {Ref, ok} -> ok
    end.

-spec loop(map()) -> no_return().

loop(Map) ->
    receive
        {put, Client, Ref, Key, Val} ->
            NewMap = maps:put(Key, Val, Map),
            Client ! {Ref, ok},
            loop(NewMap);
        {put, Client, Ref, Key, Val, _Time} ->
            NewMap = maps:put(Key, Val, Map),
            Client ! {Ref, ok},
            loop(NewMap)
    end.

start_link(1) -> 
    Pid = spawn_link(fun() -> loop(#{} ) end),
    {ok, [Pid]}.