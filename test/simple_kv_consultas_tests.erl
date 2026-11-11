-module(simple_kv_consultas_tests).
-include_lib("eunit/include/eunit.hrl").
-import(simple_kv_test_utils, [iniciar/2, replica_con_par_falso/1, escribir/2,
                              lecturas/2, consultar_local/2, get_async/2,
                              esperar_get/1, esperar_consulta/1, responder_consulta/3]).

%% Un valor desalojado localmente se recupera desde otra replica.
lee_valor_desalojado_desde_otra_replica_test() ->
    Rep = replica_con_par_falso(3),
    escribir(Rep, [1, 2, 3, 4]),
    Entry1 = receive {ofrecer, 1, E} -> E after 1000 -> erlang:error(sin_oferta) end,
    ok = get_async(Rep, 1),
    {Rep, RefConsulta} = esperar_consulta(1),
    ok = responder_consulta(Rep, RefConsulta, {ok, Entry1}),
    ?assertEqual({ok, 1}, esperar_get(1)),
    ok = simple_kv:stop([Rep]).

%% Clave que nadie conoce: consulta y responde not_found.
clave_desconocida_test() ->
    Rep = replica_con_par_falso(3),
    ok = get_async(Rep, nunca),
    {Rep, RefConsulta} = esperar_consulta(nunca),
    ok = responder_consulta(Rep, RefConsulta, error),
    ?assertEqual(not_found, esperar_get(nunca)),
    ok = simple_kv:stop([Rep]).

%% Entre lo local (desalojado) y lo que responde el par, gana la version
%% mas alta: si el par tiene un borrado mas nuevo, el resultado es not_found.
gana_la_version_mas_alta_test() ->
    Rep = replica_con_par_falso(3),
    escribir(Rep, [1, 2, 3, 4]),
    ok = get_async(Rep, 1),
    {Rep, RefConsulta} = esperar_consulta(1),
    BorradoNuevo = {simple_kv_replicacion:nueva_version(), borrado},
    ok = responder_consulta(Rep, RefConsulta, {ok, BorradoNuevo}),
    ?assertEqual(not_found, esperar_get(1)),
    ok = simple_kv:stop([Rep]).

%% Si el par responde un valor vencido, no se devuelve.
respuesta_vencida_no_se_devuelve_test() ->
    Rep = replica_con_par_falso(3),
    ok = get_async(Rep, k),
    {Rep, RefConsulta} = esperar_consulta(k),
    Vencido = {simple_kv_replicacion:nueva_version(),
               {valor, x, erlang:monotonic_time(millisecond) - 1}},
    ok = responder_consulta(Rep, RefConsulta, {ok, Vencido}),
    ?assertEqual(not_found, esperar_get(k)),
    ok = simple_kv:stop([Rep]).

%% Si mientras espera llega el valor por replicacion, se usa ese
%% (comparacion final con lo local).
valor_que_llega_mientras_espera_test() ->
    Rep = replica_con_par_falso(3),
    ok = get_async(Rep, k),
    {Rep, RefConsulta} = esperar_consulta(k),
    Rep ! {replicar, k, {simple_kv_replicacion:nueva_version(), {valor, llego, infinity}}},
    ok = responder_consulta(Rep, RefConsulta, error),
    ?assertEqual({ok, llego}, esperar_get(k)),
    ok = simple_kv:stop([Rep]).

%% 5.2: mientras espera la respuesta de una consulta, la replica sigue
%% atendiendo pedidos de clientes y consultas de otras replicas.
replica_no_se_bloquea_mientras_consulta_test() ->
    Rep = replica_con_par_falso(3),
    ok = get_async(Rep, pendiente),
    {Rep, RefConsulta} = esperar_consulta(pendiente),
    %% todavia no respondimos la consulta
    ok = simple_kv:put(Rep, otra, 1),
    ?assertEqual({ok, 1}, simple_kv:get(Rep, otra)),
    MiRef = make_ref(),
    Rep ! {consultar, self(), MiRef, otra},
    receive
        {respuesta_consulta, MiRef, Rep, {ok, {_V, {valor, Valor, _Vence}}}} ->
            ?assertEqual(1, Valor)
    after 1000 ->
        erlang:error(no_respondio_consulta)
    end,
    %% recien ahora respondemos la consulta original
    ok = responder_consulta(Rep, RefConsulta, error),
    ?assertEqual(not_found, esperar_get(pendiente)),
    ok = simple_kv:stop([Rep]).

%% Una lectura en otra réplica devuelve la escritura recién confirmada.
lectura_inmediata_en_otra_replica_test() ->
    [P1, P2, _P3] = Ps = iniciar(3, 4),
    ok = simple_kv:put(P1, color, rojo),
    ?assertEqual({ok, rojo}, simple_kv:get(P2, color)),
    ok = simple_kv:stop(Ps).

%% Si todas las replicas desalojaron la clave, el resultado es not_found.
desalojada_en_todas_test() ->
    [P1, P2, _P3] = Ps = iniciar(3, 4),
    escribir(P1, lists:seq(1, 10)),
    timer:sleep(50),
    ?assertEqual(not_found, simple_kv:get(P2, 1)),
    ok = simple_kv:stop(Ps).

%% Una sola replica: no hay a quien consultar.
una_sola_replica_test() ->
    [P] = iniciar(1, 3),
    ?assertEqual(not_found, simple_kv:get(P, nunca)),
    ok = simple_kv:stop([P]).

%% 5.2: muchas lecturas cruzadas al mismo tiempo, todas terminan.
sin_deadlock_lecturas_cruzadas_test() ->
    Ps = iniciar(3, 4),
    Yo = self(),
    Clientes = lists:seq(1, 30),
    lists:foreach(
        fun(I) ->
            P = lists:nth(I rem 3 + 1, Ps),
            spawn_link(fun() -> Yo ! {fin, I, simple_kv:get(P, {nunca, I})} end)
        end,
        Clientes),
    lists:foreach(
        fun(I) ->
            receive
                {fin, I, Resultado} -> ?assertEqual(not_found, Resultado)
            after 2000 ->
                erlang:error({deadlock, I})
            end
        end,
        Clientes),
    ok = simple_kv:stop(Ps).

%% El par controlado conserva la única copia, de igual versión que la marca de desalojo.
get_recupera_valor_remoto_tras_desalojo_test() ->
    Padre = self(),
    Marca = make_ref(),
    Entrada = {1, {valor, remoto, infinity}},
    Par = spawn(fun() -> par_controlado(Padre, Marca, #{1 => Entrada}) end),
    Pid = spawn_link(fun simple_kv_replica:init/0),
    Pid ! {configurar, [Par], 16},
    try
        Pid ! {replicar, 1, Entrada},
        lists:foreach(
            fun(N) -> Pid ! {replicar, N, {N, {valor, N, infinity}}} end,
            lists:seq(2, 17)
        ),
        ?assertEqual({ok, {1, desalojado}}, consultar_local(Pid, 1)),
        ?assertEqual({ok, remoto}, simple_kv:get(Pid, 1)),
        receive {Marca, consultado, 1} -> ok
        after 1000 -> erlang:error(no_consulto_al_par)
        end
    after
        simple_kv:stop([Pid]),
        exit(Par, kill)
    end.

%% Prueba interna: un par retiene las respuestas hasta observar dos consultas
%% pendientes a la vez. Las replicas deben seguir atendiendo consultas entre si.
consultas_simultaneas_siguen_atendiendo_pedidos_test() ->
    Padre = self(),
    Marca = make_ref(),
    ParDemorado = spawn(fun() -> retener_consultas(Padre, Marca, []) end),
    P1 = spawn_link(fun simple_kv_replica:init/0),
    P2 = spawn_link(fun simple_kv_replica:init/0),
    P1 ! {configurar, [P2, ParDemorado], 16},
    P2 ! {configurar, [P1, ParDemorado], 16},
    Clientes = [spawn(fun() ->
        Resultado = simple_kv:get(Pid, {ausente, N}),
        Padre ! {Marca, lectura, N, Resultado}
    end) || {Pid, N} <- [{P1, 1}, {P2, 2}]],
    try
        receive {Marca, dos_pendientes} -> ok
        after 1000 -> erlang:error(no_iniciaron_dos_consultas)
        end,
        Escritor = spawn(fun() ->
            R = simple_kv:put(P1, disponible, dato),
            Padre ! {Marca, escritura, R}
        end),
        try
            receive {Marca, escritura, ok} -> ok
            after 1000 -> erlang:error(replica_bloqueada_esperando_consulta)
            end
        after exit(Escritor, kill)
        end,
        ParDemorado ! {Marca, liberar},
        lists:foreach(fun(N) ->
            receive {Marca, lectura, N, R} -> ?assertEqual(not_found, R)
            after 1000 -> erlang:error(consulta_no_termino)
            end
        end, [1, 2])
    after
        %% Liberar primero permite limpiar aun si falla una asercion.
        ParDemorado ! {Marca, liberar},
        lists:foreach(fun(C) -> exit(C, kill) end, Clientes),
        simple_kv:stop([P1, P2]),
        exit(ParDemorado, kill)
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

par_controlado(Padre, Marca, Valores) ->
    receive
        {consultar, Solicitante, Ref, Clave} ->
            Padre ! {Marca, consultado, Clave},
            Solicitante ! {respuesta_consulta, Ref, self(), maps:find(Clave, Valores)},
            par_controlado(Padre, Marca, Valores)
    end.

retener_consultas(Padre, Marca, Acumuladas) ->
    receive
        {consultar, Solicitante, Ref, _Clave} ->
            Nuevas = [{Solicitante, Ref} | Acumuladas],
            case length(Nuevas) of
                2 ->
                    Padre ! {Marca, dos_pendientes},
                    receive {Marca, liberar} ->
                        lists:foreach(fun({P, R}) ->
                            P ! {respuesta_consulta, R, self(), error}
                        end, Nuevas)
                    end;
                _ -> retener_consultas(Padre, Marca, Nuevas)
            end;
        {Marca, liberar} ->
            lists:foreach(fun({P, R}) ->
                P ! {respuesta_consulta, R, self(), error}
            end, Acumuladas)
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
