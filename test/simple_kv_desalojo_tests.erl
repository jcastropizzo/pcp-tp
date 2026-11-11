-module(simple_kv_desalojo_tests).
-include_lib("eunit/include/eunit.hrl").
-import(simple_kv_test_utils, [replica_con_par_falso/1, escribir/2, lecturas/2,
                              consultar_local/2, get_async/2, esperar_get/1,
                              esperar_consulta/1, responder_consulta/3]).

%% Con todos los valores vigentes, la réplica ofrece el de menor versión.
desalojo_ofrece_el_valor_test() ->
    Rep = replica_con_par_falso(3),
    escribir(Rep, [1, 2, 3, 4]),
    receive
        {ofrecer, Clave, {_Version, {valor, Valor, _Vence}}} ->
            ?assertEqual(1, Clave),
            ?assertEqual(1, Valor)
    after 1000 ->
        erlang:error(sin_oferta)
    end,
    ok = simple_kv:stop([Rep]).

%% Con lugar libre, la oferta se acepta y queda disponible localmente.
oferta_aceptada_con_lugar_test() ->
    Rep = replica_con_par_falso(3),
    Entrada = {simple_kv_replicacion:nueva_version(), {valor, ofrecido, infinity}},
    Rep ! {ofrecer, k, Entrada},
    ?assertEqual({ok, ofrecido}, simple_kv:get(Rep, k)),
    ok = simple_kv:stop([Rep]).

%% Un mapa lleno de valores vigentes conserva sus entradas al recibir una oferta.
oferta_rechazada_sin_lugar_test() ->
    Rep = replica_con_par_falso(3),
    escribir(Rep, [1, 2, 3]),
    Entrada = {simple_kv_replicacion:nueva_version(), {valor, ofrecido, infinity}},
    Rep ! {ofrecer, k, Entrada},
    %% como no la guardo, el get de k tiene que consultar al par
    ok = get_async(Rep, k),
    {Rep, RefConsulta} = esperar_consulta(k),
    ok = responder_consulta(Rep, RefConsulta, error),
    ?assertEqual(not_found, esperar_get(k)),
    %% los valores que tenia siguen estando
    lists:foreach(fun(N) -> ?assertEqual({ok, N}, simple_kv:get(Rep, N)) end, [1, 2, 3]),
    ok = simple_kv:stop([Rep]).

%% Una oferta con version vieja no pisa un valor mas nuevo.
oferta_vieja_no_pisa_valor_nuevo_test() ->
    Rep = replica_con_par_falso(3),
    VersionVieja = simple_kv_replicacion:nueva_version(),
    ok = simple_kv:put(Rep, k, nuevo),
    Rep ! {ofrecer, k, {VersionVieja, {valor, viejo, infinity}}},
    ?assertEqual({ok, nuevo}, simple_kv:get(Rep, k)),
    ok = simple_kv:stop([Rep]).

%% La marca de borrado impide que una oferta antigua recupere el valor.
oferta_vieja_no_revive_borrado_test() ->
    Rep = replica_con_par_falso(3),
    VersionVieja = simple_kv_replicacion:nueva_version(),
    ok = simple_kv:put(Rep, k, v),
    ok = simple_kv:delete(Rep, k),
    Rep ! {ofrecer, k, {VersionVieja, {valor, v, infinity}}},
    ?assertEqual(not_found, simple_kv:get(Rep, k)),
    ok = simple_kv:stop([Rep]).

%% Un vencido que sale del mapa no se ofrece al par.
no_se_ofrece_un_vencido_al_desalojarlo_test() ->
    P = spawn_link(fun simple_kv_replica:init/0),
    P ! {configurar, [self()], 3},
    try
        ok = simple_kv:put(P, vencido, descartado, 0),
        escribir(P, [a, b, c]),
        ?assertNotMatch({ok, {_, {valor, _, _}}}, consultar_local(P, vencido)),
        receive
            {ofrecer, vencido, Entrada} -> error({ofrecio_vencido, Entrada})
        after 0 -> ok
        end
    after
        simple_kv:stop([P])
    end.

%% Una oferta puede reutilizar un vencido elegible, sin desalojar vigentes ni reenviar ofertas.
oferta_reutiliza_vencido_elegible_test() ->
    P = spawn_link(fun simple_kv_replica:init/0),
    P ! {configurar, [self()], 4},
    try
        Inicio = simple_kv_replicacion:nueva_version(),
        escribir(P, [a]),
        ok = simple_kv:put(P, b, vencido, 0),
        escribir(P, [c, d]),
        P ! {ofrecer, e, {simple_kv_replicacion:nueva_version(), {valor, e, infinity}}},
        ?assertMatch({ok, {_, desalojado}}, consultar_local(P, b)),
        P ! {ofrecer, f, {simple_kv_replicacion:nueva_version(), {valor, f, infinity}}},
        ?assertEqual(error, consultar_local(P, f)),
        ?assertEqual([{ok, K} || K <- [a, c, d, e]], lecturas(P, [a, c, d, e])),
        receive
            {ofrecer, K, {Version, _} = Entrada} when Version > Inicio ->
                error({oferta_reenviada, K, Entrada})
        after 0 -> ok
        end
    after
        simple_kv:stop([P])
    end.
