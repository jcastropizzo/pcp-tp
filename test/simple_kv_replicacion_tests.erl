-module(simple_kv_replicacion_tests).
-include_lib("eunit/include/eunit.hrl").

elige_mayor_sin_importar_orden_test() ->
    Vieja = {ok, {3, borrado}},
    Nueva = {ok, {8, {valor, rojo, infinity}}},
    ?assertEqual(Nueva, simple_kv_replicacion:elegir_mayor(Vieja, Nueva)),
    ?assertEqual(Nueva, simple_kv_replicacion:elegir_mayor(Nueva, Vieja)).

sin_informacion_conserva_la_otra_test() ->
    Entrada = {ok, {8, borrado}},
    ?assertEqual(Entrada, simple_kv_replicacion:elegir_mayor(error, Entrada)),
    ?assertEqual(Entrada, simple_kv_replicacion:elegir_mayor(Entrada, error)).

mensaje_viejo_no_resucita_borrado_test() ->
    Vieja = {10, {valor, rojo, infinity}},
    ?assertEqual({ok, {20, borrado}}, aplicar_en_orden([{20, borrado}, Vieja])).

ordenes_opuestos_convergen_a_misma_version_test() ->
    Vieja = {10, {valor, rojo, infinity}},
    Nueva = {20, {valor, azul, infinity}},
    ?assertEqual({ok, Nueva}, aplicar_en_orden([Vieja, Nueva])),
    ?assertEqual({ok, Nueva}, aplicar_en_orden([Nueva, Vieja])).

%% Dos clientes arrancan juntos. La prueba espera acuerdo observable en un valor escrito.
escritores_concurrentes_convergen_test() ->
    {ok, [P1, P2, _] = Pids} = simple_kv:start_link(3, 16),
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

%% Un delete replicado viejo no reemplaza una escritura de mayor version.
delete_replicado_viejo_conserva_valor_nuevo_test() ->
    Nueva = {20, {valor, nuevo, infinity}},
    ?assertEqual({ok, Nueva}, aplicar_en_orden([Nueva, {10, borrado}])).

aplicar_en_orden(Entradas) ->
    Reserva = make_ref(),
    {V, M} = lists:foldl(fun(Entrada, {Valores, Meta}) ->
        {simple_kv_almacen:aplicar_actualizacion(color, Entrada, Valores, Meta),
         simple_kv_almacen:registrar_metadatos(color, Reserva, Entrada, Meta)}
    end, {#{}, #{}}, Entradas),
    simple_kv_almacen:buscar_local(color, V, M).

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

escribir_en_p1_replica_leer_en_p2_test()->
    {ok, Pids} = simple_kv:start_link(3, 10),
    [Pid1, Pid2, Pid3] = Pids,
    try
        ok = simple_kv:put(Pid1, color, rojo),
        simple_kv_test_utils:esperar_valor(Pid2,color,{ok,rojo},1000),
        simple_kv_test_utils:esperar_valor(Pid3,color,{ok, rojo},1000)
    after
        simple_kv:stop(Pids)
    end.

borrar_en_p2_replica_en_otras_test()->
    {ok, Pids} = simple_kv:start_link(3, 10),
    [Pid1, Pid2, Pid3] = Pids,
    try
        ok = simple_kv:put(Pid1, color, rojo),
        simple_kv_test_utils:esperar_valor(Pid2,color,{ok,rojo},1000),
        simple_kv_test_utils:esperar_valor(Pid3,color,{ok, rojo},1000),
        ok = simple_kv:delete(Pid2, color),
        simple_kv_test_utils:esperar_valor(Pid1, color, not_found, 1000),
        simple_kv_test_utils:esperar_valor(Pid3, color, not_found, 1000),
        ok = simple_kv:put(Pid3, color, azul),
        simple_kv_test_utils:esperar_valor(Pid2,color,{ok,azul},1000),
        simple_kv_test_utils:esperar_valor(Pid1,color,{ok, azul},1000)
    after
        simple_kv:stop(Pids)
    end.
