-module(simple_kv_almacen_tests).
-include_lib("eunit/include/eunit.hrl").


buscar_local_desconocida_test() ->
    ?assertEqual(error, simple_kv_almacen:buscar_local(color, #{}, #{})).

buscar_local_valor_disponible_test() ->
    Entry = {7, {value, rojo, infinity}},
    ?assertEqual(
        {ok, Entry},
        simple_kv_almacen:buscar_local(color, #{color => Entry}, #{color => {7, valor}})
    ).

buscar_local_borrado_test() ->
    ?assertEqual(
        {ok, {8, borrado}},
        simple_kv_almacen:buscar_local(color, #{}, #{color => {8, borrado}})
    ).

buscar_local_desalojado_conserva_version_test() ->
    ?assertEqual(
        {ok, {9, desalojado}},
        simple_kv_almacen:buscar_local(color, #{}, #{color => {9, desalojado}})
    ).

recuperar_desalojado_con_igual_version_test() ->
    Entry = {9, {value, rojo, infinity}},
    Metadatos = #{color => {9, desalojado}},
    NuevoMap = simple_kv_almacen:aplicar_actualizacion(color, Entry, #{}, Metadatos),
    NuevosMetadatos =
        simple_kv_almacen:registrar_metadata(color, Entry, Metadatos),
    ?assertEqual({ok, Entry}, maps:find(color, NuevoMap)),
    ?assertEqual({ok, {9, valor}}, maps:find(color, NuevosMetadatos)),
    ?assertEqual(
        {ok, Entry},
        simple_kv_almacen:buscar_local(color, NuevoMap, NuevosMetadatos)
    ).

es_mensaje_nuevo_clave_desconocida_test() ->
    ?assert(simple_kv_almacen:es_mensaje_nuevo(
        color, {-5, {value, rojo, infinity}}, #{}
    )).

es_mensaje_nuevo_compara_versiones_test() ->
    lists:foreach(
        fun(Estado) ->
            Metadatos = #{color => {-5, Estado}},
            ?assert(simple_kv_almacen:es_mensaje_nuevo(
                color, {-4, borrado}, Metadatos
            )),
            ?assert(simple_kv_almacen:es_mensaje_nuevo(
                color, {-5, {value, rojo, infinity}}, Metadatos
            )),
            ?assertNot(simple_kv_almacen:es_mensaje_nuevo(
                color, {-6, {value, azul, infinity}}, Metadatos
            ))
        end,
        [valor, borrado, desalojado]
    ).
