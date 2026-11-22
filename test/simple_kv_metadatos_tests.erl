-module(simple_kv_metadatos_tests).
-include_lib("eunit/include/eunit.hrl").

metadata_acotada_con_desalojos_test() ->
    medir(desalojo).

metadata_acotada_con_borrados_test() ->
    medir(borrado).

metadata_acotada_con_productores_concurrentes_test() ->
    con_replicas(fun([P1 | _] = Pids) ->
        Padre = self(),
        Ref = make_ref(),
        Clientes = [spawn_link(fun() ->
            lists:foreach(fun(N) ->
                Clave = {P, N},
                ok = simple_kv:put(P, Clave, N),
                case N rem 2 of
                    0 -> ok = simple_kv:delete(P, Clave);
                    1 -> ok
                end
            end, lists:seq(1, 24)),
            Padre ! {Ref, self()}
        end) || P <- Pids],
        try
            lists:foreach(fun(Cliente) ->
                receive {Ref, Cliente} -> ok
                after 1500 -> error({productor_bloqueado, Cliente})
                end
            end, Clientes),
            %% La última escritura debe llegar a todos pese al tráfico y las
            %% reaperturas concurrentes. Las trazas comprueban las tres cotas.
            ok = simple_kv:put(P1, ultima, final),
            esperar_estados(Pids, fun({V, _, _, _, _}) ->
                case maps:find(ultima, V) of
                    {ok, {_, {valor, final, _}}} -> true;
                    _ -> false
                end
            end, observacion()),
            ?assertEqual([{ok, final}, {ok, final}, {ok, final}], lecturas(Pids, ultima))
        after
            lists:foreach(fun(C) -> unlink(C), exit(C, kill) end, Clientes)
        end
    end).

medir(Modo) ->
    con_replicas(fun([Origen | _] = Pids) ->
        Alfa = 4,
        lists:foldl(fun(Tanda, Observacion) ->
            Claves = [{Modo, Tanda, N} || N <- lists:seq(1, 12)],
            lists:foreach(fun(K) ->
                ok = simple_kv:put(Origen, K, K),
                case Modo of
                    borrado -> ok = simple_kv:delete(Origen, K);
                    desalojo -> ok
                end
            end, Claves),
            Rondas = case Modo of desalojo -> 3; borrado -> 6 end,
            {Estados, _} = Siguiente = esperar_tanda(Pids, Tanda * Rondas, Observacion),
            Esperado = case Modo of desalojo -> Alfa; borrado -> 0 end,
            lists:foreach(fun(P) ->
                {Valores, Meta, _, _, _} = maps:get(P, Estados),
                ?assertEqual(Esperado, map_size(Valores)),
                ?assertEqual(Esperado, map_size(Meta))
            end, Pids),
            Siguiente
        end, observacion(), lists:seq(1, 5))
    end).

%% La escritura original quedó pausada después del ok local y antes del envío.
%% Las operaciones son de la API y las versiones las genera la implementación.
escritura_demorada_no_revive_y_se_puede_reutilizar_test() ->
    con_envio_pausable(replicar, fun([P1, P2, P3] = Pids) ->
        ok = simple_kv:put(P1, k, rojo),
        esperar_break(P1),
        ok = int:no_break(simple_kv_replicacion),
        ?assertEqual([], int:all_breaks(simple_kv_replicacion)),
        ok = simple_kv:delete(P2, k),
        borrar_relleno(P2, 3),
        Cerrando = esperar_estados([P2, P3], fun({_, M, _, _, {_, Fase}}) ->
            es_marca_borrado(k, M) andalso Fase =/= abierta
        end, observacion()),
        ?assertEqual(not_found, simple_kv:get(P3, k)),
        %% La siguiente operación queda sin admitir mientras falta P1.
        Padre = self(),
        Ref = make_ref(),
        Cliente = spawn_link(fun() ->
            Padre ! {Ref, simple_kv:delete(P2, siguiente)}
        end),
        try
            esperar(fun() ->
                {messages, Mensajes} = process_info(P2, messages),
                lists:any(fun
                    ({delete, P, _, siguiente}) -> P =:= Cliente;
                    (_) -> false
                end, Mensajes)
            end),
            ?assert(is_process_alive(Cliente)),
            ok = int:continue(P1),
            esperar_cliente(Ref),
            Abierta = esperar_tanda(Pids, 1, Cerrando),
            comprobar_borrada(Pids, Abierta),
            ok = simple_kv:put(P3, k, azul),
            esperar_estados(Pids, fun({V, _, _, _, _}) ->
                case maps:find(k, V) of
                    {ok, {_, {valor, azul, _}}} -> true;
                    _ -> false
                end
            end, Abierta),
            ?assertEqual([{ok, azul}, {ok, azul}, {ok, azul}], lecturas(Pids, k))
        after
            unlink(Cliente),
            exit(Cliente, kill)
        end
    end).

%% Incluso una oferta disparada antes del borrado se procesa con su marca vigente.
oferta_demorada_no_revive_borrado_test() ->
    con_replicas(fun([P1, P2, P3] = Pids) ->
        simple_kv_test_utils:escribir(P1, [k, a, b, c]),
        Inicial = esperar_tanda(Pids, 1, observacion()),
        con_punto_de_pausa(ofrecer, P1, fun() ->
            Padre = self(),
            Ref = make_ref(),
            Cliente = spawn_link(fun() ->
                Padre ! {Ref, simple_kv:put(P1, d, d)}
            end),
            try
                esperar_break(P1),
                ok = int:no_break(simple_kv_replicacion),
                ?assertEqual([], int:all_breaks(simple_kv_replicacion)),
                ok = simple_kv:delete(P2, k),
                borrar_relleno(P2, 3),
                Cerrando = esperar_estados([P2, P3], fun({_, M, _, _, {_, Fase}}) ->
                    es_marca_borrado(k, M) andalso Fase =/= abierta
                end, Inicial),
                ?assertEqual(not_found, simple_kv:get(P3, k)),
                ok = int:continue(P1),
                esperar_cliente(Ref),
                Abierta = esperar_tanda(Pids, 2, vigilar_ausencia(k, [P2, P3], Cerrando)),
                comprobar_borrada(Pids, Abierta),
                ?assertEqual([{ok, d}, {ok, d}, {ok, d}], lecturas(Pids, d))
            after
                unlink(Cliente),
                exit(Cliente, kill)
            end
        end)
    end).

%% Una lectura ya abierta guarda un candidato rojo antes del borrado y
%% termina durante el cierre, cuando llega la respuesta del último par.
lectura_pendiente_no_restaura_candidato_borrado_test() ->
    con_replicas(fun([P1, P2, P3] = Pids) ->
        con_punto_de_pausa(replicar, P2, fun() ->
            true = erlang:suspend_process(P3),
            Padre = self(),
            Ref = make_ref(),
            try
                ok = simple_kv:put(P2, k, rojo),
                esperar_break(P2),
                ok = int:no_break(simple_kv_replicacion),
                ?assertEqual([], int:all_breaks(simple_kv_replicacion)),
                spawn_link(fun() -> Padre ! {Ref, simple_kv:get(P1, k)} end),
                Consultando = esperar_estados([P1], fun({_, _, _, Pendientes, _}) ->
                    map_size(Pendientes) =:= 1
                end, observacion()),
                ok = int:continue(P2),
                ConCandidato = esperar_estados([P1], fun({_, _, _, Pendientes, _}) ->
                    case maps:values(Pendientes) of
                        [{_, _, k, [P3], {ok, {_, {valor, rojo, _}}}}] -> true;
                        _ -> false
                    end
                end, Consultando),
                ok = simple_kv:delete(P2, k),
                borrar_relleno(P2, 2),
                Cerrando = esperar_estados([P1], fun({_, M, _, Pendientes, Estado}) ->
                    es_marca_borrado(k, M) andalso map_size(Pendientes) =:= 1
                        andalso Estado =:= {0, cerrando}
                end, ConCandidato),
                true = erlang:resume_process(P3),
                receive
                    {Ref, Resultado} -> ?assertEqual(not_found, Resultado)
                after 1000 -> error(lectura_no_termino)
                end,
                comprobar_borrada(Pids, esperar_tanda(Pids, 1, Cerrando))
            after
                try erlang:resume_process(P3) catch error:badarg -> ok end
            end
        end)
    end).

es_marca_borrado(Clave, Meta) ->
    case maps:find(Clave, Meta) of {ok, {_, borrado}} -> true; _ -> false end.

comprobar_borrada(Pids, {Estados, _}) ->
    lists:foreach(fun(P) ->
        {V, M, _, _, _} = maps:get(P, Estados),
        ?assertNot(maps:is_key(k, V)),
        ?assertNot(maps:is_key(k, M))
    end, Pids),
    ?assertEqual([not_found, not_found, not_found], lecturas(Pids, k)).

lecturas(Pids, Clave) -> [simple_kv:get(P, Clave) || P <- Pids].

borrar_relleno(Pid, Cantidad) ->
    lists:foreach(fun(N) ->
        ok = simple_kv:delete(Pid, {relleno, N})
    end, lists:seq(1, Cantidad)).

esperar_cliente(Ref) ->
    receive {Ref, ok} -> ok
    after 1000 -> error(cliente_no_termino)
    end.

con_envio_pausable(Funcion, Prueba) ->
    con_replicas(fun([P1 | _] = Pids) ->
        con_punto_de_pausa(Funcion, P1, fun() -> Prueba(Pids) end)
    end).

con_punto_de_pausa(Funcion, Pid, Prueba) ->
    Modulo = simple_kv_replicacion,
    ?assertNot(lists:member(Modulo, int:interpreted())),
    {module, Modulo} = int:i(Modulo),
    try
        ok = int:break_in(Modulo, Funcion, 3),
        Prueba()
    after
        int:no_break(Modulo),
        int:continue(Pid),
        int:n(Modulo)
    end.

esperar_break(Pid) ->
    esperar(fun() ->
        lists:any(fun
            ({P, _, break, {simple_kv_replicacion, _}}) -> P =:= Pid;
            (_) -> false
        end, int:snapshot())
    end).

con_replicas(Prueba) ->
    {module, simple_kv_replica} = code:ensure_loaded(simple_kv_replica),
    erlang:trace_pattern({simple_kv_replica, loop, 7}, true, [local]),
    {ok, Pids} = simple_kv:start_link(3, 4),
    try
        lists:foreach(fun(P) ->
            erlang:trace(P, true, [call, {tracer, self()}])
        end, Pids),
        Prueba(Pids)
    after
        lists:foreach(fun(P) -> erlang:trace(P, false, [call]) end, Pids),
        erlang:trace_pattern({simple_kv_replica, loop, 7}, false, [local]),
        simple_kv:stop(Pids),
        recolectar_trazas(observacion())
    end.

observacion() -> {#{}, #{}}.

vigilar_ausencia(Clave, Pids, {Estados, Vigiladas}) ->
    {Estados, lists:foldl(fun(P, Acc) -> Acc#{P => Clave} end, Vigiladas, Pids)}.

esperar_tanda(Pids, Numero, Observacion) ->
    esperar_estados(Pids, fun({_, _, _, Pendientes, Estado}) ->
        Estado =:= {Numero, abierta} andalso map_size(Pendientes) =:= 0
    end, Observacion).

esperar_estados(Pids, Predicado, Observacion) ->
    esperar(fun(Anterior) ->
        {Estados, _} = Nueva = sincronizar_trazas(Anterior),
        Listos = lists:all(fun(P) ->
            case maps:find(P, Estados) of
                {ok, Estado} -> Predicado(Estado);
                error -> false
            end
        end, Pids),
        case Listos of true -> {ok, Nueva}; false -> {esperar, Nueva} end
    end, Observacion, erlang:monotonic_time(millisecond) + 1500).

esperar(Predicado) ->
    esperar(fun(ok) ->
        case Predicado() of true -> {ok, ok}; false -> {esperar, ok} end
    end, ok, erlang:monotonic_time(millisecond) + 1500).

esperar(Funcion, Estado, Plazo) ->
    case Funcion(Estado) of
        {ok, Resultado} -> Resultado;
        {esperar, Siguiente} ->
            ?assert(erlang:monotonic_time(millisecond) < Plazo),
            timer:sleep(1),
            esperar(Funcion, Siguiente, Plazo)
    end.

sincronizar_trazas(Observacion) ->
    Ref = erlang:trace_delivered(all),
    receive {trace_delivered, all, Ref} -> ok
    after 1000 -> error(trazas_no_entregadas)
    end,
    recolectar_trazas(Observacion).

recolectar_trazas({Estados, Vigiladas} = Observacion) ->
    receive
        {trace, P, call, {simple_kv_replica, loop,
                         [Pares, Alfa, V, M, R, Pendientes, Tanda]}} ->
            N = length(Pares) + 1,
            Estado = simple_kv_tandas:estado(Tanda),
            ?assert(map_size(V) =< Alfa),
            ?assert(map_size(M) =< 2 * N * Alfa),
            ?assert(map_size(R) =< (3 * Alfa + 3) div 4),
            case Estado of
                {_, compactada} -> ?assert(map_size(M) =< N * Alfa);
                _ -> ok
            end,
            case maps:find(P, Vigiladas) of
                {ok, Clave} -> ?assertNot(maps:is_key(Clave, V));
                error -> ok
            end,
            recolectar_trazas({Estados#{P => {V, M, R, Pendientes, Estado}}, Vigiladas})
    after 0 -> Observacion
    end.
