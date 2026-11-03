-module(simple_kv_replica_tests).
-include_lib("eunit/include/eunit.hrl").

%% Una sola replica: un get no puede recuperar el dato desde otro proceso.
%% Sin TTL ni delete: la desaparicion esperada corresponde al desalojo.
diecisiete_claves_desalojan_una_en_replica_unica_test() ->
    {ok, [Pid]} = simple_kv:start_link(1),
    try
        lists:foreach(
            fun(N) ->
                ok = simple_kv:put(Pid, {clave, N}, {valor, N})
            end,
            lists:seq(1, 16)
        ),
        %% Con 16 claves todavia no hace falta desalojar.
        lists:foreach(
            fun(N) ->
                ?assertEqual({ok, {valor, N}}, simple_kv:get(Pid, {clave, N}))
            end,
            lists:seq(1, 16)
        ),
        ok = simple_kv:put(Pid, {clave, 17}, {valor, 17}),
        Lecturas = [
            {N, simple_kv:get(Pid, {clave, N})}
            || N <- lists:seq(1, 17)
        ],
        %% Las 12 escrituras mas recientes deben seguir disponibles.
        lists:foreach(
            fun(N) ->
                ?assertEqual({ok, {valor, N}}, proplists:get_value(N, Lecturas))
            end,
            lists:seq(6, 17)
        ),
        Disponibles = [N || {N, {ok, _}} <- Lecturas],
        Ausentes = [N || {N, not_found} <- Lecturas],
        ?assertEqual(16, length(Disponibles)),
        ?assertEqual(1, length(Ausentes))
    after
        simple_kv:stop([Pid])
    end.
