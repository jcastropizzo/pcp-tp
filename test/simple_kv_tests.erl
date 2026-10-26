-module(simple_kv_tests).
-include_lib("eunit/include/eunit.hrl").

iniciar_una_replica_escribir_y_leer_devuelve_ok_test()->
    {ok, [Pid]} = simple_kv:start_link(1),
    ok = simple_kv:put(Pid, color, rojo),
    {ok, ColorVal} = simple_kv:get(Pid, color),
    simple_kv:stop([Pid]),
    ?assertEqual(rojo, ColorVal).

iniciar_una_replica_y_leer_devuelve_not_found_test()->
    {ok, [Pid]} = simple_kv:start_link(1),
    ?assertEqual(not_found, simple_kv:get(Pid, color)),
    simple_kv:stop([Pid]).

iniciar_una_replica_escribir_leer_borrar_y_leer_devuelve_not_found_test()->
    {ok, [Pid]} = simple_kv:start_link(1),
    ok = simple_kv:put(Pid, color, rojo),
    {ok, ColorVal} = simple_kv:get(Pid, color),
    ok = simple_kv:delete(Pid, color),
    ?assertEqual(rojo, ColorVal),
    ?assertEqual(not_found, simple_kv:get(Pid, color)),
    simple_kv:stop([Pid]).