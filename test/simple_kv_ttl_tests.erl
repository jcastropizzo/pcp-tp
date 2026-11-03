-module(simple_kv_ttl_tests).
-include_lib("eunit/include/eunit.hrl").

infinity_no_vence_test() ->
    ?assertEqual(infinity, simple_kv_ttl:expira(infinity)),
    ?assert(simple_kv_ttl:vigente(infinity)).

instante_pasado_no_esta_vigente_test() ->
    Pasado = erlang:monotonic_time(millisecond) - 1,
    ?assertNot(simple_kv_ttl:vigente(Pasado)).

ttl_cero_nace_vencido_test() ->
    ?assertNot(simple_kv_ttl:vigente(simple_kv_ttl:expira(0))).
