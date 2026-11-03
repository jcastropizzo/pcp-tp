-module(simple_kv_replica_tests).
-include_lib("eunit/include/eunit.hrl").

%% Una sola replica: un get no puede recuperar el dato desde otro proceso.
%% Sin TTL ni delete: la desaparicion esperada corresponde al desalojo.
diecisiete_claves_desalojan_una_en_replica_unica_test() ->
    {ok, [Pid]} = simple_kv:start_link(1),
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
    {ok, [Pid]} = simple_kv:start_link(1),
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
    {ok, [Pid]} = simple_kv:start_link(1),
    try
        lists:foreach(
            fun(N) -> Pid ! {replica, N, {N, {value, N, infinity}}} end,
            lists:seq(1, 17)
        ),
        Antes = [{N, consultar_local(Pid, N)} || N <- lists:seq(1, 17)],
        ?assertEqual(16, length([N || {N, {ok, {_, {value, _, _}}}} <- Antes])),
        ?assertEqual(1, length([N || {N, {ok, {_, desalojado}}} <- Antes])),
        lists:foreach(
            fun(N) -> ?assertEqual({ok, {N, {value, N, infinity}}}, proplists:get_value(N, Antes)) end,
            lists:seq(6, 17)
        ),
        Pid ! {replica, 17, {17, {value, 17, infinity}}},
        Pid ! {replica, 17, {0, {value, obsoleto, infinity}}},
        Despues = [{N, consultar_local(Pid, N)} || N <- lists:seq(1, 17)],
        ?assertEqual(Antes, Despues)
    after
        simple_kv:stop([Pid])
    end.

%% Par controlado: fuerza que la unica copia disponible sea remota y que tenga
%% la MISMA version que la marca local de desalojo. No cambia produccion.
get_recupera_valor_remoto_tras_desalojo_test() ->
    Padre = self(),
    Marca = make_ref(),
    Entry = {1, {value, remoto, infinity}},
    Peer = spawn(fun() -> par_controlado(Padre, Marca, #{1 => Entry}) end),
    Pid = spawn_link(fun simple_kv_replica:init/0),
    Pid ! {peers, [Peer]},
    try
        Pid ! {replica, 1, Entry},
        lists:foreach(
            fun(N) -> Pid ! {replica, N, {N, {value, N, infinity}}} end,
            lists:seq(2, 17)
        ),
        ?assertEqual({ok, {1, desalojado}}, consultar_local(Pid, 1)),
        ?assertEqual({ok, remoto}, simple_kv:get(Pid, 1)),
        receive {Marca, consultado, 1} -> ok
        after 1000 -> erlang:error(no_consulto_al_par)
        end
    after
        simple_kv:stop([Pid]),
        exit(Peer, kill)
    end.

%% Prueba interna: entrega primero un borrado y luego una escritura anterior.
mensaje_viejo_no_resucita_borrado_test() ->
    {ok, [Pid]} = simple_kv:start_link(1),
    try
        Pid ! {replica, color, {20, borrado}},
        Pid ! {replica, color, {10, {value, rojo, infinity}}},
        ?assertEqual({ok, {20, borrado}}, consultar_local(Pid, color)),
        ?assertEqual(not_found, simple_kv:get(Pid, color))
    after
        simple_kv:stop([Pid])
    end.

%% Prueba interna: fuerza los dos ordenes de entrega en replicas reales.
ordenes_opuestos_convergen_a_misma_version_test() ->
    {ok, [P1, P2] = Pids} = simple_kv:start_link(2),
    Vieja = {10, {value, rojo, infinity}},
    Nueva = {20, {value, azul, infinity}},
    try
        P1 ! {replica, color, Vieja},
        P1 ! {replica, color, Nueva},
        P2 ! {replica, color, Nueva},
        P2 ! {replica, color, Vieja},
        ?assertEqual({ok, Nueva}, consultar_local(P1, color)),
        ?assertEqual({ok, Nueva}, consultar_local(P2, color))
    after
        simple_kv:stop(Pids)
    end.

%% API publica: dos clientes se liberan juntos. No fija el ganador ni garantiza
%% que cada ejecucion fuerce desconocimiento mutuo entre escrituras.
escritores_concurrentes_convergen_test() ->
    {ok, [P1, P2, _] = Pids} = simple_kv:start_link(3),
    Padre = self(),
    Marca = make_ref(),
    Clientes = [spawn(fun() ->
        receive {Marca, empezar} ->
            Resultado = simple_kv:put(Pid, color, Valor),
            Padre ! {Marca, terminado, self(), Resultado}
        end
    end) || {Pid, Valor} <- [{P1, rojo}, {P2, azul}]],
    try
        lists:foreach(fun(C) -> C ! {Marca, empezar} end, Clientes),
        lists:foreach(fun(C) ->
            receive {Marca, terminado, C, ok} -> ok
            after 1000 -> erlang:error(escritor_no_termino)
            end
        end, Clientes),
        Plazo = erlang:monotonic_time(millisecond) + 1000,
        esperar_convergencia(Pids, Plazo)
    after
        lists:foreach(fun(C) -> exit(C, kill) end, Clientes),
        simple_kv:stop(Pids)
    end.

%% Prueba interna: un par retiene las respuestas hasta observar dos consultas
%% pendientes a la vez. Las replicas deben seguir atendiendo consultas entre si.
consultas_simultaneas_siguen_atendiendo_pedidos_test() ->
    Padre = self(),
    Marca = make_ref(),
    Gate = spawn(fun() -> retener_consultas(Padre, Marca, []) end),
    P1 = spawn_link(fun simple_kv_replica:init/0),
    P2 = spawn_link(fun simple_kv_replica:init/0),
    P1 ! {peers, [P2, Gate]},
    P2 ! {peers, [P1, Gate]},
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
        Gate ! {Marca, liberar},
        lists:foreach(fun(N) ->
            receive {Marca, lectura, N, R} -> ?assertEqual(not_found, R)
            after 1000 -> erlang:error(consulta_no_termino)
            end
        end, [1, 2])
    after
        %% Liberar primero permite limpiar aun si falla una asercion.
        Gate ! {Marca, liberar},
        lists:foreach(fun(C) -> exit(C, kill) end, Clientes),
        simple_kv:stop([P1, P2]),
        exit(Gate, kill)
    end.

%% Auxiliares de pruebas internas del protocolo, no exportados.
consultar_local(Pid, Key) ->
    Ref = make_ref(),
    Pid ! {consultar, self(), Ref, Key},
    receive
        {respuesta_consulta, Ref, Pid, Resultado} -> Resultado
    after 1000 -> erlang:error(consulta_local_sin_respuesta)
    end.

par_controlado(Padre, Marca, Valores) ->
    receive
        {consultar, Solicitante, Ref, Key} ->
            Padre ! {Marca, consultado, Key},
            Solicitante ! {respuesta_consulta, Ref, self(), maps:find(Key, Valores)},
            par_controlado(Padre, Marca, Valores)
    end.

esperar_convergencia(Pids, Plazo) ->
    Lecturas = [simple_kv:get(P, color) || P <- Pids],
    case lists:usort(Lecturas) of
        [{ok, Valor}] when Valor =:= rojo; Valor =:= azul -> ok;
        _ ->
            case erlang:monotonic_time(millisecond) >= Plazo of
                true -> erlang:error({no_convergen, Lecturas});
                false ->
                    timer:sleep(10),
                    esperar_convergencia(Pids, Plazo)
            end
    end.

retener_consultas(Padre, Marca, Acumuladas) ->
    receive
        {consultar, Solicitante, Ref, _Key} ->
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
