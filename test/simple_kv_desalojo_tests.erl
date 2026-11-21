-module(simple_kv_desalojo_tests).
-include_lib("eunit/include/eunit.hrl").

%% La decisión de desalojo devuelve una oferta del valor vigente más antiguo.
desalojo_ofrece_el_valor_test() ->
    Estado = llenar(3, [1, 2, 3]),
    {{V, _, _}, {1, _, {_, {valor, 1, infinity}}}} =
        guardar(3, 4, entrada(4, infinity), Estado),
    ?assertEqual([2, 3, 4], lists:sort(maps:keys(V))).

oferta_aceptada_con_lugar_test() ->
    {{V, _, _}, Entrada} = ofrecer(3, k, ofrecido, {#{}, #{}, #{}}),
    ?assertEqual(#{k => Entrada}, V).

oferta_rechazada_sin_lugar_test() ->
    Estado = llenar(3, [1, 2, 3]),
    ?assertEqual(Estado, element(1, ofrecer(3, k, ofrecido, Estado))).

oferta_vieja_no_pisa_valor_nuevo_test() ->
    Vieja = entrada(viejo, infinity),
    {Estado, _} = guardar(3, k, entrada(nuevo, infinity), {#{}, #{}, #{}}),
    ?assertEqual(Estado, aceptar(3, k, Vieja, Estado)).

oferta_vieja_no_revive_borrado_test() ->
    Vieja = entrada(v, infinity),
    Borrado = {simple_kv_replicacion:nueva_version(), borrado},
    Meta = simple_kv_almacen:registrar_metadatos(k, make_ref(), Borrado, #{}),
    Estado = {#{}, Meta, #{}},
    ?assertEqual(Estado, aceptar(3, k, Vieja, Estado)).

no_se_ofrece_un_vencido_al_desalojarlo_test() ->
    E0 = {#{}, #{}, #{}},
    {E1, ninguna} = guardar(3, vencido, entrada(descartado, 0), E0),
    {E2, ninguna} = guardar(3, a, entrada(a, infinity), E1),
    {E3, ninguna} = guardar(3, b, entrada(b, infinity), E2),
    {{V, M, _}, ninguna} = guardar(3, c, entrada(c, infinity), E3),
    ?assertNot(maps:is_key(vencido, V)),
    ?assertMatch({_, desalojado, _}, maps:get(vencido, M)).

oferta_reutiliza_vencido_elegible_test() ->
    E0 = llenar(4, [a]),
    {E1, ninguna} = guardar(4, b, entrada(vencido, 0), E0),
    {E2, ninguna} = guardar(4, c, entrada(c, infinity), E1),
    {E3, ninguna} = guardar(4, d, entrada(d, infinity), E2),
    {{V, M, _} = E4, _} = ofrecer(4, e, e, E3),
    ?assertMatch({_, desalojado, _}, maps:get(b, M)),
    ?assertEqual([a, c, d, e], lists:sort(maps:keys(V))),
    ?assertEqual(E4, element(1, ofrecer(4, f, f, E4))).

llenar(Alfa, Claves) ->
    lists:foldl(fun(K, Estado) ->
        {Nuevo, ninguna} = guardar(Alfa, K, entrada(K, infinity), Estado),
        Nuevo
    end, {#{}, #{}, #{}}, Claves).

guardar(Alfa, K, Entrada, {V, M, R}) ->
    simple_kv_capacidad:guardar(Alfa, K, reserva(K, M), Entrada, V, {M, R}).

ofrecer(Alfa, K, Valor, Estado) ->
    Entrada = entrada(Valor, infinity),
    {aceptar(Alfa, K, Entrada, Estado), Entrada}.

aceptar(Alfa, K, Entrada, {V, M, R}) ->
    simple_kv_capacidad:aceptar_oferta(Alfa, K, reserva(K, M), Entrada, V, {M, R}).

reserva(K, M) ->
    case maps:find(K, M) of {ok, {_, _, R}} -> R; error -> make_ref() end.

entrada(Valor, TTL) ->
    {simple_kv_replicacion:nueva_version(),
     {valor, Valor, simple_kv_ttl:calcular_vencimiento(TTL)}}.
