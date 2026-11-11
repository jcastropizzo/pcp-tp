-module(simple_kv_desalojo_tests).
-include_lib("eunit/include/eunit.hrl").

%% Los pares controlados permiten fijar el orden y el contenido de las respuestas.

iniciar(N, Alfa) ->
    {ok, Pids} = simple_kv:start_link(N, Alfa),
    Pids.

%% Replica cuyo unico par es el proceso del test.
replica_con_par_falso(Alfa) ->
    Rep = spawn_link(fun simple_kv_replica:init/0),
    Rep ! {peers, [self()], Alfa},
    Rep.

poner_varios(Pid, Claves) ->
    lists:foreach(fun(N) -> ok = simple_kv:put(Pid, N, N) end, Claves).

%% El get se hace desde otro proceso: si la replica le consulta al test
%% (par falso), el test tiene que estar libre para responder.
get_async(Rep, Clave) ->
    Yo = self(),
    spawn_link(fun() -> Yo ! {resultado_get, Clave, simple_kv:get(Rep, Clave)} end),
    ok.

esperar_get(Clave) ->
    receive
        {resultado_get, Clave, Resultado} -> Resultado
    after 1000 ->
        erlang:error({get_sin_respuesta, Clave})
    end.

%% Espera el {consultar, ...} que la replica le manda al par falso.
esperar_consulta(Clave) ->
    receive
        {consultar, Rep, RefConsulta, Clave} -> {Rep, RefConsulta}
    after 1000 ->
        erlang:error({sin_consulta, Clave})
    end.

responder_consulta(Rep, RefConsulta, Resultado) ->
    Rep ! {respuesta_consulta, RefConsulta, self(), Resultado},
    ok.

%%% 1. Capacidad (4.7)

%% Con una sola replica no hay a quien ofrecer ni consultar: quedan
%% exactamente los Alfa valores mas recientes.
conserva_los_alfa_mas_recientes_test() ->
    [P] = iniciar(1, 4),
    poner_varios(P, lists:seq(1, 10)),
    lists:foreach(fun(N) -> ?assertEqual({ok, N}, simple_kv:get(P, N)) end,
                  lists:seq(7, 10)),
    lists:foreach(fun(N) -> ?assertEqual(not_found, simple_kv:get(P, N)) end,
                  lists:seq(1, 6)),
    ok = simple_kv:stop([P]).

%% El 75 % mas reciente (3 de 4) esta disponible en todas las replicas.
setenta_y_cinco_por_ciento_en_todas_las_replicas_test() ->
    [P1 | _] = Ps = iniciar(3, 4),
    poner_varios(P1, lists:seq(1, 10)),
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
    poner_varios(P, [1, 2, 3, 4]),
    ok = simple_kv:put(P, 1, nuevo),
    ?assertEqual({ok, nuevo}, simple_kv:get(P, 1)),
    lists:foreach(fun(N) -> ?assertEqual({ok, N}, simple_kv:get(P, N)) end, [2, 3, 4]),
    ok = simple_kv:stop([P]).

%% Un delete libera lugar: el siguiente put no desaloja a nadie.
delete_libera_lugar_test() ->
    [P] = iniciar(1, 4),
    poner_varios(P, [1, 2, 3, 4]),
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

%% Alfa invalido: falla en el proceso que llama. El minimo es 3 (4.7).
alfa_invalido_test() ->
    ?assertError(function_clause, simple_kv:start_link(2, 0)),
    ?assertError(function_clause, simple_kv:start_link(2, -1)),
    ?assertError(function_clause, simple_kv:start_link(2, 2)),
    ?assertError(function_clause, simple_kv:start_link(2, tres)).

%% Alfa minimo aceptado.
alfa_minimo_3_aceptado_test() ->
    [P] = iniciar(1, 3),
    ok = simple_kv:stop([P]).

%%% 2. Ofertas al desalojar (4.7)

%% Con todos los valores vigentes, la réplica ofrece el de menor versión.
desalojo_ofrece_el_valor_test() ->
    Rep = replica_con_par_falso(3),
    poner_varios(Rep, [1, 2, 3, 4]),
    receive
        {ofrecer, Clave, {_Version, {value, Valor, _Vence}}} ->
            ?assertEqual(1, Clave),
            ?assertEqual(1, Valor)
    after 1000 ->
        erlang:error(sin_oferta)
    end,
    ok = simple_kv:stop([Rep]).

%% Con lugar libre, la oferta se acepta y queda disponible localmente.
oferta_aceptada_con_lugar_test() ->
    Rep = replica_con_par_falso(3),
    Entrada = {simple_kv_replicacion:nueva_version(), {value, ofrecido, infinity}},
    Rep ! {ofrecer, k, Entrada},
    ?assertEqual({ok, ofrecido}, simple_kv:get(Rep, k)),
    ok = simple_kv:stop([Rep]).

%% Un mapa lleno de valores vigentes conserva sus entradas al recibir una oferta.
oferta_rechazada_sin_lugar_test() ->
    Rep = replica_con_par_falso(3),
    poner_varios(Rep, [1, 2, 3]),
    Entrada = {simple_kv_replicacion:nueva_version(), {value, ofrecido, infinity}},
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
    Rep ! {ofrecer, k, {VersionVieja, {value, viejo, infinity}}},
    ?assertEqual({ok, nuevo}, simple_kv:get(Rep, k)),
    ok = simple_kv:stop([Rep]).

%% La marca de borrado impide que una oferta antigua recupere el valor.
oferta_vieja_no_revive_borrado_test() ->
    Rep = replica_con_par_falso(3),
    VersionVieja = simple_kv_replicacion:nueva_version(),
    ok = simple_kv:put(Rep, k, v),
    ok = simple_kv:delete(Rep, k),
    Rep ! {ofrecer, k, {VersionVieja, {value, v, infinity}}},
    ?assertEqual(not_found, simple_kv:get(Rep, k)),
    ok = simple_kv:stop([Rep]).

%%% 3. Lectura con consulta a otras replicas (4.8)

%% Un valor desalojado localmente se recupera desde otra replica.
lee_valor_desalojado_desde_otra_replica_test() ->
    Rep = replica_con_par_falso(3),
    poner_varios(Rep, [1, 2, 3, 4]),
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
    poner_varios(Rep, [1, 2, 3, 4]),
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
               {value, x, erlang:monotonic_time(millisecond) - 1}},
    ok = responder_consulta(Rep, RefConsulta, {ok, Vencido}),
    ?assertEqual(not_found, esperar_get(k)),
    ok = simple_kv:stop([Rep]).

%% Si mientras espera llega el valor por replicacion, se usa ese
%% (comparacion final con lo local).
valor_que_llega_mientras_espera_test() ->
    Rep = replica_con_par_falso(3),
    ok = get_async(Rep, k),
    {Rep, RefConsulta} = esperar_consulta(k),
    Rep ! {replica, k, {simple_kv_replicacion:nueva_version(), {value, llego, infinity}}},
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
        {respuesta_consulta, MiRef, Rep, {ok, {_V, {value, Valor, _Vence}}}} ->
            ?assertEqual(1, Valor)
    after 1000 ->
        erlang:error(no_respondio_consulta)
    end,
    %% recien ahora respondemos la consulta original
    ok = responder_consulta(Rep, RefConsulta, error),
    ?assertEqual(not_found, esperar_get(pendiente)),
    ok = simple_kv:stop([Rep]).

%% Pruebas con réplicas reales.

%% Una lectura en otra réplica devuelve la escritura recién confirmada.
lectura_inmediata_en_otra_replica_test() ->
    [P1, P2, _P3] = Ps = iniciar(3, 4),
    ok = simple_kv:put(P1, color, rojo),
    ?assertEqual({ok, rojo}, simple_kv:get(P2, color)),
    ok = simple_kv:stop(Ps).

%% Si todas las replicas desalojaron la clave, el resultado es not_found.
desalojada_en_todas_test() ->
    [P1, P2, _P3] = Ps = iniciar(3, 4),
    poner_varios(P1, lists:seq(1, 10)),
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
