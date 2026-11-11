-module(simple_kv_replicacion_tests).
-include_lib("eunit/include/eunit.hrl").
-import(simple_kv_test_utils, [consultar_local/2]).

elige_mayor_sin_importar_orden_test() ->
    Vieja = {ok, {3, borrado}},
    Nueva = {ok, {8, {valor, rojo, infinity}}},
    ?assertEqual(Nueva, simple_kv_replicacion:elegir_mayor(Vieja, Nueva)),
    ?assertEqual(Nueva, simple_kv_replicacion:elegir_mayor(Nueva, Vieja)).

sin_informacion_conserva_la_otra_test() ->
    Entrada = {ok, {8, borrado}},
    ?assertEqual(Entrada, simple_kv_replicacion:elegir_mayor(error, Entrada)),
    ?assertEqual(Entrada, simple_kv_replicacion:elegir_mayor(Entrada, error)).

%% Prueba interna: entrega primero un borrado y luego una escritura anterior.
mensaje_viejo_no_resucita_borrado_test() ->
    {ok, [Pid]} = simple_kv:start_link(1, 16),
    try
        Pid ! {replicar, color, {20, borrado}},
        Pid ! {replicar, color, {10, {valor, rojo, infinity}}},
        ?assertEqual({ok, {20, borrado}}, consultar_local(Pid, color)),
        ?assertEqual(not_found, simple_kv:get(Pid, color))
    after
        simple_kv:stop([Pid])
    end.

%% Prueba interna: fuerza los dos ordenes de entrega en replicas reales.
ordenes_opuestos_convergen_a_misma_version_test() ->
    {ok, [P1, P2] = Pids} = simple_kv:start_link(2, 16),
    Vieja = {10, {valor, rojo, infinity}},
    Nueva = {20, {valor, azul, infinity}},
    try
        P1 ! {replicar, color, Vieja},
        P1 ! {replicar, color, Nueva},
        P2 ! {replicar, color, Nueva},
        P2 ! {replicar, color, Vieja},
        ?assertEqual({ok, Nueva}, consultar_local(P1, color)),
        ?assertEqual({ok, Nueva}, consultar_local(P2, color))
    after
        simple_kv:stop(Pids)
    end.

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
    {ok, [P]} = simple_kv:start_link(1, 3),
    try
        P ! {replicar, k, {20, {valor, nuevo, infinity}}},
        P ! {replicar, k, {10, borrado}},
        ?assertEqual({ok, nuevo}, simple_kv:get(P, k))
    after
        simple_kv:stop([P])
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
