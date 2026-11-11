-module(simple_kv_v5_tests).
-include_lib("eunit/include/eunit.hrl").

terminos_compuestos_y_enlaces_test() ->
    {ok, Ps} = simple_kv:start_link(2, 3),
    try
        {links, Links} = process_info(self(), links),
        ?assert(lists:all(fun(P) -> lists:member(P, Links) end, Ps)),
        [P | _] = Ps,
        Key = #{clave => [uno, {dos, 2}]},
        Val = {self(), <<0, 255>>, #{datos => [1,2,3]}},
        ok = simple_kv:put(P, Key, Val),
        ?assertEqual({ok, Val}, simple_kv:get(P, Key))
    after simple_kv:stop(Ps) end.

%% El contrato no impone un plazo: una replica viva puede tardar mas de 1 s.
stop_espera_terminacion_lenta_test() ->
    {ok, [P]} = simple_kv:start_link(1, 3),
    true = erlang:suspend_process(P),
    Parent = self(),
    {Worker, Monitor} = spawn_monitor(fun() ->
        Parent ! {cerrando, self()},
        R = simple_kv:stop([P]),
        Parent ! {cerrado, self(), R}
    end),
    receive {cerrando, Worker} -> ok end,
    try
        receive
            {cerrado, Worker, _} -> erlang:error(stop_no_espero);
            {'DOWN', Monitor, process, Worker, Reason} -> erlang:error({stop_fallo, Reason})
        after 1100 -> ok
        end,
        true = erlang:resume_process(P),
        receive {cerrado, Worker, ok} -> ok after 1000 -> erlang:error(stop_no_termino) end,
        receive {'DOWN', Monitor, process, Worker, normal} -> ok end,
        ?assertNot(is_process_alive(P))
    after
        case is_process_alive(P) of
            true ->
                try erlang:resume_process(P) catch error:badarg -> ok end,
                simple_kv:stop([P]);
            false -> ok
        end
    end.

init_descarta_mensajes_test() ->
    P = spawn_link(fun simple_kv_replica:init/0),
    P ! inesperado_antes_de_peers,
    P ! {peers, [], 3},
    try
        ?assertEqual(not_found, simple_kv:get(P, ausente)),
        ?assertEqual({messages, []}, process_info(P, messages))
    after simple_kv:stop([P]) end.

%% La capacidad y el cupo redondeado hacia arriba se verifican en cada paso,
%% incluyendo Alfa=3 y Alfa no multiplo de cuatro. Solo metadatos en Locales.
limite_y_cupo_local_para_varios_alfa_test() ->
    lists:foreach(fun(Alfa) ->
        Q = (3 * Alfa + 3) div 4,
        {Map, Meta, Locales} = lists:foldl(fun(N, {M, T, L}) ->
            E = {N, {value, {local, N}, infinity}},
            NL = simple_kv_capacidad:registrar_local(N, E, Alfa, L),
            {NM, NT} = simple_kv_capacidad:guardar([], Alfa, N, E, M, T, NL),
            ?assert(map_size(NM) =< Alfa),
            {NM, NT, NL}
        end, {#{}, #{}, #{}}, lists:seq(1, 30)),
        {Final, _} = lists:foldl(fun(N, {M, T}) ->
            E = {N, {value, remoto, infinity}},
            {NM, NT} = simple_kv_capacidad:guardar([], Alfa, N, E, M, T, Locales),
            ?assert(map_size(NM) =< Alfa),
            {NM, NT}
        end, {Map, Meta}, lists:seq(100, 150)),
        ?assertEqual(Q, map_size(Locales)),
        lists:foreach(fun(N) -> ?assert(maps:is_key(N, Final)) end,
                      lists:seq(31-Q, 30))
    end, lists:seq(3, 16)).

%% Dos escritores reales compiten por espacio. Los ultimos Q valores propios
%% siguen disponibles desde el nodo de origen, tambien luego de converger.
escrituras_locales_concurrentes_conservan_cupo_test() ->
    {ok, [P1, P2] = Ps} = simple_kv:start_link(2, 4),
    Parent = self(),
    Workers = [spawn_monitor(fun() ->
        lists:foreach(fun(N) -> ok = simple_kv:put(P, {Tag, N}, N) end, lists:seq(1, 20)),
        Parent ! {terminado, self()}
    end) || {P, Tag} <- [{P1, a}, {P2, b}]],
    try
        lists:foreach(fun({W, M}) ->
            receive {terminado, W} -> ok after 2000 -> erlang:error(escritor_lento) end,
            receive {'DOWN', M, process, W, normal} -> ok end
        end, Workers),
        lists:foreach(fun({P, Tag}) ->
            lists:foreach(fun(N) ->
                ?assertEqual({ok, N}, simple_kv:get(P, {Tag, N}))
            end, [18,19,20])
        end, [{P1,a},{P2,b}])
    after simple_kv:stop(Ps) end.

sobrescritura_delete_ttl_y_trafico_remoto_test() ->
    {ok, [P]} = simple_kv:start_link(1, 4),
    try
        lists:foreach(fun(N) -> simple_kv:put(P, N, N) end, lists:seq(1, 4)),
        ok = simple_kv:put(P, 2, nuevo),
        ok = simple_kv:delete(P, 3),
        ok = simple_kv:put(P, 4, vencido, 0),
        %% Versiones globales reales, posteriores a las escrituras locales.
        lists:foreach(fun(N) ->
            P ! {replica, {remoto,N}, {simple_kv_replicacion:nueva_version(), {value,N,infinity}}}
        end, lists:seq(1, 10)),
        ?assertEqual({ok,nuevo}, simple_kv:get(P, 2)),
        ?assertEqual(not_found, simple_kv:get(P, 3)),
        ?assertEqual(not_found, simple_kv:get(P, 4))
    after simple_kv:stop([P]) end.

%% No se acumula el valor en Pendientes: se entrega al cliente antes de que
%% responda el ultimo par. Las respuestas ajenas/duplicadas no cierran el get.
consultas_reenvian_y_filtran_respuestas_test() ->
    Gate = spawn(fun gate/0),
    P = spawn_link(fun simple_kv_replica:init/0),
    P ! {peers, [self(), Gate], 3},
    Ref = make_ref(),
    P ! {get, self(), Ref, ausente},
    try
        Consulta = receive {consultar, P, C, ausente} -> C after 1000 -> error(sin_consulta) end,
        P ! {respuesta_consulta, make_ref(), self(), error},
        P ! {respuesta_consulta, Consulta, desconocido, error},
        E = {1, {value, remoto, infinity}},
        P ! {respuesta_consulta, Consulta, self(), {ok, E}},
        P ! {respuesta_consulta, Consulta, self(), {ok, {100, borrado}}},
        receive {Ref, candidato, {ok, E}} -> ok after 1000 -> error(valor_retenido_en_replica) end,
        receive {Ref, fin} -> error(termino_sin_todos) after 20 -> ok end,
        Gate ! {liberar, self()},
        receive {Ref, fin} -> ok after 1000 -> error(no_termino) end,
        receive {Ref, candidato, {ok, {100,borrado}}} -> error(acepto_duplicado) after 0 -> ok end
    after simple_kv:stop([P]), exit(Gate, kill) end.

gate() ->
    receive {consultar, P, Ref, _} ->
        receive {liberar, _} -> P ! {respuesta_consulta, Ref, self(), error} end
    end.

valor_remoto_vence_antes_de_finalizar_get_test() ->
    Gate = spawn(fun gate/0),
    P = spawn_link(fun simple_kv_replica:init/0),
    P ! {peers, [self(), Gate], 3},
    Parent = self(),
    spawn(fun() -> Parent ! {leido, simple_kv:get(P, k)} end),
    try
        C = receive {consultar, P, R, k} -> R after 1000 -> error(sin_consulta) end,
        P ! {respuesta_consulta, C, self(), {ok, {1, {value, temporal, erlang:monotonic_time(millisecond)+30}}}},
        %% Barrera: la replica ya reenvio el candidato al cliente.
        B = make_ref(), P ! {consultar, self(), B, barrera},
        receive {respuesta_consulta, B, P, _} -> ok end,
        receive after 50 -> ok end,
        Gate ! {liberar, self()},
        receive {leido, Rdo} -> ?assertEqual(not_found, Rdo) after 1000 -> error(sin_resultado) end
    after simple_kv:stop([P]), exit(Gate, kill) end.

put_ttl_cero_con_mapa_lleno_no_desaloja_otras_claves_test() ->
    {ok, [P]} = simple_kv:start_link(1, 3),
    try
        lists:foreach(fun(N) -> simple_kv:put(P, N, N) end, [1,2,3]),
        ok = simple_kv:put(P, nueva, vencida, 0),
        lists:foreach(fun(N) -> ?assertEqual({ok,N}, simple_kv:get(P,N)) end, [1,2,3]),
        ?assertEqual(not_found, simple_kv:get(P,nueva))
    after simple_kv:stop([P]) end.

delete_replicado_viejo_conserva_valor_nuevo_test() ->
    {ok, [P]} = simple_kv:start_link(1,3),
    try
        P ! {replica, k, {20,{value,nuevo,infinity}}},
        P ! {replica, k, {10,borrado}},
        ?assertEqual({ok,nuevo},simple_kv:get(P,k))
    after simple_kv:stop([P]) end.
