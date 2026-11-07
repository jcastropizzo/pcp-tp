-module(simple_kv).
-export([start_link/2, stop/1, put/3, put/4, delete/2, get/2]).

-spec start_link(pos_integer(), pos_integer()) -> {ok, [pid()]}.
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

%% Alfa: capacidad maxima de valores por replica (4.7).
start_link(N, Alfa) when is_integer(N), N >= 1, is_integer(Alfa), Alfa >= 3 ->
    Pids = lists:map(
        fun(_) -> spawn_link(fun() -> simple_kv_replica:init() end) end,
        lists:seq(1, N)
    ),
    lists:foreach(
        fun(Pid) -> Pid ! {peers, lists:delete(Pid, Pids), Alfa} end,
        Pids
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
