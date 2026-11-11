-module(simple_kv_replicacion_tests).
-include_lib("eunit/include/eunit.hrl").

elige_mayor_sin_importar_orden_test() ->
    Vieja = {ok, {3, borrado}},
    Nueva = {ok, {8, {valor, rojo, infinity}}},
    ?assertEqual(Nueva, simple_kv_replicacion:elegir_mayor(Vieja, Nueva)),
    ?assertEqual(Nueva, simple_kv_replicacion:elegir_mayor(Nueva, Vieja)).

sin_informacion_conserva_la_otra_test() ->
    Entrada = {ok, {8, borrado}},
    ?assertEqual(Entrada, simple_kv_replicacion:elegir_mayor(error, Entrada)),
    ?assertEqual(Entrada, simple_kv_replicacion:elegir_mayor(Entrada, error)).
