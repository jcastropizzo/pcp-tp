-module(simple_kv_v5_tests).
-include_lib("eunit/include/eunit.hrl").

terminos_compuestos_y_enlaces_test() ->
    {ok, Ps} = simple_kv:start_link(2, 3),
    try
        {links, Links} = process_info(self(), links),
        ?assert(lists:all(fun(P) -> lists:member(P, Links) end, Ps)),
        [P | _] = Ps,
        Key = #{clave => [uno, {dos, 2}]},
        Val = {self(), <<0, 255>>, #{datos => [1,2,3]}},
        ok = simple_kv:put(P, Key, Val),
        ?assertEqual({ok, Val}, simple_kv:get(P, Key))
    after simple_kv:stop(Ps) end.

%% El contrato no impone un plazo: una replica viva puede tardar mas de 1 s.
stop_espera_terminacion_lenta_test() ->
    {ok, [P]} = simple_kv:start_link(1, 3),
    true = erlang:suspend_process(P),
    Parent = self(),
    {Worker, Monitor} = spawn_monitor(fun() ->
        Parent ! {cerrando, self()},
        R = simple_kv:stop([P]),
        Parent ! {cerrado, self(), R}
    end),
    receive {cerrando, Worker} -> ok end,
    try
        receive
            {cerrado, Worker, _} -> erlang:error(stop_no_espero);
            {'DOWN', Monitor, process, Worker, Reason} -> erlang:error({stop_fallo, Reason})
        after 1100 -> ok
        end,
        true = erlang:resume_process(P),
        receive {cerrado, Worker, ok} -> ok after 1000 -> erlang:error(stop_no_termino) end,
        receive {'DOWN', Monitor, process, Worker, normal} -> ok end,
        ?assertNot(is_process_alive(P))
    after
        case is_process_alive(P) of
            true ->
                try erlang:resume_process(P) catch error:badarg -> ok end,
                simple_kv:stop([P]);
            false -> ok
        end
    end.

init_descarta_mensajes_test() ->
    P = spawn_link(fun simple_kv_replica:init/0),
    P ! inesperado_antes_de_peers,
    P ! {peers, [], 3},
    try
        ?assertEqual(not_found, simple_kv:get(P, ausente)),
        ?assertEqual({messages, []}, process_info(P, messages))
    after simple_kv:stop([P]) end.

%% La misma seleccion global para Alfa de 3 a 16 y tres ordenes distintos.
limite_y_mayores_versiones_para_varios_alfa_test() ->
    lists:foreach(fun(Alfa) ->
        Entradas = [{N,{N,{value,N,infinity}}} || N <- lists:seq(1,40)],
        Esperado = maps:from_list(lists:nthtail(40-Alfa,Entradas)),
        lists:foreach(fun(Orden) ->
            {Map,_} = lists:foldl(fun({K,E},{M,T}) ->
                {NM,NT}=simple_kv_capacidad:guardar([],Alfa,K,E,M,T),
                ?assert(map_size(NM)=<Alfa), {NM,NT}
            end,{#{},#{}},Orden),
            ?assertEqual(Esperado,Map)
        end,[Entradas,lists:reverse(Entradas),
            [E || E={N,_} <- Entradas,N rem 2=:=0] ++
            [E || E={N,_} <- Entradas,N rem 2=:=1]])
    end,lists:seq(3,16)).

%% Compara valores LOCALES: get/2 podria ocultar divergencia leyendo un par.
escritores_concurrentes_convergen_al_mismo_map_test() ->
    Alfa=4,
    {ok,Ps}=simple_kv:start_link(3,Alfa),
    Parent=self(), Trabajos=lists:zip(Ps,[a,b,c]),
    Keys=[{Tag,N} || {_,Tag} <- Trabajos,N <- lists:seq(1,20)],
    Ws=[spawn_monitor(fun() ->
        lists:foreach(fun(N)->ok=simple_kv:put(P,{Tag,N},N) end,lists:seq(1,20)),
        Parent ! {terminado,self()}
    end) || {P,Tag} <- Trabajos],
    try
        lists:foreach(fun({W,M})->
            receive {terminado,W}->ok after 2000->error(escritor_lento) end,
            receive {'DOWN',M,process,W,normal}->ok end
        end,Ws),
        Plazo=erlang:monotonic_time(millisecond)+1500,
        Esperado=esperar_maps_iguales(Ps,Keys,Alfa,Plazo),
        ?assertEqual(Alfa,map_size(Esperado))
    after simple_kv:stop(Ps) end.

sobrescritura_delete_ttl_y_trafico_remoto_test() ->
    {ok,[P]}=simple_kv:start_link(1,4),
    try
        lists:foreach(fun(N)->simple_kv:put(P,N,N) end,lists:seq(1,4)),
        ok=simple_kv:put(P,2,nuevo),
        ok=simple_kv:delete(P,3),
        ok=simple_kv:put(P,4,vencido,0),
        ?assertEqual({ok,nuevo},simple_kv:get(P,2)),
        lists:foreach(fun(N)->
            P ! {replica,{remoto,N},{simple_kv_replicacion:nueva_version(),{value,N,infinity}}}
        end,lists:seq(1,10)),
        ?assertEqual(not_found,simple_kv:get(P,2)),
        ?assertEqual(not_found,simple_kv:get(P,3)),
        ?assertEqual(not_found,simple_kv:get(P,4)),
        lists:foreach(fun(N)->?assertEqual({ok,N},simple_kv:get(P,{remoto,N})) end,[7,8,9,10])
    after simple_kv:stop([P]) end.

map_local(P,Keys) ->
    lists:foldl(fun(K,Acc)->
        R=make_ref(), P ! {consultar,self(),R,K},
        receive
            {respuesta_consulta,R,P,{ok,{_,{value,_,_}}=E}}->maps:put(K,E,Acc);
            {respuesta_consulta,R,P,_}->Acc
        after 1000->error(sin_respuesta_local)
        end
    end,#{},Keys).

esperar_maps_iguales(Ps,Keys,Alfa,Plazo) ->
    Maps=[map_local(P,Keys) || P <- Ps],
    case lists:usort(Maps) of
        [Unico] when map_size(Unico)=:=Alfa->Unico;
        _ ->
            case erlang:monotonic_time(millisecond)>=Plazo of
                true->error({maps_no_convergen,Maps});
                false->receive after 5->ok end,
                       esperar_maps_iguales(Ps,Keys,Alfa,Plazo)
            end
    end.

%% No se acumula el valor en Pendientes: se entrega al cliente antes de que
%% responda el ultimo par. Las respuestas ajenas/duplicadas no cierran el get.
consultas_reenvian_y_filtran_respuestas_test() ->
    Gate = spawn(fun gate/0),
    P = spawn_link(fun simple_kv_replica:init/0),
    P ! {peers, [self(), Gate], 3},
    Ref = make_ref(),
    P ! {get, self(), Ref, ausente},
    try
        Consulta = receive {consultar, P, C, ausente} -> C after 1000 -> error(sin_consulta) end,
        P ! {respuesta_consulta, make_ref(), self(), error},
        P ! {respuesta_consulta, Consulta, desconocido, error},
        E = {1, {value, remoto, infinity}},
        P ! {respuesta_consulta, Consulta, self(), {ok, E}},
        P ! {respuesta_consulta, Consulta, self(), {ok, {100, borrado}}},
        receive {Ref, candidato, {ok, E}} -> ok after 1000 -> error(valor_retenido_en_replica) end,
        receive {Ref, fin} -> error(termino_sin_todos) after 20 -> ok end,
        Gate ! {liberar, self()},
        receive {Ref, fin} -> ok after 1000 -> error(no_termino) end,
        receive {Ref, candidato, {ok, {100,borrado}}} -> error(acepto_duplicado) after 0 -> ok end
    after simple_kv:stop([P]), exit(Gate, kill) end.

gate() ->
    receive {consultar, P, Ref, _} ->
        receive {liberar, _} -> P ! {respuesta_consulta, Ref, self(), error} end
    end.

valor_remoto_vence_antes_de_finalizar_get_test() ->
    Gate = spawn(fun gate/0),
    P = spawn_link(fun simple_kv_replica:init/0),
    P ! {peers, [self(), Gate], 3},
    Parent = self(),
    spawn(fun() -> Parent ! {leido, simple_kv:get(P, k)} end),
    try
        C = receive {consultar, P, R, k} -> R after 1000 -> error(sin_consulta) end,
        P ! {respuesta_consulta, C, self(), {ok, {1, {value, temporal, erlang:monotonic_time(millisecond)+30}}}},
        %% Barrera: la replica ya reenvio el candidato al cliente.
        B = make_ref(), P ! {consultar, self(), B, barrera},
        receive {respuesta_consulta, B, P, _} -> ok end,
        receive after 50 -> ok end,
        Gate ! {liberar, self()},
        receive {leido, Rdo} -> ?assertEqual(not_found, Rdo) after 1000 -> error(sin_resultado) end
    after simple_kv:stop([P]), exit(Gate, kill) end.

put_ttl_cero_reciente_ocupa_lugar_y_no_se_devuelve_test() ->
    {ok, [P]} = simple_kv:start_link(1, 3),
    try
        lists:foreach(fun(N) -> simple_kv:put(P, N, N) end, [1,2,3]),
        ok = simple_kv:put(P, nueva, vencida, 0),
        ?assertEqual(not_found,simple_kv:get(P,1)),
        lists:foreach(fun(N) -> ?assertEqual({ok,N}, simple_kv:get(P,N)) end, [2,3]),
        ?assertEqual(not_found, simple_kv:get(P,nueva)),
        ?assertMatch(#{nueva := {_,{value,vencida,_}}},map_local(P,[1,2,3,nueva]))
    after simple_kv:stop([P]) end.

delete_replicado_viejo_conserva_valor_nuevo_test() ->
    {ok, [P]} = simple_kv:start_link(1,3),
    try
        P ! {replica, k, {20,{value,nuevo,infinity}}},
        P ! {replica, k, {10,borrado}},
        ?assertEqual({ok,nuevo},simple_kv:get(P,k))
    after simple_kv:stop([P]) end.

%% Reproduce la divergencia causada por el cupo local: ahora todas las claves
%% locales antiguas salen frente a Alfa versiones remotas mas nuevas.
versiones_remotas_desplazan_todas_las_locales_antiguas_test() ->
    {ok,[P]}=simple_kv:start_link(1,3),
    try
        lists:foreach(fun(K)->simple_kv:put(P,K,K) end,[a,b,c]),
        Remotas=[{K,{simple_kv_replicacion:nueva_version(),{value,K,infinity}}} || K <- [d,e,f]],
        lists:foreach(fun({K,E})->P ! {replica,K,E} end,Remotas),
        ?assertEqual(maps:from_list(Remotas),map_local(P,[a,b,c,d,e,f]))
    after simple_kv:stop([P]) end.

mismas_entradas_en_ordenes_opuestos_producen_maps_iguales_test() ->
    {ok,[P1,P2]=Ps}=simple_kv:start_link(2,3),
    Entradas=[{K,{N,{value,K,infinity}}} || {K,N} <- lists:zip([a,b,c,d,e,f],lists:seq(1,6))],
    try
        lists:foreach(fun({K,E})->P1 ! {replica,K,E} end,Entradas),
        lists:foreach(fun({K,E})->P2 ! {replica,K,E} end,lists:reverse(Entradas)),
        Esperado=maps:from_list(lists:nthtail(3,Entradas)),
        ?assertEqual(Esperado,map_local(P1,[a,b,c,d,e,f])),
        ?assertEqual(Esperado,map_local(P2,[a,b,c,d,e,f]))
    after simple_kv:stop(Ps) end.
