-module(simple_kv_capacidad_tests).
-include_lib("eunit/include/eunit.hrl").
-import(simple_kv_test_utils, [iniciar/2, escribir/2, lecturas/2, consultar_local/2]).

entrada_mas_antigua_mapa_vacio_no_tiene_candidato_test() ->
    ?assertEqual(ninguno, simple_kv_capacidad:entrada_mas_antigua(#{})).

entrada_mas_antigua_clave_ninguno_es_un_candidato_valido_test() ->
    Entrada = {42, {valor, rojo, infinity}},
    ?assertEqual(
        {ninguno, Entrada},
        simple_kv_capacidad:entrada_mas_antigua(#{ninguno => Entrada})
    ).

entrada_mas_antigua_elige_version_menor_aunque_no_venza_test() ->
    Vieja = {3, {valor, azul, infinity}},
    Nueva = {20, {valor, rojo, 100}},
    ?assertEqual(
        {z, Vieja},
        simple_kv_capacidad:entrada_mas_antigua(#{a => Nueva, z => Vieja})
    ).

entrada_mas_antigua_elige_por_version_y_no_por_vencimiento_test() ->
    Vieja = {3, {valor, azul, 9000}},
    Nueva = {20, {valor, rojo, 100}},
    ?assertEqual(
        {z, Vieja},
        simple_kv_capacidad:entrada_mas_antigua(#{a => Nueva, z => Vieja})
    ).

entrada_mas_antigua_admite_versiones_negativas_test() ->
    Vieja = {-5, {valor, rojo, infinity}},
    Nueva = {-2, {valor, azul, 0}},
    ?assertEqual(
        {a, Vieja},
        simple_kv_capacidad:entrada_mas_antigua(#{a => Vieja, b => Nueva})
    ).

%% El orden de las claves es opuesto al orden de escritura.
dos_infinity_eligen_por_version_test() ->
    Vieja = {3, {valor, viejo, infinity}},
    Nueva = {20, {valor, nuevo, infinity}},
    ?assertEqual(
        {z, Vieja},
        simple_kv_capacidad:entrada_mas_antigua(#{a => Nueva, z => Vieja})
    ).

%% Con una sola replica no hay a quien ofrecer ni consultar: quedan
%% exactamente los Alfa valores mas recientes.
conserva_los_alfa_mas_recientes_test() ->
    [P] = iniciar(1, 4),
    escribir(P, lists:seq(1, 10)),
    lists:foreach(fun(N) -> ?assertEqual({ok, N}, simple_kv:get(P, N)) end,
                  lists:seq(7, 10)),
    lists:foreach(fun(N) -> ?assertEqual(not_found, simple_kv:get(P, N)) end,
                  lists:seq(1, 6)),
    ok = simple_kv:stop([P]).

%% El 75 % mas reciente (3 de 4) esta disponible en todas las replicas.
setenta_y_cinco_por_ciento_en_todas_las_replicas_test() ->
    [P1 | _] = Ps = iniciar(3, 4),
    escribir(P1, lists:seq(1, 10)),
    timer:sleep(50),
    lists:foreach(
        fun(P) ->
            lists:foreach(fun(N) -> ?assertEqual({ok, N}, simple_kv:get(P, N)) end,
                          [8, 9, 10])
        end,
        Ps),
    ok = simple_kv:stop(Ps).

%% Sobrescribir una clave existente no ocupa lugar nuevo: no desaloja.
sobrescribir_no_desaloja_test() ->
    [P] = iniciar(1, 4),
    escribir(P, [1, 2, 3, 4]),
    ok = simple_kv:put(P, 1, nuevo),
    ?assertEqual({ok, nuevo}, simple_kv:get(P, 1)),
    lists:foreach(fun(N) -> ?assertEqual({ok, N}, simple_kv:get(P, N)) end, [2, 3, 4]),
    ok = simple_kv:stop([P]).

%% Un delete libera lugar: el siguiente put no desaloja a nadie.
delete_libera_lugar_test() ->
    [P] = iniciar(1, 4),
    escribir(P, [1, 2, 3, 4]),
    ok = simple_kv:delete(P, 1),
    ok = simple_kv:put(P, 5, 5),
    lists:foreach(fun(N) -> ?assertEqual({ok, N}, simple_kv:get(P, N)) end, [2, 3, 4, 5]),
    ?assertEqual(not_found, simple_kv:get(P, 1)),
    ok = simple_kv:stop([P]).

%% Entre los elegibles, se desaloja el vencido antes que el vigente mas viejo.
vencidos_no_protegidos_se_desalojan_primero_test() ->
    [P] = iniciar(1, 4),
    try
        ok = simple_kv:put(P, a, 1),
        ok = simple_kv:put(P, b, 2, 0),
        ok = simple_kv:put(P, c, 3),
        ok = simple_kv:put(P, d, 4),
        ok = simple_kv:put(P, e, 5),
        ?assertEqual(not_found, simple_kv:get(P, b)),
        lists:foreach(fun({K, V}) -> ?assertEqual({ok, V}, simple_kv:get(P, K)) end,
                      [{a, 1}, {c, 3}, {d, 4}, {e, 5}])
    after
        simple_kv:stop([P])
    end.

%% Una sola replica: un get no puede recuperar el dato desde otro proceso.
%% Sin TTL ni delete: la desaparicion esperada corresponde al desalojo.
diecisiete_claves_desalojan_una_en_replica_unica_test() ->
    {ok, [Pid]} = simple_kv:start_link(1, 16),
    try
        lists:foreach(
            fun(N) ->
                ok = simple_kv:put(Pid, {clave, N}, {valor, N})
            end,
            lists:seq(1, 16)
        ),
        %% Con 16 claves todavia no hace falta desalojar.
        lists:foreach(
            fun(N) ->
                ?assertEqual({ok, {valor, N}}, simple_kv:get(Pid, {clave, N}))
            end,
            lists:seq(1, 16)
        ),
        ok = simple_kv:put(Pid, {clave, 17}, {valor, 17}),
        Lecturas = [
            {N, simple_kv:get(Pid, {clave, N})}
            || N <- lists:seq(1, 17)
        ],
        %% Las 12 escrituras mas recientes deben seguir disponibles.
        lists:foreach(
            fun(N) ->
                ?assertEqual({ok, {valor, N}}, proplists:get_value(N, Lecturas))
            end,
            lists:seq(6, 17)
        ),
        Disponibles = [N || {N, {ok, _}} <- Lecturas],
        Ausentes = [N || {N, not_found} <- Lecturas],
        ?assertEqual(16, length(Disponibles)),
        ?assertEqual(1, length(Ausentes))
    after
        simple_kv:stop([Pid])
    end.

%% Regresion de capacidad mediante API publica, sin pares que oculten un desalojo.
sobrescritura_con_capacidad_llena_no_desaloja_test() ->
    {ok, [Pid]} = simple_kv:start_link(1, 16),
    try
        lists:foreach(fun(N) -> ok = simple_kv:put(Pid, N, N) end, lists:seq(1, 16)),
        ok = simple_kv:put(Pid, 16, reemplazo),
        ?assertEqual({ok, reemplazo}, simple_kv:get(Pid, 16)),
        lists:foreach(
            fun(N) -> ?assertEqual({ok, N}, simple_kv:get(Pid, N)) end,
            lists:seq(1, 15)
        )
    after
        simple_kv:stop([Pid])
    end.

%% Prueba interna: inyecta mensajes de replicacion y consulta estado LOCAL.
%% get/2 podria recuperar datos de pares y ocultar exceso de almacenamiento.
recepcion_replicada_limita_capacidad_y_no_desaloja_por_duplicados_test() ->
    {ok, [Pid]} = simple_kv:start_link(1, 16),
    try
        lists:foreach(
            fun(N) -> Pid ! {replicar, N, {N, {valor, N, infinity}}} end,
            lists:seq(1, 17)
        ),
        Antes = [{N, consultar_local(Pid, N)} || N <- lists:seq(1, 17)],
        ?assertEqual(16, length([N || {N, {ok, {_, {valor, _, _}}}} <- Antes])),
        ?assertEqual(1, length([N || {N, {ok, {_, desalojado}}} <- Antes])),
        lists:foreach(
            fun(N) -> ?assertEqual({ok, {N, {valor, N, infinity}}}, proplists:get_value(N, Antes)) end,
            lists:seq(6, 17)
        ),
        Pid ! {replicar, 17, {17, {valor, 17, infinity}}},
        Pid ! {replicar, 17, {0, {valor, obsoleto, infinity}}},
        Despues = [{N, consultar_local(Pid, N)} || N <- lists:seq(1, 17)],
        ?assertEqual(Antes, Despues)
    after
        simple_kv:stop([Pid])
    end.

%% Una sola replica conserva las Alfa versiones mas nuevas para tres ordenes de entrega.
limite_y_mayores_versiones_para_varios_alfa_test() ->
    Claves = lists:seq(1, 40),
    ParesPrimero = [N || N <- Claves, N rem 2 =:= 0] ++
                   [N || N <- Claves, N rem 2 =:= 1],
    Ordenes = [Claves, lists:reverse(Claves), ParesPrimero],
    lists:foreach(fun(Alfa) ->
        lists:foreach(fun(Orden) ->
            {ok, [P]} = simple_kv:start_link(1, Alfa),
            try
                lists:foreach(fun(N) ->
                    P ! {replicar, N, {N, {valor, N, infinity}}}
                end, Orden),
                Esperado = [{N, {ok, N}} || N <- lists:nthtail(40 - Alfa, Claves)],
                Disponibles = [{N, Lectura} || N <- Claves,
                    Lectura <- [simple_kv:get(P, N)], Lectura =/= not_found],
                ?assertEqual(Esperado, Disponibles)
            after
                simple_kv:stop([P])
            end
        end, Ordenes)
    end, lists:seq(3, 16)).

%% La presion de escrituras remotas preserva el borrado y no reactiva el TTL cero.
sobrescritura_delete_ttl_y_trafico_remoto_test() ->
    {ok, [P]} = simple_kv:start_link(1, 4),
    try
        escribir(P, [1, 2, 3, 4]),
        ok = simple_kv:put(P, 2, nuevo),
        ok = simple_kv:delete(P, 3),
        ok = simple_kv:put(P, 4, vencido, 0),
        ?assertEqual({ok, nuevo}, simple_kv:get(P, 2)),
        inyectar_escrituras_remotas(P, [{remoto, N} || N <- lists:seq(1, 10)]),
        ?assertEqual([not_found, not_found, not_found], lecturas(P, [2, 3, 4])),
        ?assertEqual([{ok, {remoto, N}} || N <- [7, 8, 9, 10]],
                     lecturas(P, [{remoto, N} || N <- [7, 8, 9, 10]]))
    after
        simple_kv:stop([P])
    end.

%% Las versiones remotas mas nuevas pueden ocupar todo el cupo.
versiones_remotas_desplazan_todas_las_locales_antiguas_test() ->
    {ok, [P]} = simple_kv:start_link(1, 3),
    try
        escribir(P, [a, b, c]),
        inyectar_escrituras_remotas(P, [d, e, f]),
        ?assertEqual([not_found, not_found, not_found, {ok, d}, {ok, e}, {ok, f}],
                     lecturas(P, [a, b, c, d, e, f]))
    after
        simple_kv:stop([P])
    end.

%% Con Alfa 3, el TTL cero reciente ocupa una plaza y get lo oculta.
retencion_fisica_ttl_test() ->
    {ok, [P]} = simple_kv:start_link(1, 3),
    try
        escribir(P, [a, b, c]),
        ok = simple_kv:put(P, d, vencido, 0),
        ?assertEqual(not_found, simple_kv:get(P, d)),
        ?assertMatch({ok, {_, {valor, vencido, _}}}, consultar_local(P, d)),
        ?assertEqual([not_found, {ok, b}, {ok, c}], lecturas(P, [a, b, c]))
    after
        simple_kv:stop([P])
    end.

%% Alfa 5 protege cuatro escrituras. Una vencida se vuelve elegible al salir del ranking.
vencida_sale_al_perder_proteccion_test() ->
    {ok, [P]} = simple_kv:start_link(1, 5),
    try
        escribir(P, [a]),
        ok = simple_kv:put(P, b, vencido, 0),
        ok = simple_kv:put(P, c, vencido, 0),
        escribir(P, [d, e]),
        inyectar_escrituras_remotas(P, [f]),
        ?assertMatch({ok, {_, desalojado}}, consultar_local(P, b)),
        ?assertMatch({ok, {_, {valor, vencido, _}}}, consultar_local(P, c)),
        ?assertEqual(not_found, simple_kv:get(P, c)),
        inyectar_escrituras_remotas(P, [g]),
        ?assertMatch({ok, {_, desalojado}}, consultar_local(P, c)),
        ?assertEqual([{ok, K} || K <- [a, d, e, f, g]], lecturas(P, [a, d, e, f, g]))
    after
        simple_kv:stop([P])
    end.

%% El delete de un protegido vencido libera su plaza y bloquea su replica anterior.
delete_libera_plaza_de_vencido_protegido_test() ->
    {ok, [P]} = simple_kv:start_link(1, 3),
    try
        escribir(P, [a, b]),
        ok = simple_kv:put(P, c, vencido, 0),
        {ok, Entrada} = consultar_local(P, c),
        ok = simple_kv:delete(P, c),
        P ! {replicar, c, Entrada},
        escribir(P, [d]),
        ?assertMatch({ok, {_, borrado}}, consultar_local(P, c)),
        ?assertEqual([{ok, a}, {ok, b}, not_found, {ok, d}], lecturas(P, [a, b, c, d]))
    after
        simple_kv:stop([P])
    end.

inyectar_escrituras_remotas(P, Claves) ->
    lists:foreach(fun(Clave) ->
        Entrada = {simple_kv_replicacion:nueva_version(), {valor, Clave, infinity}},
        P ! {replicar, Clave, Entrada}
    end, Claves).
