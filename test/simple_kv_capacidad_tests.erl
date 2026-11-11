-module(simple_kv_capacidad_tests).
-include_lib("eunit/include/eunit.hrl").

entrada_mas_antigua_mapa_vacio_no_tiene_candidato_test() ->
    ?assertEqual(ninguno, simple_kv_capacidad:entrada_mas_antigua(#{})).

entrada_mas_antigua_clave_ninguno_es_un_candidato_valido_test() ->
    Entrada = {42, {value, rojo, infinity}},
    ?assertEqual(
        {ninguno, Entrada},
        simple_kv_capacidad:entrada_mas_antigua(#{ninguno => Entrada})
    ).

entrada_mas_antigua_elige_version_menor_aunque_no_venza_test() ->
    Vieja = {3, {value, azul, infinity}},
    Nueva = {20, {value, rojo, 100}},
    ?assertEqual(
        {z, Vieja},
        simple_kv_capacidad:entrada_mas_antigua(#{a => Nueva, z => Vieja})
    ).

entrada_mas_antigua_elige_por_version_y_no_por_vencimiento_test() ->
    Vieja = {3, {value, azul, 9000}},
    Nueva = {20, {value, rojo, 100}},
    ?assertEqual(
        {z, Vieja},
        simple_kv_capacidad:entrada_mas_antigua(#{a => Nueva, z => Vieja})
    ).

entrada_mas_antigua_admite_versiones_negativas_test() ->
    Vieja = {-5, {value, rojo, infinity}},
    Nueva = {-2, {value, azul, 0}},
    ?assertEqual(
        {a, Vieja},
        simple_kv_capacidad:entrada_mas_antigua(#{a => Vieja, b => Nueva})
    ).

%% El orden de las claves es opuesto al orden de escritura.
dos_infinity_eligen_por_version_test() ->
    Vieja = {3, {value, viejo, infinity}},
    Nueva = {20, {value, nuevo, infinity}},
    ?assertEqual(
        {z, Vieja},
        simple_kv_capacidad:entrada_mas_antigua(#{a => Nueva, z => Vieja})
    ).
