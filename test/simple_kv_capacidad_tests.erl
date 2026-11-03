-module(simple_kv_capacidad_tests).
-include_lib("eunit/include/eunit.hrl").

candidato_a_desalojar_mapa_vacio_no_tiene_candidato_test() ->
    ?assertEqual(ninguno, simple_kv_capacidad:candidato_a_desalojar(#{})).

candidato_a_desalojar_clave_ninguno_es_un_candidato_valido_test() ->
    Entry = {42, {value, rojo, infinity}},
    ?assertEqual(
        {ninguno, Entry},
        simple_kv_capacidad:candidato_a_desalojar(#{ninguno => Entry})
    ).

candidato_a_desalojar_elige_version_menor_aunque_no_venza_test() ->
    Vieja = {3, {value, azul, infinity}},
    Nueva = {20, {value, rojo, 100}},
    ?assertEqual(
        {z, Vieja},
        simple_kv_capacidad:candidato_a_desalojar(#{a => Nueva, z => Vieja})
    ).

candidato_a_desalojar_elige_por_version_y_no_por_vencimiento_test() ->
    Vieja = {3, {value, azul, 9000}},
    Nueva = {20, {value, rojo, 100}},
    ?assertEqual(
        {z, Vieja},
        simple_kv_capacidad:candidato_a_desalojar(#{a => Nueva, z => Vieja})
    ).

candidato_a_desalojar_admite_versiones_negativas_test() ->
    Vieja = {-5, {value, rojo, infinity}},
    Nueva = {-2, {value, azul, 0}},
    ?assertEqual(
        {a, Vieja},
        simple_kv_capacidad:candidato_a_desalojar(#{a => Vieja, b => Nueva})
    ).
