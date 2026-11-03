-module(simple_kv_test_utils).
-export([esperar_valor/4]).
-include_lib("eunit/include/eunit.hrl").

obtener_plazo_ms(Ms)->erlang:monotonic_time(millisecond) + Ms.

esperar_valor(Pid, Key, Esperado, Ms) ->
    Plazo = obtener_plazo_ms(Ms),
    esperar_valor_hasta(Pid, Key, Esperado, Plazo).

esperar_valor_hasta(Pid, Key, Esperado, Plazo) ->
    Actual = simple_kv:get(Pid, Key),
    case Actual =:= Esperado of
        true ->
            ok;
        false ->
            case erlang:monotonic_time(millisecond) >= Plazo of
                true ->
                    ?assertEqual(Esperado, Actual);
                false ->
                    timer:sleep(10),
                    esperar_valor_hasta(Pid, Key, Esperado, Plazo)
            end
    end.
