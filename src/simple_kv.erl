-module(simple_kv).
-export([start_link/2, stop/1, put/3, put/4, delete/2, get/2]).

-spec start_link(pos_integer(), pos_integer()) -> {ok, [pid()]}.
-spec stop([pid()]) -> ok.
-spec put(pid(), term(), term()) -> ok.
-spec put(pid(), term(), term(), non_neg_integer() | infinity) -> ok.
-spec delete(pid(), term()) -> ok.
-spec get(pid(), term()) -> {ok, term()} | not_found.

put(Pid, Clave, Valor) ->
    put(Pid, Clave, Valor, infinity).

put(Pid, Clave, Valor, TTL) when
    is_integer(TTL), TTL >= 0; TTL =:= infinity
->
    cambiar(Pid, Clave, {put, Valor, TTL}).

get(Pid, Clave) ->
    RefCliente = make_ref(),
    Pid ! {get, self(), RefCliente, Clave},
    receive
        {RefCliente, ok, Valor} -> {ok, Valor};
        {RefCliente, not_found} -> not_found
    end.

delete(Pid, Clave) ->
    cambiar(Pid, Clave, borrado).

cambiar(Pid, Clave, Cambio) ->
    Ref = make_ref(),
    Pid ! {pedir_cupo, self(), Ref, Clave},
    receive
        {Ref, permiso, Reserva, Id} ->
            Pid ! {cambiar, self(), Ref, Clave, Reserva, Id, Cambio}
    end,
    receive {Ref, ok} -> ok end.

start_link(Cantidad, Alfa) when
    is_integer(Cantidad), Cantidad >= 1, is_integer(Alfa), Alfa >= 3
->
    Pids = lists:map(
        fun(_) -> spawn_link(fun() -> simple_kv_replica:init() end) end,
        lists:seq(1, Cantidad)
    ),
    Cupos = spawn_link(fun() -> simple_kv_cupos:init(Pids, Alfa) end),
    lists:foreach(
        fun(Pid) -> Pid ! {configurar, lists:delete(Pid, Pids), Alfa, Cupos} end,
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
            end
        end,
        Pids
    ).
