-module(simple_kv_replica).
-export([init/0]).

%% Estado de la replica (solo en los argumentos de loop):
%%   Peers      : pids de las otras replicas
%%   Alfa       : capacidad maxima de valores (4.7)
%%   Locales    : Key => Version, ultimas ceil(3*Alfa/4) escrituras locales (sin valores)
%%   Map        : Key => {Version, {value, Val, Vence}}      (solo valores)
%%   Metadatos  : Key => {Version, valor | borrado | desalojado}
%%   Pendientes : ConsultaRef => {Client, Ref, Key, Faltan}  (gets en curso, 4.8)

init() ->
    receive
        {peers, Peers, Alfa} -> loop(Peers, Alfa, #{}, #{}, #{}, #{});
        _ -> init()
    end.

loop(Peers, Alfa, Map, Metadatos, Pendientes, Locales) ->
    receive
        %% ---------- otra replica pregunta por una clave (4.8) ----------
        %% Se responde enseguida con lo local: nunca se espera a nadie (5.2).
        {consultar, Solicitante, ConsultaRef, Key} ->
            Solicitante !
                {respuesta_consulta, ConsultaRef, self(),
                 simple_kv_almacen:buscar_local(Key, Map, Metadatos)},
            loop(Peers, Alfa, Map, Metadatos, Pendientes, Locales);

        stop ->
            ok;

        %% ---------- put del cliente ----------
        %% Reserva lugar antes de insertar; protege las escrituras locales recientes.
        %% Sobrescribir una clave existente no aumenta el tamano.
        {put, Client, Ref, Key, Val, Time} ->
            Entry = {simple_kv_replicacion:nueva_version(),
                     {value, Val, simple_kv_ttl:expira(Time)}},
            NuevosLocales = simple_kv_capacidad:registrar_local(Key, Entry, Alfa, Locales),
            {NewMap, NuevosMetadatos} = simple_kv_capacidad:guardar(
                Peers, Alfa, Key, Entry, Map, Metadatos, NuevosLocales),
            Client ! {Ref, ok},
            simple_kv_replicacion:replicar(Peers, Key, Entry),
            loop(Peers, Alfa, NewMap, NuevosMetadatos, Pendientes, NuevosLocales);
        %% ---------- delete del cliente (tombstone) ----------
        {delete, Client, Ref, Key} ->
            Entry = {simple_kv_replicacion:nueva_version(), borrado},
            NuevosMetadatos = simple_kv_almacen:registrar_metadata(Key, Entry, Metadatos),
            NewMap = maps:remove(Key, Map),
            Client ! {Ref, ok},
            simple_kv_replicacion:replicar(Peers, Key, Entry),
            loop(Peers, Alfa, NewMap, NuevosMetadatos, Pendientes, Locales);

        %% ---------- get del cliente ----------
        {get, Client, Ref, Key} ->
            Local = simple_kv_almacen:buscar_local(Key, Map, Metadatos),
            case Local of
                %% tengo el valor: respondo (la API del cliente chequea el TTL)
                {ok, {_Version, {value, _Val, _Vence}}} ->
                    responder_lectura(Client, Ref, Local),
                    loop(Peers, Alfa, Map, Metadatos, Pendientes, Locales);
                %% fue borrado: not_found
                {ok, {_Version, borrado}} ->
                    responder_lectura(Client, Ref, Local),
                    loop(Peers, Alfa, Map, Metadatos, Pendientes, Locales);
                %% desalojado o desconocido, y no hay a quien preguntar
                _ when Peers =:= [] ->
                    responder_lectura(Client, Ref, Local),
                    loop(Peers, Alfa, Map, Metadatos, Pendientes, Locales);
                %% desalojado o desconocido: pregunto a los pares (4.8)
                %% y sigo atendiendo mensajes sin bloquearme (5.2)
                _ ->
                    NuevosPendientes =
                        consultar_pares(Peers, Client, Ref, Key, Local, Pendientes),
                    loop(Peers, Alfa, Map, Metadatos, NuevosPendientes, Locales)
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
                                    Peers, Alfa, Key, Entry, Map, Metadatos, Locales)
                        end;
                    false -> {Map, Metadatos}
                end,
            loop(Peers, Alfa, NewMap, NuevosMetadatos, Pendientes, Locales);

        %% ---------- otra replica me ofrece un valor que va a desalojar ----------
        %% Nunca desaloja ni envia mensajes: la cadena termina aca.
        {ofrecer, Key, Entry} ->
            {NewMap, NuevosMetadatos} =
                simple_kv_capacidad:aceptar_oferta(Key, Entry, Alfa, Map, Metadatos),
            loop(Peers, Alfa, NewMap, NuevosMetadatos, Pendientes, Locales);
        %% ---------- respuesta a una consulta mia (4.8) ----------
        {respuesta_consulta, ConsultaRef, Peer, Resultado} ->
            case maps:find(ConsultaRef, Pendientes) of
                {ok, {Client, Ref, Key, Faltan}} ->
                    case lists:member(Peer, Faltan) of
                        false ->
                            loop(Peers, Alfa, Map, Metadatos, Pendientes, Locales);
                        true ->
                            Client ! {Ref, candidato, Resultado},
                            Restantes = lists:delete(Peer, Faltan),
                            case Restantes of
                                [] ->
                                    Client ! {Ref, candidato,
                                        simple_kv_almacen:buscar_local(Key, Map, Metadatos)},
                                    Client ! {Ref, fin},
                                    loop(Peers, Alfa, Map, Metadatos,
                                         maps:remove(ConsultaRef, Pendientes), Locales);
                                _ ->
                                    Actualizado = {Client, Ref, Key, Restantes},
                                    loop(Peers, Alfa, Map, Metadatos,
                                         maps:put(ConsultaRef, Actualizado, Pendientes), Locales)
                            end
                    end;
                error ->
                    loop(Peers, Alfa, Map, Metadatos, Pendientes, Locales)
            end;

        %% ---------- descartar mensajes inesperados (5.1) ----------
        _ ->
            loop(Peers, Alfa, Map, Metadatos, Pendientes, Locales)
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
