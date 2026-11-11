-module(simple_kv_proteccion_ttl_tests).
-include_lib("eunit/include/eunit.hrl").

%% Fuente: consigna/kv_replicado.pdf (V5), secciones 4.6 y 4.7.
%% Citas textuales:
%% "el 75 % escrito más recientemente (en el nodo local) siempre siga disponible".
%% "nunca se devuelve un valor vencido".
%% "No es válido tener entradas adicionales en alguna estructura secundaria,
%% α es el tope de valores permitidos para un nodo."
%% La preservacion FISICA de protegidos vencidos y Q=ceil(3*Alfa/4) son el
%% criterio de diseno acordado: el PDF no los prescribe literalmente.
%% Se ordena por version, sin cupos independientes por replica de origen.

%% El valor d vence, pero su version queda entre las tres protegidas; sale a.
vencido_protegido_permanece_al_insertar_test() ->
    D=entrada(4,d,pasado()),
    {M,T}=estado([{a,entrada(1,a,infinity)},{b,entrada(2,b,infinity)},
                  {c,entrada(3,c,infinity)},{d,D}]),
    {NM,NT}=simple_kv_capacidad:guardar([],4,e,entrada(5,e,infinity),M,T),
    ?assertEqual(D,maps:get(d,NM)),
    ?assertEqual({4,valor},maps:get(d,NT)),
    ?assertNot(maps:is_key(a,NM)),
    ?assertEqual(4,map_size(NM)).

%% Entre a vigente y b vencido, ambos elegibles, se reutiliza b aunque a sea mas viejo.
vencido_elegible_sale_antes_que_vigente_mas_viejo_test() ->
    B=entrada(2,b,pasado()),
    {M,T}=estado([{a,entrada(1,a,infinity)},{b,B},
                  {c,entrada(3,c,infinity)},{d,entrada(4,d,infinity)}]),
    {NM,NT}=simple_kv_capacidad:guardar([],4,e,entrada(5,e,infinity),M,T),
    ?assert(maps:is_key(a,NM)),
    ?assertNot(maps:is_key(b,NM)),
    ?assertEqual({2,desalojado},maps:get(b,NT)),
    ?assertEqual(4,map_size(NM)).

%% Cuando todos los candidatos siguen vigentes, la version minima decide el descarte.
sin_vencidos_elegibles_sale_la_menor_version_test() ->
    {M,T}=estado([{N,entrada(N,N,infinity)} || N <- [1,2,3,4]]),
    {NM,_}=simple_kv_capacidad:guardar([],4,5,entrada(5,5,infinity),M,T),
    ?assertEqual([2,3,4,5],lists:sort(maps:keys(NM))).

%% El entrante tambien compite: si es vencido y no protegido, no ocupa el mapa.
entrante_vencido_y_antiguo_puede_ser_descartado_test() ->
    {M,T}=estado([{N,entrada(N,N,infinity)} || N <- [2,3,4,5]]),
    {NM,NT}=simple_kv_capacidad:guardar([],4,1,entrada(1,1,pasado()),M,T),
    ?assertEqual(M,NM),
    ?assertEqual({1,desalojado},maps:get(1,NT)).

%% Una escritura nueva ya vencida sigue protegida por version y conserva metadato valor.
entrante_vencido_reciente_se_conserva_test() ->
    {M,T}=estado([{N,entrada(N,N,infinity)} || N <- [1,2,3,4]]),
    E=entrada(5,nuevo,pasado()),
    {NM,NT}=simple_kv_capacidad:guardar([],4,5,E,M,T),
    ?assertEqual(E,maps:get(5,NM)),
    ?assertEqual({5,valor},maps:get(5,NT)),
    ?assertNot(maps:is_key(1,NM)).

%% La prioridad por vencimiento puede conservar un entrante mas viejo que el descartado.
entrante_viejo_vigente_puede_reutilizar_vencido_elegible_test() ->
    {M,T}=estado([{2,entrada(2,2,pasado())} |
                  [{N,entrada(N,N,infinity)} || N <- [3,4,5]]]),
    {NM,_}=simple_kv_capacidad:guardar([],4,1,entrada(1,1,infinity),M,T),
    ?assertEqual([1,3,4,5],lists:sort(maps:keys(NM))).

%% Comprueba el redondeo hacia arriba y la primera version protegida en varias capacidades.
redondeo_y_frontera_protegida_para_distintos_alfa_test() ->
    lists:foreach(fun(Alfa) ->
        Q=(3*Alfa+3) div 4,
        Frontera=Alfa+2-Q,
        {M,T}=estado([{N,entrada(N,N,case N=:=Frontera of
                                      true->pasado(); false->infinity end)}
                      || N <- lists:seq(1,Alfa)]),
        {NM,NT}=simple_kv_capacidad:guardar([],Alfa,Alfa+1,
                                            entrada(Alfa+1,nuevo,infinity),M,T),
        ?assertEqual(Alfa,map_size(NM)),
        lists:foreach(fun(N)->?assert(maps:is_key(N,NM)) end,
                      lists:seq(Frontera,Alfa+1)),
        ?assertEqual({Frontera,valor},maps:get(Frontera,NT))
    end,[3,4,5,7,16]).

%% Una oferta rechazada no debe borrar entradas protegidas como efecto secundario.
oferta_no_limpia_vencidos_protegidos_test() ->
    D=entrada(4,d,pasado()),
    {M,T}=estado([{a,entrada(1,a,infinity)},{b,entrada(2,b,infinity)},
                  {c,entrada(3,c,infinity)},{d,D}]),
    {NM,NT}=simple_kv_capacidad:aceptar_oferta(e,entrada(5,e,infinity),4,M,T),
    ?assertEqual(M,NM),
    ?assertEqual({4,valor},maps:get(d,NT)).

%% Una oferta puede usar espacio de un vencido elegible sin desalojar valores vigentes.
oferta_reutiliza_solo_un_vencido_no_protegido_test() ->
    {M,T}=estado([{a,entrada(1,a,infinity)},{b,entrada(2,b,pasado())},
                  {c,entrada(3,c,infinity)},{d,entrada(4,d,infinity)}]),
    {NM,NT}=simple_kv_capacidad:aceptar_oferta(e,entrada(5,e,infinity),4,M,T),
    ?assertEqual([a,c,d,e],lists:sort(maps:keys(NM))),
    ?assertEqual({2,desalojado},maps:get(b,NT)).

%% Un mensaje obsoleto se ignora antes de cualquier decision de capacidad o limpieza.
replica_vieja_no_limpia_ni_modifica_el_mapa_test() ->
    {M,T}=estado([{a,entrada(1,a,infinity)},{b,entrada(2,b,pasado())},
                  {c,entrada(3,c,infinity)},{d,entrada(4,d,pasado())}]),
    ?assertEqual({M,T},simple_kv_capacidad:guardar([],4,d,entrada(0,viejo,infinity),M,T)).

%% Contrasta el resultado publico not_found con la entrada fisica que conserva la replica.
get_no_devuelve_ni_elimina_el_protegido_vencido_test() ->
    {ok,[P]}=simple_kv:start_link(1,4),
    try
        lists:foreach(fun(K)->simple_kv:put(P,K,K) end,[a,b,c]),
        ok=simple_kv:put(P,d,vencido,0),
        Antes=local(P,d),
        ?assertMatch({ok,{_,{value,vencido,_}}},Antes),
        ?assertEqual(not_found,simple_kv:get(P,d)),
        ?assertEqual(Antes,local(P,d)),
        ok=simple_kv:put(P,e,nuevo),
        ?assertEqual(Antes,local(P,d)),
        ?assertEqual(not_found,simple_kv:get(P,d)),
        ?assertMatch({ok,{_,desalojado}},local(P,a))
    after simple_kv:stop([P]) end.

%% Un put recibido vencido mantiene su version y no se convierte en un delete explicito.
replicacion_vencida_se_guarda_sin_fabricar_borrado_test() ->
    {ok,[P]}=simple_kv:start_link(1,4),
    E=entrada(simple_kv_replicacion:nueva_version(),vencido,pasado()),
    try
        P ! {replica,k,E},
        ?assertEqual({ok,E},local(P,k)),
        ?assertEqual(not_found,simple_kv:get(P,k)),
        ?assertEqual({ok,E},local(P,k))
    after simple_kv:stop([P]) end.

%% Reemplazar una clave existente no necesita otra plaza, aunque el nuevo TTL sea cero.
sobrescribir_protegido_vencido_no_desaloja_otra_clave_test() ->
    {ok,[P]}=simple_kv:start_link(1,3),
    try
        lists:foreach(fun(K)->simple_kv:put(P,K,K) end,[a,b,c]),
        ok=simple_kv:put(P,c,reemplazo,0),
        ?assertMatch({ok,{_,{value,reemplazo,_}}},local(P,c)),
        ?assertEqual({ok,a},simple_kv:get(P,a)),
        ?assertEqual({ok,b},simple_kv:get(P,b)),
        ?assertEqual(not_found,simple_kv:get(P,c))
    after simple_kv:stop([P]) end.

%% La proteccion frente al desalojo no impide un delete ni que su lapida frene mensajes viejos.
delete_explicito_si_elimina_protegido_vencido_test() ->
    {ok,[P]}=simple_kv:start_link(1,3),
    try
        ok=simple_kv:put(P,k,vencido,0),
        {ok,{Version,_}}=local(P,k),
        ok=simple_kv:delete(P,k),
        ?assertMatch({ok,{_,borrado}},local(P,k)),
        P ! {replica,k,entrada(Version,vencido,pasado())},
        ?assertMatch({ok,{_,borrado}},local(P,k))
    after simple_kv:stop([P]) end.

%% El protocolo de ofertas solo envia valores vigentes; descartar un vencido no genera oferta.
no_se_ofrece_un_vencido_al_desalojarlo_test() ->
    B=entrada(2,b,pasado()),
    {M,T}=estado([{a,entrada(1,a,infinity)},{b,B},
                  {c,entrada(3,c,infinity)},{d,entrada(4,d,infinity)}]),
    {NM,_}=simple_kv_capacidad:guardar([self()],4,e,entrada(5,e,infinity),M,T),
    ?assertNot(maps:is_key(b,NM)),
    receive {ofrecer,b,B}->error(ofrecio_vencido) after 0->ok end.

%% Comprueba la transicion de vigente a vencido, no solamente una entrada nacida vencida.
vence_despues_de_guardado_y_sigue_protegido_test() ->
    {ok,[P]}=simple_kv:start_link(1,4),
    try
        lists:foreach(fun(K)->simple_kv:put(P,K,K) end,[a,b,c]),
        ok=simple_kv:put(P,d,temporal,30),
        Antes=local(P,d),
        receive after 50->ok end,
        ok=simple_kv:put(P,e,nuevo),
        ?assertEqual(not_found,simple_kv:get(P,d)),
        ?assertEqual(Antes,local(P,d)),
        ?assertMatch({ok,{_,desalojado}},local(P,a))
    after simple_kv:stop([P]) end.

%% Construye una entrada de replica con version y vencimiento controlados por el test.
entrada(V,Val,Vence)->{V,{value,Val,Vence}}.
%% Usa el reloj monotono para producir un vencimiento ya alcanzado sin depender de fechas.
pasado()->erlang:monotonic_time(millisecond)-1.
%% Arma un mapa y metadatos coherentes para ejercitar capacidad sin procesos de replica.
estado(Pares)->
    M=maps:from_list(Pares),
    {M,maps:map(fun(_,{V,_})->{V,valor} end,M)}.
%% Consulta el estado local: get podria ocultar un desalojo al buscar el valor en un par.
local(P,K)->
    R=make_ref(), P ! {consultar,self(),R,K},
    receive {respuesta_consulta,R,P,E}->E after 1000->error(sin_respuesta_local) end.
