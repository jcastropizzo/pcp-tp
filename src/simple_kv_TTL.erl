-module(simple_kv_ttl).
-export([expira/1, vigente/1]).

expira(infinity) -> infinity;
expira(Time) -> erlang:monotonic_time(millisecond) + Time.

vigente(infinity) -> true;
vigente(Expira) -> erlang:monotonic_time(millisecond) < Expira.
