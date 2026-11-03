-module(simple_kv_replicacion_tests).
-include_lib("eunit/include/eunit.hrl").

elige_mayor_sin_importar_orden_test() ->
    Vieja = {ok, {3, borrado}},
    Nueva = {ok, {8, {value, rojo, infinity}}},
    ?assertEqual(Nueva, simple_kv_replicacion:elegir_mayor(Vieja, Nueva)),
    ?assertEqual(Nueva, simple_kv_replicacion:elegir_mayor(Nueva, Vieja)).

sin_informacion_conserva_la_otra_test() ->
    Entry = {ok, {8, borrado}},
    ?assertEqual(Entry, simple_kv_replicacion:elegir_mayor(error, Entry)),
    ?assertEqual(Entry, simple_kv_replicacion:elegir_mayor(Entry, error)).

versiones_sucesivas_crecientes_test() ->
    Primera = simple_kv_replicacion:nueva_version(),
    Segunda = simple_kv_replicacion:nueva_version(),
    ?assert(Segunda > Primera).
