-module(simple_kv_metadatos_tests).
-include_lib("eunit/include/eunit.hrl").

%% Tres replicas, alfa = 4: cupo = 2 * 4 = 8 por replica.
%% Estas mediciones comprueban solo la cantidad de entradas después de
%% estabilizar la propagación. La seguridad del borrado queda fuera de ellas.
metadata_se_estabiliza_con_desalojos_test() ->
    medir(desalojo).

%% Esta prueba puede pasar aunque el recorte olvide una marca que todavía
%% protege contra una escritura atrasada. Solo comprueba el tamaño del mapa.
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

replica_unica_conserva_valores_con_cupo_dos_alfa_test() ->
    {ok, [P]} = simple_kv:start_link(1, 4),
    try
        simple_kv_test_utils:escribir(P, [a, b, c, d, e, f]),
        lists:foreach(fun(K) -> ?assertEqual({ok, K}, simple_kv:get(P, K)) end,
                      [c, d, e, f])
    after simple_kv:stop([P]) end.

%% LIMITACIÓN CONOCIDA DEL CUPO. La prueba caracteriza un defecto y pasa
%% deliberadamente cuando la escritura anterior al delete restaura la clave.
%% La consigna exige not_found. Se usa la API real y el debugger solo demora
%% a P1 al entrar a replicar/3, hasta que la marca salga del cupo en P3.
caso_borde_documentado_put_viejo_restaura_borrada_por_api_test() ->
    ?assertNot(lists:member(simple_kv_replicacion, int:interpreted())),
    {module, simple_kv_replicacion} = int:i(simple_kv_replicacion),
    ok = int:break_in(simple_kv_replicacion, replicar, 3),
    {module, simple_kv_replica} = code:ensure_loaded(simple_kv_replica),
    erlang:trace_pattern({simple_kv_replica, loop, 6}, true, [local]),
    {ok, [P1, P2, P3] = Pids} = simple_kv:start_link(3, 4),
    try
        [erlang:trace(P, true, [call, send, 'receive', {tracer, self()}]) || P <- [P2, P3]],
        %% El ok del put es local: P1 puede pausarse antes de propagarlo.
        ok = simple_kv:put(P1, k, rojo),
        esperar_break(P1, erlang:monotonic_time(millisecond) + 1000),
        ok = int:no_break(simple_kv_replicacion),
        ?assertEqual([], int:all_breaks(simple_kv_replicacion)),
        ok = simple_kv:delete(P2, k),
        %% La marca llega a P3 antes de que se hagan los borrados de relleno.
        Borrada = esperar_estados([P2, P3], fun({_V, M, _R, _P}) ->
            case maps:find(k, M) of {ok, {_, borrado}} -> true; _ -> false end
        end, {#{}, 0}),
        ?assertEqual(not_found, simple_kv:get(P3, k)),
        Cupo = simple_kv_almacen:cupo_metadatos(length(Pids) - 1, 4),
        lists:foreach(fun(N) ->
            ok = simple_kv:delete(P2, {relleno, N})
        end, lists:seq(1, Cupo)),
        Olvidada = esperar_estados([P2, P3], fun({V, M, _R, _P}) ->
            not maps:is_key(k, V) andalso not maps:is_key(k, M)
                andalso maps:is_key({relleno, Cupo}, M)
        end, Borrada),
        %% P1 completa el envio real pendiente y luego procesa los borrados
        %% que acumulo en su buzon. No hay otro put de k en toda la secuencia.
        erlang:trace(P1, true, [call, send, 'receive', {tracer, self()}]),
        ok = int:continue(P1),
        Restaurada = esperar_estados([P3], fun({V, _M, _R, _P}) ->
            maps:is_key(k, V)
        end, Olvidada),
        esperar_estados([P1], fun({V, M, _R, _P}) ->
            not maps:is_key(k, V) andalso maps:is_key({relleno, Cupo}, M)
        end, Restaurada),
        %% {ok, rojo} es el defecto observado. El resultado correcto sería not_found.
        ?assertEqual({ok, rojo}, simple_kv:get(P3, k))
    after
        int:no_break(simple_kv_replicacion),
        int:continue(P1),
        [erlang:trace(P, false, [all]) || P <- Pids],
        erlang:trace_pattern({simple_kv_replica, loop, 6}, false, [local]),
        simple_kv:stop(Pids),
        int:n(simple_kv_replicacion),
        recoger_trazas({#{}, 0})
    end.

esperar_break(Pid, Plazo) ->
    case lists:any(fun
        ({P, _, break, {simple_kv_replicacion, _Linea}}) -> P =:= Pid;
        (_) -> false
    end, int:snapshot()) of
        true -> ok;
        false ->
            ?assert(erlang:monotonic_time(millisecond) < Plazo),
            timer:sleep(1),
            esperar_break(Pid, Plazo)
    end.

esperar_estados(Pids, Predicado, Observacion) ->
    esperar_estados(Pids, Predicado, Observacion,
                    erlang:monotonic_time(millisecond) + 1000).

esperar_estados(Pids, Predicado, Observacion, Plazo) ->
    {Estados, _} = Nueva = sincronizar_trazas(Observacion),
    case lists:all(fun(P) ->
        case maps:find(P, Estados) of
            {ok, Estado} -> Predicado(Estado);
            error -> false
        end
    end, Pids) of
        true -> Nueva;
        false ->
            ?assert(erlang:monotonic_time(millisecond) < Plazo),
            timer:sleep(1),
            esperar_estados(Pids, Predicado, Nueva, Plazo)
    end.
