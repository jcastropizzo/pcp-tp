-module(simple_kv_almacen_tests).
-include_lib("eunit/include/eunit.hrl").


buscar_local_desconocida_test() ->
    ?assertEqual(error, simple_kv_almacen:buscar_local(color, #{}, #{})).

buscar_local_valor_disponible_test() ->
    Entrada = {7, {valor, rojo, infinity}},
    ?assertEqual(
        {ok, Entrada},
        simple_kv_almacen:buscar_local(color, #{color => Entrada}, #{color => {7, valor, make_ref()}})
    ).

buscar_local_borrado_test() ->
    ?assertEqual(
        {ok, {8, borrado}},
        simple_kv_almacen:buscar_local(color, #{}, #{color => {8, borrado, make_ref()}})
    ).

buscar_local_desalojado_conserva_version_test() ->
    ?assertEqual(
        {ok, {9, desalojado}},
        simple_kv_almacen:buscar_local(color, #{}, #{color => {9, desalojado, make_ref()}})
    ).

recuperar_desalojado_con_igual_version_test() ->
    Entrada = {9, {valor, rojo, infinity}},
    Reserva = make_ref(),
    Metadatos = #{color => {9, desalojado, Reserva}},
    NuevoMap = simple_kv_almacen:aplicar_actualizacion(color, Entrada, #{}, Metadatos),
    NuevosMetadatos =
        simple_kv_almacen:registrar_metadatos(color, Reserva, Entrada, Metadatos),
    ?assertEqual({ok, Entrada}, maps:find(color, NuevoMap)),
    ?assertEqual({ok, {9, valor, Reserva}}, maps:find(color, NuevosMetadatos)),
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
            Metadatos = #{color => {-5, Estado, make_ref()}},
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
