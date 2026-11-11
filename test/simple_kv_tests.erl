-module(simple_kv_tests).
-include_lib("eunit/include/eunit.hrl").
-import(simple_kv_test_utils, [iniciar/2]).

iniciar_una_replica_escribir_y_leer_devuelve_ok_test() ->
    {ok, [Pid]} = simple_kv:start_link(1, 10),
    ok = simple_kv:put(Pid, color, rojo),
    {ok, ColorVal} = simple_kv:get(Pid, color),
    ?assertEqual(rojo, ColorVal),
    simple_kv:stop([Pid]).


iniciar_tres_replicas_devuelve_replicas_distintas_test() ->
    {ok, Pids} = simple_kv:start_link(3, 10),
    UniquePids = lists:usort(Pids),
    ?assertEqual(3, length(Pids)),
    ?assertEqual(3, length(UniquePids)),
    ?assert(lists:all(fun(Pid) -> is_pid(Pid) andalso is_process_alive(Pid) end, Pids)),
    simple_kv:stop(Pids),
    ?assert(lists:all(fun(Pid) -> is_pid(Pid) andalso not is_process_alive(Pid) end, Pids)).

leer_devuelve_not_found_test() ->
    {ok, [Pid]} = simple_kv:start_link(1, 10),
    ?assertEqual(not_found, simple_kv:get(Pid, color)),
    simple_kv:stop([Pid]).

escribir_leer_borrar_y_leer_devuelve_not_found_test() ->
    {ok, [Pid]} = simple_kv:start_link(1, 10),
    ok = simple_kv:put(Pid, color, rojo),
    ok = simple_kv:delete(Pid, color),
    ?assertEqual(not_found, simple_kv:get(Pid, color)),
    simple_kv:stop([Pid]).

start_link_con_numero_negativo_devuelve_error_test() ->
    ?assertError(function_clause, simple_kv:start_link(-1, 10)).

start_link_con_cero_devuelve_error_test() ->
    ?assertError(function_clause, simple_kv:start_link(0, 10)).

start_link_con_uno_con_decimal_devuelve_error_test() ->
    ?assertError(function_clause, simple_kv:start_link(1.0, 10)).

borrar_clave_inexistente_devuelve_ok_test() ->
    {ok, [Pid]} = simple_kv:start_link(1, 10),
    ?assertEqual(ok, simple_kv:delete(Pid, color)),
    simple_kv:stop([Pid]).

mensaje_desconocido_es_ignorado_test() ->
    {ok, [Pid]} = simple_kv:start_link(1, 10),
    Pid ! {mensaje_desconocido123, a, 123},
    ok = simple_kv:put(Pid, color, rojo),
    {ok, ColorVal} = simple_kv:get(Pid, color),
    ?assertEqual(rojo, ColorVal),
    simple_kv:stop([Pid]).

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

%% La API acepta terminos compuestos y enlaza cada replica al invocante.
terminos_compuestos_y_enlaces_test() ->
    {ok, [P | _] = Pids} = simple_kv:start_link(2, 3),
    try
        {links, Links} = process_info(self(), links),
        ?assert(lists:all(fun(Pid) -> lists:member(Pid, Links) end, Pids)),
        Clave = #{clave => [uno, {dos, 2}]},
        Valor = {self(), <<0, 255>>, #{datos => [1, 2, 3]}},
        ok = simple_kv:put(P, Clave, Valor),
        ?assertEqual({ok, Valor}, simple_kv:get(P, Clave))
    after
        simple_kv:stop(Pids)
    end.

%% Un mensaje inesperado recibido antes de inicializar no queda en el buzon.
init_descarta_mensajes_test() ->
    P = spawn_link(fun simple_kv_replica:init/0),
    P ! inesperado_antes_de_configurar,
    P ! {configurar, [], 3},
    try
        ?assertEqual(not_found, simple_kv:get(P, ausente)),
        ?assertEqual({messages, []}, process_info(P, messages))
    after
        simple_kv:stop([P])
    end.

%% stop espera a una replica viva demorada y retorna con todos los pids terminados.
stop_espera_terminacion_lenta_test() ->
    {ok, [P1, P2] = Pids} = simple_kv:start_link(2, 3),
    true = erlang:suspend_process(P1),
    Padre = self(),
    {Cliente, Monitor} = spawn_monitor(fun() ->
        Resultado = try simple_kv:stop(Pids)
                     catch error:Razon -> {error, Razon}
                     end,
        Padre ! {cierre, self(), Resultado}
    end),
    try
        Plazo = erlang:monotonic_time(millisecond) + 700,
        esperar_stop_en_buzon(P1, Plazo),
        receive
            {cierre, Cliente, {error, Error}} -> error({stop_fallo, Error});
            {cierre, Cliente, Resultado} -> error({stop_no_espero, Resultado});
            {'DOWN', Monitor, process, Cliente, Razon} -> error({stop_fallo, Razon})
        after 1100 -> ok
        end,
        true = erlang:resume_process(P1),
        receive
            {cierre, Cliente, ok} -> ok;
            {cierre, Cliente, {error, ErrorFinal}} -> error({stop_fallo, ErrorFinal});
            {'DOWN', Monitor, process, Cliente, RazonFinal} -> error({stop_fallo, RazonFinal})
        after 1000 -> error(stop_no_termino)
        end,
        ?assertEqual([false, false], [is_process_alive(P) || P <- [P1, P2]])
    after
        exit(Cliente, kill),
        erlang:demonitor(Monitor, [flush]),
        lists:foreach(fun(P) -> unlink(P), exit(P, kill) end, Pids)
    end.

esperar_stop_en_buzon(Pid, Plazo) ->
    {messages, Mensajes} = process_info(Pid, messages),
    case lists:member(stop, Mensajes) of
        true -> ok;
        false ->
            case erlang:monotonic_time(millisecond) >= Plazo of
                true -> error(stop_no_enviado);
                false -> timer:sleep(5), esperar_stop_en_buzon(Pid, Plazo)
            end
    end.
