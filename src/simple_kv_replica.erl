-module(simple_kv_replica).
-export([init/0]).

%% Estado de la replica (solo en los argumentos de loop):
%%   Peers      : pids de las otras replicas
%%   Alfa       : capacidad maxima de valores (4.7)
%%   Map        : Key => {Version, {value, Val, Vence}}      (solo valores)
%%   Metadatos  : Key => {Version, valor | borrado | desalojado}
%%   Pendientes : ConsultaRef => {Client, Ref, Key, Faltan}  (gets en curso, 4.8)

init() ->
    receive
        {peers, Peers, Alfa, Coordinador, Solicitante, Ref} ->
            Solicitante ! {Ref, self()},
            loop(Peers, Alfa, #{}, #{}, #{}, Coordinador);
        {peers, Peers, Alfa, Coordinador} -> loop(Peers, Alfa, #{}, #{}, #{}, Coordinador);
        {peers, Peers, Alfa} -> loop(Peers, Alfa, #{}, #{}, #{}, ninguno);
        _ -> init()
    end.

loop(Peers, Alfa, Map, Metadatos, Pendientes, Coordinador) ->
    receive
        %% ---------- otra replica pregunta por una clave (4.8) ----------
        %% Se responde enseguida con lo local: nunca se espera a nadie (5.2).
        {consultar, Solicitante, ConsultaRef, Key} when is_pid(Coordinador) ->
            Coordinador ! {barrera_consulta, self(), Solicitante, ConsultaRef, Key},
            loop(Peers, Alfa, Map, Metadatos, Pendientes, Coordinador);
        {consulta_ordenada, Solicitante, ConsultaRef, Key} ->
            Solicitante !
                {respuesta_consulta, ConsultaRef, self(),
                 simple_kv_almacen:buscar_local(Key, Map, Metadatos)},
            loop(Peers, Alfa, Map, Metadatos, Pendientes, Coordinador);
        {consultar, Solicitante, ConsultaRef, Key} ->
            Solicitante !
                {respuesta_consulta, ConsultaRef, self(),
                 simple_kv_almacen:buscar_local(Key, Map, Metadatos)},
            loop(Peers, Alfa, Map, Metadatos, Pendientes, Coordinador);

        stop ->
            ok;

        %% ---------- put del cliente ----------
        %% Reserva lugar antes de insertar; no elimina vencidos del 75 % protegido.
        %% Sobrescribir una clave existente no aumenta el tamano.
        {put, Client, Ref, Key, Val, Time} when is_pid(Coordinador) ->
            Coordinador ! {escritura, self(), Client, Ref, put, Key, Val, Time},
            loop(Peers, Alfa, Map, Metadatos, Pendientes, Coordinador);
        {put, Client, Ref, Key, Val, Time} ->
            Entry = {simple_kv_replicacion:nueva_version(),
                     {value, Val, simple_kv_ttl:expira(Time)}},
            {NewMap, NuevosMetadatos} = simple_kv_capacidad:guardar(
                Peers, Alfa, Key, Entry, Map, Metadatos),
            Client ! {Ref, ok},
            simple_kv_replicacion:replicar(Peers, Key, Entry),
            loop(Peers, Alfa, NewMap, NuevosMetadatos, Pendientes, Coordinador);
        %% ---------- delete del cliente (tombstone) ----------
        {delete, Client, Ref, Key} when is_pid(Coordinador) ->
            Coordinador ! {escritura, self(), Client, Ref, delete, Key},
            loop(Peers, Alfa, Map, Metadatos, Pendientes, Coordinador);
        {delete, Client, Ref, Key} ->
            Entry = {simple_kv_replicacion:nueva_version(), borrado},
            NuevosMetadatos = simple_kv_almacen:registrar_metadata(Key, Entry, Metadatos),
            NewMap = maps:remove(Key, Map),
            Client ! {Ref, ok},
            simple_kv_replicacion:replicar(Peers, Key, Entry),
            loop(Peers, Alfa, NewMap, NuevosMetadatos, Pendientes, Coordinador);

        %% ---------- get del cliente ----------
        {get, Client, Ref, Key} when is_pid(Coordinador) ->
            Coordinador ! {barrera_get, self(), Client, Ref, Key},
            loop(Peers, Alfa, Map, Metadatos, Pendientes, Coordinador);
        {get, Client, Ref, Key} ->
            self() ! {get_ordenado, Client, Ref, Key},
            loop(Peers, Alfa, Map, Metadatos, Pendientes, Coordinador);
        {get_ordenado, Client, Ref, Key} ->
            Local = simple_kv_almacen:buscar_local(Key, Map, Metadatos),
            case Local of
                %% tengo el valor: respondo (la API del cliente chequea el TTL)
                {ok, {_Version, {value, _Val, _Vence}}} ->
                    responder_lectura(Client, Ref, Local),
                    loop(Peers, Alfa, Map, Metadatos, Pendientes, Coordinador);
                %% fue borrado: not_found
                {ok, {_Version, borrado}} ->
                    responder_lectura(Client, Ref, Local),
                    loop(Peers, Alfa, Map, Metadatos, Pendientes, Coordinador);
                %% desalojado o desconocido, y no hay a quien preguntar
                _ when Peers =:= [] ->
                    responder_lectura(Client, Ref, Local),
                    loop(Peers, Alfa, Map, Metadatos, Pendientes, Coordinador);
                %% desalojado o desconocido: pregunto a los pares (4.8)
                %% y sigo atendiendo mensajes sin bloquearme (5.2)
                _ ->
                    NuevosPendientes =
                        consultar_pares(Peers, Client, Ref, Key, Local, Pendientes),
                    loop(Peers, Alfa, Map, Metadatos, NuevosPendientes, Coordinador)
            end;
        %% ---------- cambio que llega de otra replica ----------
        {replica, Key, Entry} when is_pid(Coordinador) ->
            Coordinador ! {propuesta_replica, self(), Key, Entry},
            loop(Peers, Alfa, Map, Metadatos, Pendientes, Coordinador);
        {replica, Key, Entry} ->
            {NewMap, NuevosMetadatos} =
                case simple_kv_almacen:es_mensaje_nuevo(Key, Entry, Metadatos) of
                    true ->
                        case Entry of
                            {_, borrado} ->
                                {simple_kv_almacen:aplicar_actualizacion(Key, Entry, Map, Metadatos),
                                 simple_kv_almacen:registrar_metadata(Key, Entry, Metadatos)};
                            {_, {value, _, _}} ->
                                simple_kv_capacidad:guardar(
                                    Peers, Alfa, Key, Entry, Map, Metadatos)
                        end;
                    false -> {Map, Metadatos}
                end,
            loop(Peers, Alfa, NewMap, NuevosMetadatos, Pendientes, Coordinador);

        %% ---------- otra replica me ofrece un valor que va a desalojar ----------
        %% Puede reutilizar un vencido no protegido; nunca envia otros mensajes.
        {ofrecer, Key, Entry} when is_pid(Coordinador) ->
            Coordinador ! {propuesta_oferta, Key, Entry},
            loop(Peers, Alfa, Map, Metadatos, Pendientes, Coordinador);
        {ofrecer, Key, Entry} ->
            {NewMap, NuevosMetadatos} =
                simple_kv_capacidad:aceptar_oferta(Key, Entry, Alfa, Map, Metadatos),
            loop(Peers, Alfa, NewMap, NuevosMetadatos, Pendientes, Coordinador);
        {ordenada, Origen, Client, Ref, Key, Entry, Accion, Tipo} when is_pid(Coordinador) ->
            {NewMap, NuevosMetadatos} = aplicar_ordenada(
                Accion, Key, Entry, Map, Metadatos, Peers, Origen, Tipo),
            case self() =:= Origen andalso is_pid(Client) of
                true -> Client ! {Ref, ok}; false -> ok
            end,
            loop(Peers, Alfa, NewMap, NuevosMetadatos, Pendientes, Coordinador);
        %% ---------- respuesta a una consulta mia (4.8) ----------
        {respuesta_consulta, ConsultaRef, Peer, Resultado} ->
            case maps:find(ConsultaRef, Pendientes) of
                {ok, {Client, Ref, Key, Faltan}} ->
                    case lists:member(Peer, Faltan) of
                        false ->
                            loop(Peers, Alfa, Map, Metadatos, Pendientes, Coordinador);
                        true ->
                            %% El cliente acumula el candidato; Pendientes no guarda valores.
                            Client ! {Ref, candidato, Resultado},
                            Restantes = lists:delete(Peer, Faltan),
                            case Restantes of
                                [] ->
                                    %% Comparar tambien con el estado local actualizado durante la espera.
                                    Client ! {Ref, candidato,
                                        simple_kv_almacen:buscar_local(Key, Map, Metadatos)},
                                    Client ! {Ref, fin},
                                    loop(Peers, Alfa, Map, Metadatos,
                                         maps:remove(ConsultaRef, Pendientes), Coordinador);
                                _ ->
                                    Actualizado = {Client, Ref, Key, Restantes},
                                    loop(Peers, Alfa, Map, Metadatos,
                                         maps:put(ConsultaRef, Actualizado, Pendientes), Coordinador)
                            end
                    end;
                error ->
                    loop(Peers, Alfa, Map, Metadatos, Pendientes, Coordinador)
            end;

        %% ---------- descartar mensajes inesperados (5.1) ----------
        _ ->
            loop(Peers, Alfa, Map, Metadatos, Pendientes, Coordinador)
    end.

%% Manda {consultar, ...} a todos los pares y registra el get pendiente.
consultar_pares(Peers, Client, Ref, Key, Local, Pendientes) ->
    Client ! {Ref, candidato, Local},
    Yo = self(),
    ConsultaRef = make_ref(),
    lists:foreach(
        fun(Peer) -> Peer ! {consultar, Yo, ConsultaRef, Key} end,
        Peers
    ),
    maps:put(ConsultaRef, {Client, Ref, Key, Peers}, Pendientes).

%% Tambien lo local pasa por el cliente para revisar TTL justo antes de retornar.
responder_lectura(Client, Ref, Resultado) ->
    Client ! {Ref, candidato, Resultado},
    Client ! {Ref, fin}.

%% Las replicas aplican la decision ordenada; nunca vuelven a elegir victima.
aplicar_ordenada(ignorar, _K, _E, M, Meta, _P, _O, _T) -> {M, Meta};
aplicar_ordenada(borrar, K, E, M, Meta, _P, _O, _T) ->
    {simple_kv_almacen:aplicar_actualizacion(K,E,M,Meta),
     simple_kv_almacen:registrar_metadata(K,E,Meta)};
aplicar_ordenada({rechazar, Version}, K, E, M, Meta, Peers, Origen, Tipo) ->
    ofrecer_ordenado(K,E,Peers,Origen,Tipo),
    {M, maps:put(K,{Version,desalojado},Meta)};
aplicar_ordenada({guardar, Quitadas}, K, E, M, Meta, Peers, Origen, Tipo) ->
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
