-module(simple_kv_ordenada).
-export([aplicar/8]).

%% Las replicas aplican la decision ordenada; nunca vuelven a elegir victima.
aplicar(ignorar, _K, _E, M, Meta, _P, _O, _T) -> {M, Meta};
aplicar(borrar, K, E, M, Meta, _P, _O, _T) ->
    {simple_kv_almacen:aplicar_actualizacion(K,E,M,Meta),
     simple_kv_almacen:registrar_metadata(K,E,Meta)};
aplicar({rechazar, Version}, K, E, M, Meta, Peers, Origen, Tipo) ->
    ofrecer_ordenado(K,E,Peers,Origen,Tipo),
    {M, maps:put(K,{Version,desalojado},Meta)};
aplicar({guardar, Quitadas}, K, E, M, Meta, Peers, Origen, Tipo) ->
    {M1, Meta1} = lists:foldl(fun(Victima,{Acc, AMeta}) ->
        Entrada=maps:get(Victima,Acc),
        ofrecer_ordenado(Victima,Entrada,Peers,Origen,Tipo),
        simple_kv_capacidad:desalojar(Victima,Acc,AMeta)
    end,{M,Meta},Quitadas),
    {simple_kv_almacen:aplicar_actualizacion(K,E,M1,Meta1),
     simple_kv_almacen:registrar_metadata(K,E,Meta1)}.

ofrecer_ordenado(K,{_,{value,_,Vence}}=E,Peers,_Origen,put) ->
    %% Cada replica ofrece su copia antes de descartarla; las ofertas no
    %% generan nuevas ofertas y el coordinador ordena cualquier aceptacion.
    case simple_kv_ttl:vigente(Vence) of
        true -> simple_kv_replicacion:ofrecer(Peers,K,E);
        false -> ok
    end;
ofrecer_ordenado(_,_,_,_,_) -> ok.
