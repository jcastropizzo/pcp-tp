-module(simple_kv_ttl).
-export([calcular_vencimiento/1, vigente/1]).

calcular_vencimiento(infinity) -> infinity;
calcular_vencimiento(TTL) -> erlang:monotonic_time(millisecond) + TTL.

vigente(infinity) -> true;
vigente(Vence) -> erlang:monotonic_time(millisecond) < Vence.
