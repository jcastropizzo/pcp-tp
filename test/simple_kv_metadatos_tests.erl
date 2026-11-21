-module(simple_kv_metadatos_tests).
-include_lib("eunit/include/eunit.hrl").
-import(simple_kv_test_utils, [consultar_local/2, escribir/2, esperar/1,
                              esperar_consulta/2, responder_consulta/4,
                              replicas_con_pares_controlados/3]).

cupo_duro_con_replica_demorada_test() ->
    con_cluster(3, 4, fun([P1, P2, P3], Cupos) ->
        true = erlang:suspend_process(P3),
        try
            Limite = 3 * 4 + 1,
            lists:foreach(fun(K) -> ok = simple_kv:delete(P1, K) end, lists:seq(1, Limite)),
            esperar_cupos(Cupos, fun(Reservas) -> map_size(Reservas) =:= Limite end),
            observar(P1, fun({_, _, Meta, _, _, _}) -> map_size(Meta) =:= Limite end),
            con_cliente(fun() -> simple_kv:delete(P2, adicional) end, fun(Cliente, Ref) ->
                esperar_pedido(Cupos, Cliente, adicional),
                true = erlang:resume_process(P3),
                ?assertEqual(ok, resultado(Ref))
            end)
        after
            reanudar(P3)
        end,
        esperar_cupos(Cupos, fun(Reservas) -> map_size(Reservas) =:= 0 end),
        ?assertEqual(not_found, simple_kv:get(P2, adicional))
    end).

borrado_espera_su_clave_y_otras_avanzan_test() ->
    con_cluster(3, 4, fun([P1, P2, P3], Cupos) ->
        true = erlang:suspend_process(P3),
        try
            ok = simple_kv:put(P1, k, rojo),
            ok = simple_kv:put(P2, distinta, verde),
            esperar_cupos(Cupos, fun(Reservas) -> is_map_key(k, Reservas) end),
            con_cliente(fun() -> simple_kv:delete(P2, k) end, fun(Cliente, Ref) ->
                esperar_pedido(Cupos, Cliente, k),
                ?assertEqual({ok, rojo}, simple_kv:get(P1, k)),
                ?assertEqual({ok, verde}, simple_kv:get(P2, distinta)),
                true = erlang:resume_process(P3),
                ?assertEqual(ok, resultado(Ref))
            end)
        after
            reanudar(P3)
        end,
        esperar_olvido(Cupos, k),
        ?assertEqual([not_found, not_found, not_found], lecturas([P1, P2, P3], k)),
        ?assertEqual([{ok, verde}, {ok, verde}, {ok, verde}], lecturas([P1, P2, P3], distinta)),
        ok = simple_kv:put(P3, k, azul),
        ?assertEqual([{ok, azul}, {ok, azul}, {ok, azul}], lecturas([P1, P2, P3], k))
    end).

oferta_atrasada_no_revive_borrado_test() ->
    con_cluster(3, 4, fun([P1, P2, P3], Cupos) ->
        escribir(P1, [k, a, b, c]),
        esperar(fun() ->
            lists:all(fun(P) -> es_valor_local(P, c, c) end, [P1, P2, P3])
        end),
        observar(Cupos, fun({Reservas, Cambios}) ->
            map_size(Reservas) =:= 4 andalso map_size(Cambios) =:= 0
        end),
        con_pausa(ofrecer, 3, P1, fun() ->
            con_cliente(fun() -> simple_kv:put(P1, d, d) end, fun(_, Ref) ->
                esperar_pausa(P1),
                quitar_pausa(),
                ok = simple_kv:delete(P2, k),
                observar(P3, fun({_, _, Meta, _, _, _}) ->
                    case maps:get(k, Meta, ninguna) of {_, borrado, _} -> true; _ -> false end
                end),
                ?assertEqual(not_found, simple_kv:get(P3, k)),
                ok = int:continue(P1),
                ?assertEqual(ok, resultado(Ref)),
                esperar_olvido(Cupos, k),
                observar(P3, fun({_, Valores, Meta, _, _, _}) ->
                    ?assertNot(is_map_key(k, Valores)),
                    not is_map_key(k, Meta)
                end)
            end)
        end),
        ?assertEqual([not_found, not_found, not_found], lecturas([P1, P2, P3], k)),
        ?assertEqual([{ok, d}, {ok, d}, {ok, d}], lecturas([P1, P2, P3], d))
    end).

desalojo_de_ultima_copia_libera_el_cupo_test() ->
    con_cluster(1, 3, fun([P], Cupos) ->
        escribir(P, [k, a, b]),
        esperar_cupos(Cupos, fun(Reservas) -> is_map_key(k, Reservas) end),
        ok = simple_kv:put(P, c, c),
        esperar_olvido(Cupos, k),
        ?assertEqual(error, consultar_local(P, k)),
        ?assertEqual([{ok, a}, {ok, b}, {ok, c}], simple_kv_test_utils:lecturas(P, [a, b, c]))
    end).

%% Las operaciones son de la API. El par controlado solo retiene una
%% respuesta de lectura, y sigue confirmando los envíos y la recolección.
olvido_espera_lectura_con_candidato_viejo_test() ->
    con_replicas(3, 4, fun() ->
        {[P1, P2], [Par]} = replicas_con_pares_controlados(2, 1, 4),
        {[P1, P2], [P1, P2, Par]}
    end, fun([P1, P2], Cupos, [P1, P2, Par]) ->
        con_pausa(replicar, 5, P2, fun() ->
            ok = simple_kv:put(P2, k, rojo),
            esperar_pausa(P2),
            quitar_pausa(),
            con_cliente(fun() -> simple_kv:get(P1, k) end, fun(_, Lectura) ->
                {P1, Consulta} = esperar_consulta(Par, k),
                ok = int:continue(P2),
                observar(P1, fun({_, _, _, _, Pendientes, _}) ->
                    case maps:find(Consulta, Pendientes) of
                        {ok, {_, _, k, [Par], {ok, {_, {valor, rojo, _}}}}} -> true;
                        _ -> false
                    end
                end),
                esperar_cupos(Cupos, fun(Reservas) -> is_map_key(k, Reservas) end),
                ok = simple_kv:delete(P2, k),
                observar(P1, fun({_, _, Meta, _, Pendientes, Cierres}) ->
                    is_map_key(Consulta, Pendientes) andalso is_map_key(k, Cierres)
                        andalso case maps:get(k, Meta, ninguna) of
                            {_, borrado, _} -> true;
                            _ -> false
                        end
                end),
                ?assertEqual(not_found, simple_kv:get(P1, k)),
                ok = responder_consulta(P1, Consulta, Par, error),
                ?assertEqual(not_found, resultado(Lectura)),
                esperar_olvido(Cupos, k)
            end)
        end)
    end).

es_valor_local(P, Clave, Valor) ->
    case consultar_local(P, Clave) of {ok, {_, {valor, Valor, _}}} -> true; _ -> false end.

lecturas(Pids, Clave) -> [simple_kv:get(P, Clave) || P <- Pids].

esperar_pedido(Cupos, Cliente, Clave) ->
    esperar(fun() ->
        {messages, Mensajes} = process_info(Cupos, messages),
        lists:any(fun
            ({pedir_cupo, C, _, K}) -> C =:= Cliente andalso K =:= Clave;
            (_) -> false
        end, Mensajes)
    end),
    ?assert(is_process_alive(Cliente)).

esperar_olvido(Cupos, Clave) ->
    esperar_cupos(Cupos, fun(Reservas) -> not maps:is_key(Clave, Reservas) end).

esperar_cupos(Cupos, Condicion) ->
    observar(Cupos, fun({Reservas, _}) -> Condicion(Reservas) end).

con_cliente(Operacion, Prueba) ->
    Padre = self(),
    Ref = make_ref(),
    Cliente = spawn_link(fun() -> Padre ! {Ref, Operacion()} end),
    try Prueba(Cliente, Ref)
    after unlink(Cliente), exit(Cliente, kill)
    end.

resultado(Ref) ->
    receive {Ref, Resultado} -> Resultado
    after 1000 -> error(cliente_no_termino)
    end.

con_pausa(Funcion, Aridad, Pid, Prueba) ->
    {module, simple_kv_replicacion} = int:i(simple_kv_replicacion),
    try
        ok = int:break_in(simple_kv_replicacion, Funcion, Aridad),
        Prueba()
    after
        quitar_pausa(),
        int:continue(Pid),
        int:n(simple_kv_replicacion)
    end.

quitar_pausa() ->
    ok = int:no_break(simple_kv_replicacion),
    ?assertEqual([], int:all_breaks(simple_kv_replicacion)).

esperar_pausa(Pid) ->
    esperar(fun() ->
        lists:any(fun
            ({P, _, break, {simple_kv_replicacion, _}}) -> P =:= Pid;
            (_) -> false
        end, int:snapshot())
    end).

reanudar(P) ->
    try erlang:resume_process(P) catch error:badarg -> ok end.

con_cluster(N, Alfa, Prueba) ->
    con_replicas(N, Alfa, fun() ->
        {ok, Pids} = simple_kv:start_link(N, Alfa),
        {Pids, Pids}
    end, fun(Pids, Cupos, _) -> Prueba(Pids, Cupos) end).

con_replicas(N, Alfa, Iniciar, Prueba) ->
    {links, Antes} = process_info(self(), links),
    Mods = [{simple_kv_replica, loop, 1}, {simple_kv_cupos, loop, 4}],
    lists:foreach(fun({M, _, _} = MFA) ->
        {module, M} = code:ensure_loaded(M),
        erlang:trace_pattern(MFA, true, [local])
    end, Mods),
    {Pids, Todos} = Iniciar(),
    {links, Despues} = process_info(self(), links),
    [Cupos] = Despues -- (Antes ++ Todos),
    Trazados = [Cupos | Pids],
    Cota = N * Alfa + 1,
    try
        lists:foreach(fun(P) -> erlang:trace(P, true, [call, {tracer, self()}]) end, Trazados),
        Prueba(Pids, Cupos, Todos),
        comprobar_trazas(Trazados, Alfa, Cota)
    after
        lists:foreach(fun(P) -> erlang:trace(P, false, [call]) end, Trazados),
        lists:foreach(fun(MFA) -> erlang:trace_pattern(MFA, false, [local]) end, Mods),
        simple_kv:stop(Todos)
    end,
    ?assertNot(is_process_alive(Cupos)).

observar(Pid, Condicion) ->
    observar(Pid, Condicion, erlang:monotonic_time(millisecond) + 1500).

observar(Pid, Condicion, Plazo) ->
    %% El receive selectivo deja las trazas de otras réplicas para sus propias
    %% esperas. Guarda la traza para la comprobación de todas las cotas al final.
    receive
        {trace, Pid, call, {_, loop, Args}} ->
            self() ! {cota_observada, Args},
            case Condicion(estado(Args)) of
                true -> ok;
                false -> observar(Pid, Condicion, Plazo)
            end
    after max(0, Plazo - erlang:monotonic_time(millisecond)) ->
        error({estado_no_observado, Pid})
    end.

estado([{replica, _, _, _, V, M, R, P, C}]) -> {replica, V, M, R, P, C};
estado([_, _, Cupos, Cambios]) -> {Cupos, Cambios}.

comprobar_trazas(Trazados, Alfa, Cota) ->
    lists:foreach(fun(P) ->
        Ref = erlang:trace_delivered(P),
        receive {trace_delivered, P, Ref} -> ok after 1000 -> error(traza_incompleta) end
    end, Trazados),
    comprobar_cotas(Alfa, Cota).

comprobar_cotas(Alfa, Cota) ->
    receive
        {trace, _, call, {_, loop, Args}} ->
            comprobar_cota(Args, Alfa, Cota), comprobar_cotas(Alfa, Cota);
        {cota_observada, Args} ->
            comprobar_cota(Args, Alfa, Cota), comprobar_cotas(Alfa, Cota)
    after 0 -> ok
    end.

comprobar_cota([{replica, _, _, _, V, M, R, _, C}], Alfa, Cota) ->
    ?assert(map_size(V) =< Alfa),
    ?assert(map_size(R) =< (3 * Alfa + 3) div 4),
    ?assert(map_size(M) =< Cota),
    ?assert(map_size(C) =< Cota);
comprobar_cota([_, Limite, Cupos, Cambios], _, Cota) ->
    ?assertEqual(Cota, Limite),
    ?assert(map_size(Cupos) =< Cota),
    ?assert(map_size(Cambios) =< Cota).
