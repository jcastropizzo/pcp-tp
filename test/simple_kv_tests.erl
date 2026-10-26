-module(simple_kv_tests).
-include_lib("eunit/include/eunit.hrl").

iniciar_una_replica_escribir_y_leer_devuelve_ok_test()->
    {ok, [Pid]} = simple_kv:start_link(1),
    ok = simple_kv:put(Pid, color, rojo),
    {ok, ColorVal} = simple_kv:get(Pid, color),
    ?assertEqual(rojo, ColorVal),
    simple_kv:stop([Pid]).

leer_devuelve_not_found_test()->
    {ok, [Pid]} = simple_kv:start_link(1),
    ?assertEqual(not_found, simple_kv:get(Pid, color)),
    simple_kv:stop([Pid]).

escribir_con_tiempo_negativo_devuelve_error_test()->
    {ok, [Pid]} = simple_kv:start_link(1),
    ?assertError(function_clause, simple_kv:put(Pid, color, rojo, -1)),
    simple_kv:stop([Pid]).

escribir_leer_borrar_y_leer_devuelve_not_found_test()->
    {ok, [Pid]} = simple_kv:start_link(1),
    ok = simple_kv:put(Pid, color, rojo),
    ok = simple_kv:delete(Pid, color),
    ?assertEqual(not_found, simple_kv:get(Pid, color)),
    simple_kv:stop([Pid]).


borrar_clave_inexistente_devuelve_ok_test()->
    {ok, [Pid]} = simple_kv:start_link(1),
    ?assertEqual(ok, simple_kv:delete(Pid, color)),
    simple_kv:stop([Pid]).

mensaje_desconocido_es_ignorado_test()->
    {ok, [Pid]} = simple_kv:start_link(1),
    Pid ! {mensaje_desconocido123, a, 123},
    ok = simple_kv:put(Pid, color, rojo),
    {ok, ColorVal} = simple_kv:get(Pid, color),
    ?assertEqual(rojo, ColorVal),
    simple_kv:stop([Pid]).