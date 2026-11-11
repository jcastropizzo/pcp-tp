-module(simple_kv_v5_tests).
-include_lib("eunit/include/eunit.hrl").

%% La API acepta terminos compuestos y enlaza cada replica al invocante.
terminos_compuestos_y_enlaces_test() ->
    {ok, [P | _] = Pids} = simple_kv:start_link(2, 3),
    try
        {links, Links} = process_info(self(), links),
        ?assert(lists:all(fun(Pid) -> lists:member(Pid, Links) end, Pids)),
        Clave = #{clave => [uno, {dos, 2}]},
        Valor = {self(), <<0, 255>>, #{datos => [1, 2, 3]}},
        ok = simple_kv:put(P, Clave, Valor),
        ?assertEqual({ok, Valor}, simple_kv:get(P, Clave))
    after
        simple_kv:stop(Pids)
    end.

%% stop espera a una replica viva demorada y retorna con todos los pids terminados.
stop_espera_terminacion_lenta_test() ->
    {ok, [P1, P2] = Pids} = simple_kv:start_link(2, 3),
    true = erlang:suspend_process(P1),
    Padre = self(),
    {Cliente, Monitor} = spawn_monitor(fun() ->
        Resultado = try simple_kv:stop(Pids)
                     catch error:Razon -> {error, Razon}
                     end,
        Padre ! {cierre, self(), Resultado}
    end),
    try
        Plazo = erlang:monotonic_time(millisecond) + 700,
        esperar_stop_en_buzon(P1, Plazo),
        receive
            {cierre, Cliente, {error, Error}} -> error({stop_fallo, Error});
            {cierre, Cliente, Resultado} -> error({stop_no_espero, Resultado});
            {'DOWN', Monitor, process, Cliente, Razon} -> error({stop_fallo, Razon})
        after 1100 -> ok
        end,
        true = erlang:resume_process(P1),
        receive
            {cierre, Cliente, ok} -> ok;
            {cierre, Cliente, {error, ErrorFinal}} -> error({stop_fallo, ErrorFinal});
            {'DOWN', Monitor, process, Cliente, RazonFinal} -> error({stop_fallo, RazonFinal})
        after 1000 -> error(stop_no_termino)
        end,
        ?assertEqual([false, false], [is_process_alive(P) || P <- [P1, P2]])
    after
        exit(Cliente, kill),
        erlang:demonitor(Monitor, [flush]),
        lists:foreach(fun(P) -> unlink(P), exit(P, kill) end, Pids)
    end.

esperar_stop_en_buzon(Pid, Plazo) ->
    {messages, Mensajes} = process_info(Pid, messages),
    case lists:member(stop, Mensajes) of
        true -> ok;
        false ->
            case erlang:monotonic_time(millisecond) >= Plazo of
                true -> error(stop_no_enviado);
                false -> timer:sleep(5), esperar_stop_en_buzon(Pid, Plazo)
            end
    end.

%% Un mensaje inesperado recibido antes de inicializar no queda en el buzon.
init_descarta_mensajes_test() ->
    P = spawn_link(fun simple_kv_replica:init/0),
    P ! inesperado_antes_de_configurar,
    P ! {configurar, [], 3},
    try
        ?assertEqual(not_found, simple_kv:get(P, ausente)),
        ?assertEqual({messages, []}, process_info(P, messages))
    after
        simple_kv:stop([P])
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

%% Un delete replicado viejo no reemplaza una escritura de mayor version.
delete_replicado_viejo_conserva_valor_nuevo_test() ->
    {ok, [P]} = simple_kv:start_link(1, 3),
    try
        P ! {replicar, k, {20, {valor, nuevo, infinity}}},
        P ! {replicar, k, {10, borrado}},
        ?assertEqual({ok, nuevo}, simple_kv:get(P, k))
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

%% El resultado de un get pendiente ignora referencias ajenas, pares ajenos y duplicados.
consultas_filtran_respuestas_ajenas_y_duplicadas_test() ->
    con_lectura_retenida(fun(P, Consulta, ParDemorado, Cliente) ->
        Entrada = {1, {valor, remoto, infinity}},
        P ! {respuesta_consulta, make_ref(), self(), {ok, {100, borrado}}},
        P ! {respuesta_consulta, Consulta, desconocido, {ok, {100, borrado}}},
        P ! {respuesta_consulta, Consulta, self(), {ok, Entrada}},
        P ! {respuesta_consulta, Consulta, self(), {ok, {100, borrado}}},
        ?assertEqual(error, consultar_local(P, barrera)),
        receive
            {lectura, Cliente, Resultado} -> error({lectura_prematura, Resultado})
        after 20 -> ok
        end,
        ParDemorado ! liberar,
        ?assertEqual({ok, remoto}, esperar_lectura(Cliente))
    end).

%% Un valor remoto que vence mientras falta otra respuesta no se devuelve.
valor_remoto_vence_antes_de_finalizar_get_test() ->
    con_lectura_retenida(fun(P, Consulta, ParDemorado, Cliente) ->
        Vence = erlang:monotonic_time(millisecond) + 60,
        P ! {respuesta_consulta, Consulta, self(), {ok, {1, {valor, temporal, Vence}}}},
        ?assertEqual(error, consultar_local(P, barrera)),
        Restante = Vence - erlang:monotonic_time(millisecond),
        ?assert(Restante > 0),
        timer:sleep(Restante + 20),
        ParDemorado ! liberar,
        ?assertEqual(not_found, esperar_lectura(Cliente))
    end).

%% Un vencimiento elegible durante la demora permite al par conservar una copia remota.
replica_demorada_conserva_copia_para_get_test() ->
    {ok, [P1, P2] = Pids} = simple_kv:start_link(2, 4),
    true = erlang:suspend_process(P2),
    try
        escribir(P1, [k]),
        ok = simple_kv:put(P1, temporal, temporal, 500),
        escribir(P1, [a, b, c]),
        {ok, {Version, desalojado}} = consultar_local(P1, k),
        simple_kv_test_utils:esperar_valor(P1, temporal, not_found, 1500),
        true = erlang:resume_process(P2),
        ?assertEqual({ok, {Version, {valor, k, infinity}}}, consultar_local(P2, k)),
        Claves = [k, a, b, c, temporal],
        Esperado = [{ok, k}, {ok, a}, {ok, b}, {ok, c}, not_found],
        ?assertEqual(Esperado, lecturas(P1, Claves)),
        ?assertEqual(Esperado, lecturas(P2, Claves))
    after
        try erlang:resume_process(P2) catch error:badarg -> ok end,
        simple_kv:stop(Pids)
    end.

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

escribir(P, Claves) ->
    lists:foreach(fun(Clave) -> ok = simple_kv:put(P, Clave, Clave) end, Claves).

inyectar_escrituras_remotas(P, Claves) ->
    lists:foreach(fun(Clave) ->
        Entrada = {simple_kv_replicacion:nueva_version(), {valor, Clave, infinity}},
        P ! {replicar, Clave, Entrada}
    end, Claves).

lecturas(P, Claves) ->
    [simple_kv:get(P, Clave) || Clave <- Claves].

consultar_local(P, Clave) ->
    Ref = make_ref(),
    P ! {consultar, self(), Ref, Clave},
    receive
        {respuesta_consulta, Ref, P, Resultado} -> Resultado
    after 1000 -> error({sin_respuesta_local, Clave})
    end.

con_lectura_retenida(Verificar) ->
    ParDemorado = spawn(fun responder_al_liberar/0),
    P = spawn_link(fun simple_kv_replica:init/0),
    P ! {configurar, [self(), ParDemorado], 3},
    Padre = self(),
    Cliente = spawn(fun() -> Padre ! {lectura, self(), simple_kv:get(P, k)} end),
    try
        Consulta = receive
            {consultar, P, Ref, k} -> Ref
        after 1000 -> error(sin_consulta)
        end,
        Verificar(P, Consulta, ParDemorado, Cliente)
    after
        exit(Cliente, kill),
        exit(ParDemorado, kill),
        simple_kv:stop([P])
    end.

responder_al_liberar() ->
    receive
        {consultar, P, Ref, k} ->
            receive liberar -> P ! {respuesta_consulta, Ref, self(), error} end
    end.

esperar_lectura(Cliente) ->
    receive
        {lectura, Cliente, Resultado} -> Resultado
    after 1000 -> error(sin_lectura)
    end.
