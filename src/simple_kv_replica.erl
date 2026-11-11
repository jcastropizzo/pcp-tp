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
                    simple_kv_consultas:responder(Client, Ref, Local),
                    loop(Peers, Alfa, Map, Metadatos, Pendientes, Coordinador);
                %% fue borrado: not_found
                {ok, {_Version, borrado}} ->
                    simple_kv_consultas:responder(Client, Ref, Local),
                    loop(Peers, Alfa, Map, Metadatos, Pendientes, Coordinador);
                %% desalojado o desconocido, y no hay a quien preguntar
                _ when Peers =:= [] ->
                    simple_kv_consultas:responder(Client, Ref, Local),
                    loop(Peers, Alfa, Map, Metadatos, Pendientes, Coordinador);
                %% desalojado o desconocido: pregunto a los pares (4.8)
                %% y sigo atendiendo mensajes sin bloquearme (5.2)
                _ ->
                    NuevosPendientes =
                        simple_kv_consultas:iniciar(Peers, Client, Ref, Key, Local, Pendientes),
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
            {NewMap, NuevosMetadatos} = simple_kv_ordenada:aplicar(
                Accion, Key, Entry, Map, Metadatos, Peers, Origen, Tipo),
            case self() =:= Origen andalso is_pid(Client) of
                true -> Client ! {Ref, ok}; false -> ok
            end,
            loop(Peers, Alfa, NewMap, NuevosMetadatos, Pendientes, Coordinador);
        %% ---------- respuesta a una consulta mia (4.8) ----------
        {respuesta_consulta, ConsultaRef, Peer, Resultado} ->
            NuevosPendientes = simple_kv_consultas:recibir_respuesta(
                ConsultaRef, Peer, Resultado, Map, Metadatos, Pendientes),
            loop(Peers, Alfa, Map, Metadatos, NuevosPendientes, Coordinador);

        %% ---------- descartar mensajes inesperados (5.1) ----------
        _ ->
            loop(Peers, Alfa, Map, Metadatos, Pendientes, Coordinador)
    end.
