-module(simple_kv_coordinador_tests).
-include_lib("eunit/include/eunit.hrl").

%% Una replica queda atrasada mientras la otra completa puts y delete: aplicar
%% la misma secuencia debe dejar mapas fisicos iguales, sin restaurar d.
replica_atrasada_aplica_desalojo_antes_del_delete_test() ->
    {ok,[P1,P2,P3]=Ps}=simple_kv:start_link(3,3),
    true=erlang:suspend_process(P3),
    Padre=self(),
    {Worker,Mon}=spawn_monitor(fun()->
        lists:foreach(fun(K)->ok=simple_kv:put(P1,K,K) end,[a,b,c,d]),
        ok=simple_kv:delete(P2,d),
        Padre ! {escrituras_completas,self()}
    end),
    try
        receive {escrituras_completas,Worker}->ok after 1500->error(espero_a_la_replica_suspendida) end,
        receive {'DOWN',Mon,process,Worker,normal}->ok after 1000->error(escritor_no_termino) end,
        true=erlang:resume_process(P3),
        %% Una oferta puede recuperar a tras el delete; debe aplicarse en todos.
        E3=estado(P3,[a,b,c,d]),
        ?assertEqual(E3,estado(P1,[a,b,c,d])),
        ?assertEqual(E3,estado(P2,[a,b,c,d])),
        ?assertEqual(borrado,proplists:get_value(d,E3)),
        ?assertEqual(b,proplists:get_value(b,E3)),
        ?assertEqual(c,proplists:get_value(c,E3)),
        ?assertEqual(snapshot(P3,[a,b,c,d]),snapshot(P1,[a,b,c,d])),
        ?assertEqual(snapshot(P3,[a,b,c,d]),snapshot(P2,[a,b,c,d]))
    after
        case is_process_alive(P3) of true->try erlang:resume_process(P3) catch error:badarg->ok end; false->ok end,
        exit(Worker,kill),simple_kv:stop(Ps)
    end.

%% El coordinador elige antes del vencimiento; una replica pausada aplica mas
%% tarde la misma victima aunque su propio reloj ya considere vencida otra.
replica_lenta_no_recalcula_victima_por_ttl_test() ->
    {ok,[P1,P2]=Ps}=simple_kv:start_link(2,4),
    true=erlang:suspend_process(P2),
    try
        ok=simple_kv:put(P1,a,a),
        ok=simple_kv:put(P1,b,b,250),
        ok=simple_kv:put(P1,c,c),
        ok=simple_kv:put(P1,d,d),
        ok=simple_kv:put(P1,e,e),
        ?assertMatch([{a,desalojado},{b,b},{c,c},{d,d},{e,e}],estado(P1,[a,b,c,d,e])),
        receive after 300->ok end,
        true=erlang:resume_process(P2),
        %% P2 puede reenviar la oferta de a, que el coordinador ordena junto
        %% con el resto. Una barrera desde P2 precede a la lectura de P1.
        E2=estado(P2,[a,b,c,d,e]), E1=estado(P1,[a,b,c,d,e]),
        ?assertEqual(E1,E2),
        ?assertEqual(snapshot(P1,[a,b,c,d,e]),snapshot(P2,[a,b,c,d,e])),
        ?assertEqual(not_found,simple_kv:get(P2,b))
    after
        case is_process_alive(P2) of true->try erlang:resume_process(P2) catch error:badarg->ok end; false->ok end,
        simple_kv:stop(Ps)
    end.

%% Una oferta guardada mientras falta lugar se reenvia luego de un delete; su
%% aceptacion entra en el orden global y no genera una nueva cadena de ofertas.
oferta_se_ordena_despues_de_liberar_espacio_test() ->
    P=spawn_link(fun simple_kv_replica:init/0),
    P2=spawn_link(fun simple_kv_replica:init/0),
    Coord=spawn_link(fun()->simple_kv_coordinador:init([P,P2],3) end),
    P ! {peers,[self()],3,Coord},
    P2 ! {peers,[],3,Coord},
    try
        lists:foreach(fun(K)->ok=simple_kv:put(P,K,K) end,[a,b,c,d]),
        Ofrecida=receive {ofrecer,a,E}->E after 1000->error(sin_oferta) end,
        ok=simple_kv:delete(P,d),
        P ! {ofrecer,a,Ofrecida},
        ?assertEqual({ok,a},simple_kv:get(P,a)),
        ?assertMatch([{a,a},{b,b},{c,c},{d,borrado}],estado(P,[a,b,c,d])),
        ?assertEqual(estado(P,[a,b,c,d]),estado(P2,[a,b,c,d])),
        ?assertEqual(snapshot(P,[a,b,c,d]),snapshot(P2,[a,b,c,d])),
        receive {ofrecer,_,_}->error(oferta_genero_cadena) after 20->ok end
    after simple_kv:stop([P,P2]) end.

%% El proceso auxiliar no queda vivo cuando stop termina todas las replicas.
coordinador_finaliza_con_la_ultima_replica_test() ->
    {links,Antes}=process_info(self(),links),
    {ok,Ps}=simple_kv:start_link(2,3),
    {links,Despues}=process_info(self(),links),
    [Coord]=(Despues -- Antes) -- Ps,
    Mon=erlang:monitor(process,Coord),
    ok=simple_kv:stop(Ps),
    receive {'DOWN',Mon,process,Coord,normal}->ok after 1000->error(coordinador_no_termino) end.

%% Mensajes con forma incompleta no deben hacer caer el proceso que ordena.
coordinador_descarta_replica_y_oferta_malformadas_test() ->
    {ok,[P]=Ps}=simple_kv:start_link(1,3),
    try
        P ! {replica,k,malformado},
        P ! {ofrecer,k,{version,{value,v,infinity}}},
        P ! {put,self(),make_ref(),invalido,valor,ttl_invalido},
        ok=simple_kv:put(P,sana,ok),
        ?assertEqual({ok,ok},simple_kv:get(P,sana))
    after simple_kv:stop(Ps) end.

%% Tres clientes mezclan escrituras y borrados; al terminar el trafico las
%% entradas locales completas deben coincidir sin exceder la capacidad.
clientes_concurrentes_con_borrados_y_ofertas_convergen_test() ->
    {ok,Ps}=simple_kv:start_link(3,4),
    Parent=self(), Keys=[a,b,c,d,e,f],
    Workers=[spawn_monitor(fun()->
        lists:foreach(fun(N)->
            Key=lists:nth((N+I) rem length(Keys)+1,Keys),
            case N rem 5 of
                0->ok=simple_kv:delete(P,Key);
                _->ok=simple_kv:put(P,Key,{I,N})
            end
        end,lists:seq(1,25)),
        Parent ! {finalizo,self()}
    end) || {P,I} <- lists:zip(Ps,[1,2,3])],
    try
        lists:foreach(fun({W,M})->
            receive {finalizo,W}->ok after 3000->error(escritor_no_finalizo) end,
            receive {'DOWN',M,process,W,normal}->ok after 1000->error(escritor_sigue_vivo) end
        end,Workers),
        Deadline=erlang:monotonic_time(millisecond)+2000,
        Unico=esperar_mismos_snapshots(Ps,Keys,Deadline),
        Valores=[K || {K,{ok,{_,{value,_,_}}}} <- Unico],
        ?assert(length(Valores)=<4)
    after
        lists:foreach(fun({W,_})->exit(W,kill) end,Workers),
        simple_kv:stop(Ps)
    end.

esperar_mismos_snapshots(Ps,Keys,Deadline) ->
    Snapshots=[snapshot(P,Keys) || P <- Ps],
    case lists:usort(Snapshots) of
        [Unico] -> Unico;
        _ ->
            case erlang:monotonic_time(millisecond)>=Deadline of
                true->error({no_convergen,Snapshots});
                false->receive after 5->ok end,esperar_mismos_snapshots(Ps,Keys,Deadline)
            end
    end.

%% Se conserva version y vencimiento para comparar las entradas completas.
snapshot(P,Keys)->[{K,local(P,K)} || K <- Keys].
local(P,K)->
    Ref=make_ref(), P ! {consultar,self(),Ref,K},
    receive {respuesta_consulta,Ref,P,E}->E after 1000->error({sin_respuesta,K}) end.

estado(P,Keys)->[{K,estado_local(P,K)} || K <- Keys].
estado_local(P,K)->
    Ref=make_ref(), P ! {consultar,self(),Ref,K},
    receive
        {respuesta_consulta,Ref,P,{ok,{_,{value,V,_}}}}->V;
        {respuesta_consulta,Ref,P,{ok,{_,Estado}}}->Estado;
        {respuesta_consulta,Ref,P,error}->error
    after 1000->error({sin_respuesta,K})
    end.
