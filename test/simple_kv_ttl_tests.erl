-module(simple_kv_ttl_tests).
-include_lib("eunit/include/eunit.hrl").

infinity_no_vence_test() ->
    ?assertEqual(infinity, simple_kv_ttl:calcular_vencimiento(infinity)),
    ?assert(simple_kv_ttl:vigente(infinity)).

instante_pasado_no_esta_vigente_test() ->
    Pasado = erlang:monotonic_time(millisecond) - 1,
    ?assertNot(simple_kv_ttl:vigente(Pasado)).

ttl_cero_nace_vencido_test() ->
    ?assertNot(simple_kv_ttl:vigente(simple_kv_ttl:calcular_vencimiento(0))).

escribir_con_tiempo_negativo_devuelve_error_test() ->
    {ok, [Pid]} = simple_kv:start_link(1, 10),
    try
        ?assertError(function_clause, simple_kv:put(Pid, color, rojo, -1)),
        ok = simple_kv:put(Pid, color, rojo),
        {ok, ColorVal} = simple_kv:get(Pid, color),
        ?assertEqual(rojo, ColorVal)
    after
        simple_kv:stop([Pid])
    end.

escribir_con_un_atomo_invalido_devuelve_error_test() ->
    {ok, [Pid]} = simple_kv:start_link(1, 10),
    try
        ?assertError(function_clause, simple_kv:put(Pid, color, rojo, inifinito)),
        ok = simple_kv:put(Pid, color, rojo),
        {ok, ColorVal} = simple_kv:get(Pid, color),
        ?assertEqual(rojo, ColorVal)
    after
        simple_kv:stop([Pid])
    end.

escribir_con_float_como_tiempo_devuelve_error_test() ->
    {ok, [Pid]} = simple_kv:start_link(1, 10),
    try
        ?assertError(function_clause, simple_kv:put(Pid, color, rojo, 1.0)),
        ok = simple_kv:put(Pid, color, rojo),
        {ok, ColorVal} = simple_kv:get(Pid, color),
        ?assertEqual(rojo, ColorVal)
    after
        simple_kv:stop([Pid])
    end.

ttl_cero_reemplaza_valor_anterior_test() ->
    {ok, [Pid]} = simple_kv:start_link(1, 10),
    try
        ok = simple_kv:put(Pid, color, rojo),
        ok = simple_kv:put(Pid, color, azul, 0),
        ?assertEqual(not_found, simple_kv:get(Pid, color))
    after
        simple_kv:stop([Pid])
    end.

ttl_mayor_a_cero_expira_test() ->
    {ok, [Pid]} = simple_kv:start_link(1, 10),
    try
        ok = simple_kv:put(Pid, color, rojo, 300),
        ?assertEqual({ok, rojo}, simple_kv:get(Pid, color)),
        simple_kv_test_utils:esperar_valor(Pid, color, not_found,1000)
    after
        simple_kv:stop([Pid])
    end.

ttl_anterior_vencido_no_modifica_entrada_test() ->
    {ok, [Pid]} = simple_kv:start_link(1, 10),
    try
        ok = simple_kv:put(Pid, color, rojo, 300),
        ok = simple_kv:put(Pid, color, azul),
        ?assertEqual({ok, azul}, simple_kv:get(Pid, color)),
        timer:sleep(400),
        ?assertEqual({ok, azul}, simple_kv:get(Pid, color))
    after
        simple_kv:stop([Pid])
    end.

ttl_infinito_sobrescrito_con_finito_vence_entrada_test() ->
    {ok, [Pid]} = simple_kv:start_link(1, 10),
    try
        ok = simple_kv:put(Pid, color, rojo),
        ok = simple_kv:put(Pid, color, azul,300),
        ?assertEqual({ok, azul}, simple_kv:get(Pid, color)),
        simple_kv_test_utils:esperar_valor(Pid, color, not_found,1000)
    after
        simple_kv:stop([Pid])
    end.
