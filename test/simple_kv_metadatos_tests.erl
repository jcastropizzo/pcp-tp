-module(simple_kv_metadatos_tests).
-include_lib("eunit/include/eunit.hrl").

%% Tres replicas, alfa = 4: cupo = 2 * 4 = 8 por replica.
%% Se mide con propagacion estabilizada. Los tests adversos al final deben
%% fallar mientras el cupo permita olvidar un borrado y revivir el valor.
metadata_se_estabiliza_con_desalojos_test() ->
    medir(desalojo).

metadata_se_estabiliza_con_borrados_test() ->
    medir(borrado).

medir(Modo) ->
    {module, simple_kv_replica} = code:ensure_loaded(simple_kv_replica),
    erlang:trace_pattern({simple_kv_replica, loop, 6}, true, [local]),
    {ok, [Origen | _] = Pids} = simple_kv:start_link(3, 4),
    try
        [erlang:trace(P, true, [call, send, 'receive', {tracer, self()}]) || P <- Pids],
        {Muestras, _} = lists:mapfoldl(
            fun(Tanda, Observacion) ->
                Claves = [{Modo, Tanda, N} || N <- lists:seq(1, 12)],
                lists:foreach(fun(K) ->
                    ok = simple_kv:put(Origen, K, K),
                    case Modo of
                        borrado -> ok = simple_kv:delete(Origen, K);
                        desalojo -> ok
                    end
                end, Claves),
                {Estados, _} = Estable = estabilizar(Pids, Observacion),
                Medidas = [medida(maps:get(P, Estados)) || P <- Pids],
                Valores = case Modo of desalojo -> 4; borrado -> 0 end,
                %% Cada fila contiene {valores, metadata, recientes} por replica.
                lists:foreach(fun({V, M, R}) ->
                    ?assertEqual(Valores, V),
                    ?assert(M =< 8),
                    ?assert(R =< 3)
                end, Medidas),
                {Medidas, Estable}
            end,
            {#{}, 0}, lists:seq(1, 5)),
        ?debugFmt("~p: tandas de 12; {valores, metadata, recientes}: ~p", [Modo, Muestras]),
        [_Primera, _Segunda, Base | Posteriores] = Muestras,
        lists:foreach(fun(Muestra) ->
            lists:foreach(fun({{_V0, MetadataBase, _R0}, {_V, MetadataActual, _R}}) ->
                ?assert(MetadataActual =< MetadataBase)
            end, lists:zip(Base, Muestra))
        end, Posteriores)
    after
        [erlang:trace(P, false, [all]) || P <- Pids],
        erlang:trace_pattern({simple_kv_replica, loop, 6}, false, [local]),
        simple_kv:stop(Pids),
        recoger_trazas({#{}, 0})
    end.

medida({Valores, Metadatos, Recientes, Pendientes}) ->
    ?assertEqual(0, map_size(Pendientes)),
    {map_size(Valores), map_size(Metadatos), map_size(Recientes)}.

estabilizar(Pids, Observacion) ->
    estabilizar(Pids, Observacion, erlang:monotonic_time(millisecond) + 2000).

estabilizar(Pids, Observacion, Plazo) ->
    Antes = sincronizar_trazas(Observacion),
    Reposo = lists:all(fun(P) ->
        process_info(P, [status, message_queue_len]) =:=
            [{status, waiting}, {message_queue_len, 0}]
    end, Pids),
    {Estados, _} = Despues = sincronizar_trazas(Antes),
    %% Los contadores incluyen recepciones y envios: no basta con que el
    %% estado coincida si una oferta recorrio los buzones durante el muestreo.
    case Reposo andalso Antes =:= Despues andalso map_size(Estados) =:= length(Pids) of
        true -> Despues;
        false ->
            case erlang:monotonic_time(millisecond) >= Plazo of
                true -> error({propagacion_no_estabilizada, Despues});
                false ->
                    timer:sleep(1),
                    estabilizar(Pids, Despues, Plazo)
            end
    end.

sincronizar_trazas(Observacion) ->
    Ref = erlang:trace_delivered(all),
    receive {trace_delivered, all, Ref} -> ok
    after 1000 -> error(trazas_no_entregadas)
    end,
    recoger_trazas(Observacion).

recoger_trazas({Estados, N}) ->
    receive
        {trace, P, call, {simple_kv_replica, loop,
                         [_Pares, _Alfa, Valores, Metadatos, Recientes, Pendientes]}} ->
            recoger_trazas({maps:put(P, {Valores, Metadatos, Recientes, Pendientes}, Estados), N + 1});
        {trace, _P, send, _Mensaje, _Destino} ->
            recoger_trazas({Estados, N + 1});
        {trace, _P, 'receive', _Mensaje} ->
            recoger_trazas({Estados, N + 1})
    after 0 -> {Estados, N}
    end.

replica_unica_conserva_valores_con_cupo_alfa_test() ->
    {ok, [P]} = simple_kv:start_link(1, 4),
    try
        simple_kv_test_utils:escribir(P, [a, b, c, d, e, f]),
        lists:foreach(fun(K) -> ?assertEqual({ok, K}, simple_kv:get(P, K)) end,
                      [c, d, e, f])
    after simple_kv:stop([P]) end.

%% Limitaciones conocidas: se exige not_found y se expone el incumplimiento.
escritura_vieja_no_debe_revivir_borrado_recolectado_test() ->
    borrado_recolectado(replicar).

oferta_vieja_no_debe_revivir_borrado_recolectado_test() ->
    borrado_recolectado(ofrecer).

borrado_recolectado(Tipo) ->
    {ok, [P1, _P2, P3] = Pids} = simple_kv:start_link(3, 4),
    A = spawn_link(fun emisor_controlado/0),
    B = spawn_link(fun emisor_controlado/0),
    Vieja = {simple_kv_replicacion:nueva_version(), {valor, rojo, infinity}},
    Borrado = {simple_kv_replicacion:nueva_version(), borrado},
    try
        %% Dos emisores distintos inyectan el orden de entrega del ejemplo.
        %% No son los procesos de origen reales: el arnes controla el protocolo.
        entregar(A, [P1], {replicar, k, Vieja}, k),
        entregar(B, Pids, {replicar, k, Borrado}, k),
        lists:foreach(fun(N) ->
            K = {relleno, N},
            Entrada = {simple_kv_replicacion:nueva_version(), borrado},
            entregar(B, Pids, {replicar, K, Entrada}, K)
        end, lists:seq(1, 8)),
        lists:foreach(fun(P) ->
            ?assertEqual(error, simple_kv_test_utils:consultar_local(P, k))
        end, Pids),
        entregar(A, [P3], {Tipo, k, Vieja}, k),
        ?assertEqual(not_found, simple_kv:get(P3, k))
    after
        A ! stop,
        B ! stop,
        simple_kv:stop(Pids)
    end.

entregar(Emisor, Destinos, Mensaje, Clave) ->
    Ref = make_ref(),
    Emisor ! {entregar, self(), Ref, Destinos, Mensaje, Clave},
    receive {Ref, entregado} -> ok
    after 1000 -> error(entrega_controlada_sin_respuesta)
    end.

emisor_controlado() ->
    receive
        {entregar, Cliente, Ref, Destinos, Mensaje, Clave} ->
            lists:foreach(fun(P) ->
                P ! Mensaje,
                %% La consulta del mismo emisor es una barrera FIFO.
                simple_kv_test_utils:consultar_local(P, Clave)
            end, Destinos),
            Cliente ! {Ref, entregado},
            emisor_controlado();
        stop -> ok
    end.
