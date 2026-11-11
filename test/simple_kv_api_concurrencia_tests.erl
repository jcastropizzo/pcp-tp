-module(simple_kv_api_concurrencia_tests).
-include_lib("eunit/include/eunit.hrl").

%% Puts y delete simultaneos sobre una clave deben terminar y converger.
conflicto_concurrente_por_api_test() ->
    {ok, [P1, P2, P3] = Ps} = simple_kv:start_link(3, 8),
    try
        ok = simple_kv:put(P1, clave, inicial),
        concurrir([fun() -> simple_kv:put(P1, clave, uno) end,
                   fun() -> simple_kv:put(P2, clave, dos) end,
                   fun() -> simple_kv:delete(P3, clave) end]),
        Resultado = esperar_acuerdo(Ps, clave, erlang:monotonic_time(millisecond) + 2000),
        ?assert(lists:member(Resultado, [not_found, {ok, uno}, {ok, dos}])),
        ok = simple_kv:put(P3, clave, final),
        lists:foreach(fun(P) -> simple_kv_test_utils:esperar_valor(P, clave, {ok, final}, 2000) end, Ps)
    after simple_kv:stop(Ps) end.

%% Consultas simultaneas y escrituras sobre otras claves terminan por la API.
lecturas_y_escrituras_simultaneas_por_api_test() ->
    {ok, [P1, P2, P3] = Ps} = simple_kv:start_link(3, 8),
    try
        ok = simple_kv:put(P1, estable, conocido),
        concurrir([fun() -> ?assertEqual({ok, conocido}, simple_kv:get(P1, estable)), ok end,
                   fun() -> ?assertEqual({ok, conocido}, simple_kv:get(P2, estable)), ok end,
                   fun() -> ?assertEqual({ok, conocido}, simple_kv:get(P3, estable)), ok end,
                   fun() -> simple_kv:put(P1, otra, valor) end,
                   fun() -> ?assertEqual(not_found, simple_kv:get(P3, ausente)), ok end]),
        lists:foreach(fun(P) -> simple_kv_test_utils:esperar_valor(P, otra, {ok, valor}, 2000) end, Ps)
    after simple_kv:stop(Ps) end.

%% Libera los clientes juntos y exige que cada operacion termine sin error.
concurrir(Funciones) ->
    Parent = self(),
    Procesos = [spawn_monitor(fun() ->
        receive arrancar -> ok end,
        Parent ! {resultado, self(), F()}
    end) || F <- Funciones],
    lists:foreach(fun({Pid, _}) -> Pid ! arrancar end, Procesos),
    try lists:foreach(fun({Pid, Ref}) ->
        receive
            {resultado, Pid, Resultado} -> ?assertEqual(ok, Resultado);
            {'DOWN', Ref, process, Pid, Razon} -> error({cliente_fallo, Razon})
        after 3000 -> error({cliente_no_termino, Pid})
        end,
        receive {'DOWN', Ref, process, Pid, normal} -> ok
        after 3000 -> error({cliente_no_finalizo, Pid}) end
    end, Procesos)
    after lists:foreach(fun({Pid, Ref}) -> exit(Pid, kill), erlang:demonitor(Ref, [flush]) end, Procesos) end.

%% Espera que las lecturas publicas coincidan despues de terminar los escritores.
esperar_acuerdo(Ps, Key, Plazo) ->
    Respuestas = [simple_kv:get(P, Key) || P <- Ps],
    case lists:usort(Respuestas) of
        [Unica] -> Unica;
        _ ->
            case erlang:monotonic_time(millisecond) >= Plazo of
                true -> error({sin_acuerdo, Respuestas});
                false -> receive after 5 -> ok end, esperar_acuerdo(Ps, Key, Plazo)
            end
    end.
