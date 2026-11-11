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
        {peers, Peers, Alfa} -> loop(Peers, Alfa, #{}, #{}, #{});
        _ -> init()
    end.

loop(Peers, Alfa, Map, Metadatos, Pendientes) ->
    receive
        %% ---------- otra replica pregunta por una clave (4.8) ----------
        %% Se responde enseguida con lo local: nunca se espera a nadie (5.2).
        {consultar, Solicitante, ConsultaRef, Key} ->
            Solicitante !
                {respuesta_consulta, ConsultaRef, self(),
                 simple_kv_almacen:buscar_local(Key, Map, Metadatos)},
            loop(Peers, Alfa, Map, Metadatos, Pendientes);

        stop ->
            ok;

        %% ---------- put del cliente ----------
        %% Reserva lugar antes de insertar; no elimina vencidos del 75 % protegido.
        %% Sobrescribir una clave existente no aumenta el tamano.
        {put, Client, Ref, Key, Val, Time} ->
            Entry = {simple_kv_replicacion:nueva_version(),
                     {value, Val, simple_kv_ttl:expira(Time)}},
            {NewMap, NuevosMetadatos} = simple_kv_capacidad:guardar(
                Peers, Alfa, Key, Entry, Map, Metadatos),
            Client ! {Ref, ok},
            simple_kv_replicacion:replicar(Peers, Key, Entry),
            loop(Peers, Alfa, NewMap, NuevosMetadatos, Pendientes);
        %% ---------- delete del cliente (tombstone) ----------
        {delete, Client, Ref, Key} ->
            Entry = {simple_kv_replicacion:nueva_version(), borrado},
            NuevosMetadatos = simple_kv_almacen:registrar_metadata(Key, Entry, Metadatos),
            NewMap = maps:remove(Key, Map),
            Client ! {Ref, ok},
            simple_kv_replicacion:replicar(Peers, Key, Entry),
            loop(Peers, Alfa, NewMap, NuevosMetadatos, Pendientes);

        %% ---------- get del cliente ----------
        {get, Client, Ref, Key} ->
            Local = simple_kv_almacen:buscar_local(Key, Map, Metadatos),
            case Local of
                %% tengo el valor: respondo (la API del cliente chequea el TTL)
                {ok, {_Version, {value, _Val, _Vence}}} ->
                    responder_lectura(Client, Ref, Local),
                    loop(Peers, Alfa, Map, Metadatos, Pendientes);
                %% fue borrado: not_found
                {ok, {_Version, borrado}} ->
                    responder_lectura(Client, Ref, Local),
                    loop(Peers, Alfa, Map, Metadatos, Pendientes);
                %% desalojado o desconocido, y no hay a quien preguntar
                _ when Peers =:= [] ->
                    responder_lectura(Client, Ref, Local),
                    loop(Peers, Alfa, Map, Metadatos, Pendientes);
                %% desalojado o desconocido: pregunto a los pares (4.8)
                %% y sigo atendiendo mensajes sin bloquearme (5.2)
                _ ->
                    NuevosPendientes =
                        consultar_pares(Peers, Client, Ref, Key, Local, Pendientes),
                    loop(Peers, Alfa, Map, Metadatos, NuevosPendientes)
            end;
        %% ---------- cambio que llega de otra replica ----------
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
            loop(Peers, Alfa, NewMap, NuevosMetadatos, Pendientes);

        %% ---------- otra replica me ofrece un valor que va a desalojar ----------
        %% Puede reutilizar un vencido no protegido; nunca envia otros mensajes.
        {ofrecer, Key, Entry} ->
            {NewMap, NuevosMetadatos} =
                simple_kv_capacidad:aceptar_oferta(Key, Entry, Alfa, Map, Metadatos),
            loop(Peers, Alfa, NewMap, NuevosMetadatos, Pendientes);
        %% ---------- respuesta a una consulta mia (4.8) ----------
        {respuesta_consulta, ConsultaRef, Peer, Resultado} ->
            case maps:find(ConsultaRef, Pendientes) of
                {ok, {Client, Ref, Key, Faltan}} ->
                    case lists:member(Peer, Faltan) of
                        false ->
                            loop(Peers, Alfa, Map, Metadatos, Pendientes);
                        true ->
                            Client ! {Ref, candidato, Resultado},
                            Restantes = lists:delete(Peer, Faltan),
                            case Restantes of
                                [] ->
                                    Client ! {Ref, candidato,
                                        simple_kv_almacen:buscar_local(Key, Map, Metadatos)},
                                    Client ! {Ref, fin},
                                    loop(Peers, Alfa, Map, Metadatos,
                                         maps:remove(ConsultaRef, Pendientes));
                                _ ->
                                    Actualizado = {Client, Ref, Key, Restantes},
                                    loop(Peers, Alfa, Map, Metadatos,
                                         maps:put(ConsultaRef, Actualizado, Pendientes))
                            end
                    end;
                error ->
                    loop(Peers, Alfa, Map, Metadatos, Pendientes)
            end;

        %% ---------- descartar mensajes inesperados (5.1) ----------
        _ ->
            loop(Peers, Alfa, Map, Metadatos, Pendientes)
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
