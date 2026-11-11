-module(simple_kv_replica).
-export([init/0]).

%% Estado de la replica (solo en los argumentos de loop):
%%   Peers      : pids de las otras replicas
%%   Alfa       : capacidad maxima de valores (4.7)
%%   Map        : Key => {Version, {value, Val, Vence}}      (solo valores)
%%   Metadatos  : Key => {Version, valor | borrado | desalojado}
%%   Recientes  : Key => version de put, para el 75 % protegido (4.7)
%%   Pendientes : ConsultaRef => {Client, Ref, Key, Faltan, Mejor}  (gets en curso, 4.8)

init() ->
    receive
        {peers, Peers, Alfa} -> loop(Peers, Alfa, #{}, #{}, #{}, #{})
    end.

loop(Peers, Alfa, Map, Metadatos, Recientes, Pendientes) ->
    receive
        %% ---------- otra replica pregunta por una clave (4.8) ----------
        %% Se responde enseguida con lo local: nunca se espera a nadie (5.2).
        {consultar, Solicitante, ConsultaRef, Key} ->
            Solicitante !
                {respuesta_consulta, ConsultaRef, self(),
                 simple_kv_almacen:buscar_local(Key, Map, Metadatos)},
            loop(Peers, Alfa, Map, Metadatos, Recientes, Pendientes);

        stop ->
            ok;

        %% ---------- put del cliente ----------
        {put, Client, Ref, Key, Val, Time} ->
            Entry = {simple_kv_replicacion:nueva_version(),
                     {value, Val, simple_kv_ttl:expira(Time)}},
            {NewMap, NuevosMetadatos, NuevosRecientes} =
                simple_kv_capacidad:guardar(Peers, Alfa, Key, Entry, Map, {Metadatos, Recientes}),
            Client ! {Ref, ok},
            simple_kv_replicacion:replicar(Peers, Key, Entry),
            loop(Peers, Alfa, NewMap, NuevosMetadatos, NuevosRecientes, Pendientes);
        %% ---------- delete del cliente (tombstone) ----------
        {delete, Client, Ref, Key} ->
            Entry = {simple_kv_replicacion:nueva_version(), borrado},
            NuevosMetadatos = simple_kv_almacen:registrar_metadata(Key, Entry, Metadatos),
            NewMap = maps:remove(Key, Map),
            Client ! {Ref, ok},
            simple_kv_replicacion:replicar(Peers, Key, Entry),
            loop(Peers, Alfa, NewMap, NuevosMetadatos, Recientes, Pendientes);

        %% ---------- get del cliente ----------
        {get, Client, Ref, Key} ->
            Local = simple_kv_almacen:buscar_local(Key, Map, Metadatos),
            case Local of
                %% tengo el valor: respondo (responder_lectura chequea el TTL)
                {ok, {_Version, {value, _Val, _Vence}}} ->
                    responder_lectura(Client, Ref, Local),
                    loop(Peers, Alfa, Map, Metadatos, Recientes, Pendientes);
                %% fue borrado: not_found
                {ok, {_Version, borrado}} ->
                    responder_lectura(Client, Ref, Local),
                    loop(Peers, Alfa, Map, Metadatos, Recientes, Pendientes);
                %% desalojado o desconocido, y no hay a quien preguntar
                _ when Peers =:= [] ->
                    responder_lectura(Client, Ref, Local),
                    loop(Peers, Alfa, Map, Metadatos, Recientes, Pendientes);
                %% desalojado o desconocido: pregunto a los pares (4.8)
                %% y sigo atendiendo mensajes sin bloquearme (5.2)
                _ ->
                    NuevosPendientes =
                        consultar_pares(Peers, Client, Ref, Key, Local, Pendientes),
                    loop(Peers, Alfa, Map, Metadatos, Recientes, NuevosPendientes)
            end;
        %% ---------- cambio que llega de otra replica ----------
        {replica, Key, {_Version, borrado} = Entry} ->
            NewMap = simple_kv_almacen:aplicar_actualizacion(Key, Entry, Map, Metadatos),
            NuevosMetadatos = simple_kv_almacen:registrar_metadata(Key, Entry, Metadatos),
            loop(Peers, Alfa, NewMap, NuevosMetadatos, Recientes, Pendientes);
        {replica, Key, {_Version, {value, _, _}} = Entry} ->
            {NewMap, NuevosMetadatos, NuevosRecientes} =
                simple_kv_capacidad:guardar(Peers, Alfa, Key, Entry, Map, {Metadatos, Recientes}),
            loop(Peers, Alfa, NewMap, NuevosMetadatos, NuevosRecientes, Pendientes);

        %% ---------- otra replica ofrece un valor ----------
        {ofrecer, Key, Entry} ->
            {NewMap, NuevosMetadatos, NuevosRecientes} =
                simple_kv_capacidad:aceptar_oferta(Key, Entry, Alfa, Map, Metadatos, Recientes),
            loop(Peers, Alfa, NewMap, NuevosMetadatos, NuevosRecientes, Pendientes);
        %% ---------- respuesta a una consulta mia (4.8) ----------
        {respuesta_consulta, ConsultaRef, Peer, Resultado} ->
            case maps:find(ConsultaRef, Pendientes) of
                {ok, {Client, Ref, Key, Faltan, Mejor}} ->
                    case lists:member(Peer, Faltan) of
                        false ->
                            loop(Peers, Alfa, Map, Metadatos, Recientes, Pendientes);
                        true ->
                            NuevoMejor = simple_kv_replicacion:elegir_mayor(Mejor, Resultado),
                            Restantes = lists:delete(Peer, Faltan),
                            case Restantes of
                                [] ->
                                    %% respondieron todos: comparo una ultima vez
                                    %% con lo local (pudo cambiar mientras esperaba)
                                    Final = simple_kv_replicacion:elegir_mayor(
                                        NuevoMejor,
                                        simple_kv_almacen:buscar_local(Key, Map, Metadatos)),
                                    responder_lectura(Client, Ref, Final),
                                    loop(Peers, Alfa, Map, Metadatos, Recientes,
                                         maps:remove(ConsultaRef, Pendientes));
                                _ ->
                                    Actualizado = {Client, Ref, Key, Restantes, NuevoMejor},
                                    loop(Peers, Alfa, Map, Metadatos, Recientes,
                                         maps:put(ConsultaRef, Actualizado, Pendientes))
                            end
                    end;
                error ->
                    loop(Peers, Alfa, Map, Metadatos, Recientes, Pendientes)
            end;

        %% ---------- descartar mensajes inesperados (5.1) ----------
        _ ->
            loop(Peers, Alfa, Map, Metadatos, Recientes, Pendientes)
    end.

%% Manda {consultar, ...} a todos los pares y registra el get pendiente.
consultar_pares(Peers, Client, Ref, Key, Local, Pendientes) ->
    Yo = self(),
    ConsultaRef = make_ref(),
    lists:foreach(
        fun(Peer) -> Peer ! {consultar, Yo, ConsultaRef, Key} end,
        Peers
    ),
    maps:put(ConsultaRef, {Client, Ref, Key, Peers, Local}, Pendientes).

responder_lectura(Client, Ref, error) ->
    Client ! {Ref, not_found};
responder_lectura(Client, Ref, {ok, {_Version, borrado}}) ->
    Client ! {Ref, not_found};
responder_lectura(Client, Ref, {ok, {_Version, desalojado}}) ->
    Client ! {Ref, not_found};
responder_lectura(Client, Ref, {ok, {_Version, {value, Val, Vence}}}) ->
    case simple_kv_ttl:vigente(Vence) of
        true -> Client ! {Ref, ok, Val};
        false -> Client ! {Ref, not_found}
    end.
