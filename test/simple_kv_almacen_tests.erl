-module(simple_kv_almacen_tests).
-include_lib("eunit/include/eunit.hrl").


buscar_local_desconocida_test() ->
    ?assertEqual(error, simple_kv_almacen:buscar_local(color, #{}, #{})).

buscar_local_valor_disponible_test() ->
    Entrada = {7, {valor, rojo, infinity}},
    ?assertEqual(
        {ok, Entrada},
        simple_kv_almacen:buscar_local(color, #{color => Entrada}, #{color => {7, valor}})
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
    Entrada = {9, {valor, rojo, infinity}},
    Metadatos = #{color => {9, desalojado}},
    NuevoMap = simple_kv_almacen:aplicar_actualizacion(color, Entrada, #{}, Metadatos),
    NuevosMetadatos =
        simple_kv_almacen:registrar_metadatos(color, Entrada, Metadatos),
    ?assertEqual({ok, Entrada}, maps:find(color, NuevoMap)),
    ?assertEqual({ok, {9, valor}}, maps:find(color, NuevosMetadatos)),
    ?assertEqual(
        {ok, Entrada},
        simple_kv_almacen:buscar_local(color, NuevoMap, NuevosMetadatos)
    ).

version_no_obsoleta_clave_desconocida_test() ->
    ?assert(simple_kv_almacen:version_no_obsoleta(
        color, {-5, {valor, rojo, infinity}}, #{}
    )).

version_no_obsoleta_compara_versiones_test() ->
    lists:foreach(
        fun(Estado) ->
            Metadatos = #{color => {-5, Estado}},
            ?assert(simple_kv_almacen:version_no_obsoleta(
                color, {-4, borrado}, Metadatos
            )),
            ?assert(simple_kv_almacen:version_no_obsoleta(
                color, {-5, {valor, rojo, infinity}}, Metadatos
            )),
            ?assertNot(simple_kv_almacen:version_no_obsoleta(
                color, {-6, {valor, azul, infinity}}, Metadatos
            ))
        end,
        [valor, borrado, desalojado]
    ).

cupo_se_calcula_por_peers_y_alfa_test() ->
    ?assertEqual(8, simple_kv_almacen:cupo_metadatos(2, 4)),
    ?assertEqual(8, simple_kv_almacen:cupo_metadatos(1, 4)),
    ?assertEqual(1200, simple_kv_almacen:cupo_metadatos(3, 400)).

cupo_sin_peers_usa_minimo_dos_test() ->
    ?assertEqual(8, simple_kv_almacen:cupo_metadatos(0, 4)).

limite_preserva_residente_antiguo_test() ->
    Valores = #{k => {1, {valor, v, infinity}}},
    Meta = #{k => {1, valor}, a => {2, borrado}, b => {3, desalojado}},
    ?assertEqual(#{k => {1, valor}, b => {3, desalojado}},
        simple_kv_almacen:limitar_metadatos(2, Valores, Meta)).

limite_conserva_marcas_de_mayor_version_test() ->
    Meta = #{a => {-3, borrado}, b => {-2, desalojado}, c => {-1, borrado}},
    ?assertEqual(#{b => {-2, desalojado}, c => {-1, borrado}},
        simple_kv_almacen:limitar_metadatos(2, #{}, Meta)).

limite_no_modifica_mapa_dentro_del_cupo_test() ->
    Meta = #{a => {1, borrado}},
    ?assertEqual(Meta, simple_kv_almacen:limitar_metadatos(4, #{}, Meta)).
