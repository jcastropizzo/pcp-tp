-module(simple_kv_desalojo_tests).
-include_lib("eunit/include/eunit.hrl").

%%% =====================================================================
%%% Tests de capacidad y desalojo (4.7) y de lectura con consulta a
%%% otras replicas (4.8 / 5.2).
%%%
%%% Hay dos tipos de tests:
%%%  - Con replicas reales, usando solo la API (start_link/2, put, get...).
%%%  - Con un "par falso": se crea UNA replica cuyo unico par es el propio
%%%    proceso del test. Asi el test recibe los mensajes que la replica le
%%%    manda a sus pares ({replica, ...}, {ofrecer, ...}, {consultar, ...})
%%%    y decide que responder. Eso permite probar casos que con replicas
%%%    reales dependen del orden de llegada de los mensajes.
%%% =====================================================================

%%% ---------------------------------------------------------------------
%%% Auxiliares
%%% ---------------------------------------------------------------------

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
get_async(Rep, Key) ->
    Yo = self(),
    spawn_link(fun() -> Yo ! {resultado_get, Key, simple_kv:get(Rep, Key)} end),
    ok.

esperar_get(Key) ->
    receive
        {resultado_get, Key, Resultado} -> Resultado
    after 1000 ->
        erlang:error({get_sin_respuesta, Key})
    end.

%% Espera el {consultar, ...} que la replica le manda al par falso.
esperar_consulta(Key) ->
    receive
        {consultar, Rep, ConsultaRef, Key} -> {Rep, ConsultaRef}
    after 1000 ->
        erlang:error({sin_consulta, Key})
    end.

responder_consulta(Rep, ConsultaRef, Resultado) ->
    Rep ! {respuesta_consulta, ConsultaRef, self(), Resultado},
    ok.

%%% =====================================================================
%%% 1. Capacidad (4.7)
%%% =====================================================================

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

%%% =====================================================================
%%% 2. Ofertas al desalojar (4.7)
%%% =====================================================================

%% Antes de desalojar, la replica ofrece a sus pares el valor de menor version.
desalojo_ofrece_el_valor_test() ->
    Rep = replica_con_par_falso(3),
    poner_varios(Rep, [1, 2, 3, 4]),
    receive
        {ofrecer, Key, {_Version, {value, Val, _Vence}}} ->
            ?assertEqual(1, Key),
            ?assertEqual(1, Val)
    after 1000 ->
        erlang:error(sin_oferta)
    end,
    ok = simple_kv:stop([Rep]).

%% Con lugar libre, la oferta se acepta y queda disponible localmente.
oferta_aceptada_con_lugar_test() ->
    Rep = replica_con_par_falso(3),
    Entry = {simple_kv_replicacion:nueva_version(), {value, ofrecido, infinity}},
    Rep ! {ofrecer, k, Entry},
    ?assertEqual({ok, ofrecido}, simple_kv:get(Rep, k)),
    ok = simple_kv:stop([Rep]).

%% Sin lugar, la oferta se rechaza y NO provoca ningun desalojo.
oferta_rechazada_sin_lugar_test() ->
    Rep = replica_con_par_falso(3),
    poner_varios(Rep, [1, 2, 3]),
    Entry = {simple_kv_replicacion:nueva_version(), {value, ofrecido, infinity}},
    Rep ! {ofrecer, k, Entry},
    %% como no la guardo, el get de k tiene que consultar al par
    ok = get_async(Rep, k),
    {Rep, ConsultaRef} = esperar_consulta(k),
    ok = responder_consulta(Rep, ConsultaRef, error),
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

%% Una oferta vieja no revive un dato borrado (tombstone).
oferta_vieja_no_revive_borrado_test() ->
    Rep = replica_con_par_falso(3),
    VersionVieja = simple_kv_replicacion:nueva_version(),
    ok = simple_kv:put(Rep, k, v),
    ok = simple_kv:delete(Rep, k),
    Rep ! {ofrecer, k, {VersionVieja, {value, v, infinity}}},
    ?assertEqual(not_found, simple_kv:get(Rep, k)),
    ok = simple_kv:stop([Rep]).

%%% =====================================================================
%%% 3. Lectura con consulta a otras replicas (4.8)
%%% =====================================================================

%% Un valor desalojado localmente se recupera desde otra replica.
lee_valor_desalojado_desde_otra_replica_test() ->
    Rep = replica_con_par_falso(3),
    poner_varios(Rep, [1, 2, 3, 4]),
    Entry1 = receive {ofrecer, 1, E} -> E after 1000 -> erlang:error(sin_oferta) end,
    ok = get_async(Rep, 1),
    {Rep, ConsultaRef} = esperar_consulta(1),
    ok = responder_consulta(Rep, ConsultaRef, {ok, Entry1}),
    ?assertEqual({ok, 1}, esperar_get(1)),
    ok = simple_kv:stop([Rep]).

%% Clave que nadie conoce: consulta y responde not_found.
clave_desconocida_test() ->
    Rep = replica_con_par_falso(3),
    ok = get_async(Rep, nunca),
    {Rep, ConsultaRef} = esperar_consulta(nunca),
    ok = responder_consulta(Rep, ConsultaRef, error),
    ?assertEqual(not_found, esperar_get(nunca)),
    ok = simple_kv:stop([Rep]).

%% Entre lo local (desalojado) y lo que responde el par, gana la version
%% mas alta: si el par tiene un borrado mas nuevo, el resultado es not_found.
gana_la_version_mas_alta_test() ->
    Rep = replica_con_par_falso(3),
    poner_varios(Rep, [1, 2, 3, 4]),
    ok = get_async(Rep, 1),
    {Rep, ConsultaRef} = esperar_consulta(1),
    BorradoNuevo = {simple_kv_replicacion:nueva_version(), borrado},
    ok = responder_consulta(Rep, ConsultaRef, {ok, BorradoNuevo}),
    ?assertEqual(not_found, esperar_get(1)),
    ok = simple_kv:stop([Rep]).

%% Si el par responde un valor vencido, no se devuelve.
respuesta_vencida_no_se_devuelve_test() ->
    Rep = replica_con_par_falso(3),
    ok = get_async(Rep, k),
    {Rep, ConsultaRef} = esperar_consulta(k),
    Vencido = {simple_kv_replicacion:nueva_version(),
               {value, x, erlang:monotonic_time(millisecond) - 1}},
    ok = responder_consulta(Rep, ConsultaRef, {ok, Vencido}),
    ?assertEqual(not_found, esperar_get(k)),
    ok = simple_kv:stop([Rep]).

%% Si mientras espera llega el valor por replicacion, se usa ese
%% (comparacion final con lo local).
valor_que_llega_mientras_espera_test() ->
    Rep = replica_con_par_falso(3),
    ok = get_async(Rep, k),
    {Rep, ConsultaRef} = esperar_consulta(k),
    Rep ! {replica, k, {simple_kv_replicacion:nueva_version(), {value, llego, infinity}}},
    ok = responder_consulta(Rep, ConsultaRef, error),
    ?assertEqual({ok, llego}, esperar_get(k)),
    ok = simple_kv:stop([Rep]).

%% 5.2: mientras espera la respuesta de una consulta, la replica sigue
%% atendiendo pedidos de clientes y consultas de otras replicas.
replica_no_se_bloquea_mientras_consulta_test() ->
    Rep = replica_con_par_falso(3),
    ok = get_async(Rep, pendiente),
    {Rep, ConsultaRef} = esperar_consulta(pendiente),
    %% todavia no respondimos la consulta
    ok = simple_kv:put(Rep, otra, 1),
    ?assertEqual({ok, 1}, simple_kv:get(Rep, otra)),
    MiRef = make_ref(),
    Rep ! {consultar, self(), MiRef, otra},
    receive
        {respuesta_consulta, MiRef, Rep, {ok, {_V, {value, Val, _Vence}}}} ->
            ?assertEqual(1, Val)
    after 1000 ->
        erlang:error(no_respondio_consulta)
    end,
    %% recien ahora respondemos la consulta original
    ok = responder_consulta(Rep, ConsultaRef, error),
    ?assertEqual(not_found, esperar_get(pendiente)),
    ok = simple_kv:stop([Rep]).

%%% ---------- con replicas reales ----------

%% Un get en otra replica encuentra el valor aunque todavia no le haya
%% llegado la replicacion (si no lo tiene, consulta a las demas).
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
