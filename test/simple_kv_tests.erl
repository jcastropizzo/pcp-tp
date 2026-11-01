-module(simple_kv_tests).
-include_lib("eunit/include/eunit.hrl").

iniciar_una_replica_escribir_y_leer_devuelve_ok_test() ->
    {ok, [Pid]} = simple_kv:start_link(1),
    ok = simple_kv:put(Pid, color, rojo),
    {ok, ColorVal} = simple_kv:get(Pid, color),
    ?assertEqual(rojo, ColorVal),
    simple_kv:stop([Pid]).

iniciar_tres_replicas_test() ->
    {ok, Pids} = simple_kv:start_link(3),
    ?assertEqual(3, length(Pids)),
    simple_kv:stop(Pids).

iniciar_tres_replicas_devuelve_replicas_distintas_test() ->
    {ok, Pids} = simple_kv:start_link(3),
    UniquePids = lists:usort(Pids),
    ?assertEqual(3, length(Pids)),
    ?assertEqual(3, length(UniquePids)),
    ?assert(lists:all(fun(Pid) -> is_pid(Pid) andalso is_process_alive(Pid) end, Pids)),
    simple_kv:stop(Pids),
    ?assert(lists:all(fun(Pid) -> is_pid(Pid) andalso not is_process_alive(Pid) end, Pids)).

leer_devuelve_not_found_test() ->
    {ok, [Pid]} = simple_kv:start_link(1),
    ?assertEqual(not_found, simple_kv:get(Pid, color)),
    simple_kv:stop([Pid]).

escribir_con_tiempo_negativo_devuelve_error_test() ->
    {ok, [Pid]} = simple_kv:start_link(1),
    ?assertError(function_clause, simple_kv:put(Pid, color, rojo, -1)),
    simple_kv:stop([Pid]).

escribir_leer_borrar_y_leer_devuelve_not_found_test() ->
    {ok, [Pid]} = simple_kv:start_link(1),
    ok = simple_kv:put(Pid, color, rojo),
    ok = simple_kv:delete(Pid, color),
    ?assertEqual(not_found, simple_kv:get(Pid, color)),
    simple_kv:stop([Pid]).

start_link_con_numero_negativo_devuelve_error_test() ->
    ?assertError(function_clause, simple_kv:start_link(-1)).

start_link_con_cero_devuelve_error_test() ->
    ?assertError(function_clause, simple_kv:start_link(0)).

start_link_con_uno_con_decimal_devuelve_error_test() ->
    ?assertError(function_clause, simple_kv:start_link(1.0)).

borrar_clave_inexistente_devuelve_ok_test() ->
    {ok, [Pid]} = simple_kv:start_link(1),
    ?assertEqual(ok, simple_kv:delete(Pid, color)),
    simple_kv:stop([Pid]).

mensaje_desconocido_es_ignorado_test() ->
    {ok, [Pid]} = simple_kv:start_link(1),
    Pid ! {mensaje_desconocido123, a, 123},
    ok = simple_kv:put(Pid, color, rojo),
    {ok, ColorVal} = simple_kv:get(Pid, color),
    ?assertEqual(rojo, ColorVal),
    simple_kv:stop([Pid]).

ttl_cero_reemplaza_valor_anterior_test() ->
    {ok, [Pid]} = simple_kv:start_link(1),
    try
        ok = simple_kv:put(Pid, color, rojo),
        ok = simple_kv:put(Pid, color, azul, 0),
        ?assertEqual(not_found, simple_kv:get(Pid, color))
    after
        simple_kv:stop([Pid])
    end.