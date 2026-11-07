-module(simple_kv_replica).
-export([init/0]).

init() ->
    receive
        {peers, Peers} -> loop(Peers, #{}, #{}, #{})
    end.

loop(Peers, Map, Metadatos, Pendientes) ->
    receive
        {consultar, Solicitante, ConsultaRef, Key} ->
            Solicitante !
                {
                    respuesta_consulta,
                    ConsultaRef,
                    self(),
                    simple_kv_almacen:buscar_local(Key, Map, Metadatos)
                },
            loop(Peers, Map, Metadatos, Pendientes);
        stop ->
            ok;
        {put, Client, Ref, Key, Val, Time} ->
            Estado = simple_kv_capacidad:estado_capacidad(Map),
            {MapaFinal, MetadatosFinales} =
                case Estado of
                    {con_espacio, _} ->
                        Entry = {
                            simple_kv_replicacion:nueva_version(),
                            {value, Val, simple_kv_ttl:expira(Time)}
                        },
                        NuevosMetadatos = simple_kv_almacen:registrar_metadata(
                            Key, Entry, Metadatos
                        ),
                        NewMap = maps:put(Key, Entry, Map),
                        Client ! {Ref, ok},
                        simple_kv_replicacion:replicar_put(Peers, Key, Entry),
                        {NewMap, NuevosMetadatos};
                    {llena, _} ->
                        Candidato = simple_kv_capacidad:candidato_a_desalojar(Map),
                        case Candidato of
                            %% no deberia llegar nunca a esta caso
                            ninguno ->
                                erlang:error(capacidad_llena_sin_candidato);
                            {KeyDesalojada, _Entry} ->
                                {MapDesalojado, MetadatosDesalojados} = simple_kv_capacidad:desalojar(
                                    KeyDesalojada, Map, Metadatos
                                ),
                                Entry = {
                                    simple_kv_replicacion:nueva_version(),
                                    {value, Val, simple_kv_ttl:expira(Time)}
                                },
                                NuevosMetadatos = simple_kv_almacen:registrar_metadata(
                                    Key, Entry, MetadatosDesalojados
                                ),
                                NewMap = maps:put(Key, Entry, MapDesalojado),
                                Client ! {Ref, ok},
                                simple_kv_replicacion:replicar_put(Peers, Key, Entry),
                                {NewMap, NuevosMetadatos}
                        end;
                    {excedida, Cantidad} ->
                        %% no deberia llegar nunca a esta caso
                        erlang:error({capacidad_excedida, Cantidad})
                end,

            loop(Peers, MapaFinal, MetadatosFinales, Pendientes);
        {delete, Client, Ref, Key} ->
            Entry = {simple_kv_replicacion:nueva_version(), borrado},
            NuevosMetadatos = simple_kv_almacen:registrar_metadata(Key, Entry, Metadatos),
            NewMap = maps:remove(Key, Map),
            Client ! {Ref, ok},
            simple_kv_replicacion:replicar_delete(Peers, Key, Entry),
            loop(Peers, NewMap, NuevosMetadatos, Pendientes);
        {get, Client, Ref, Key} ->
            Local = simple_kv_almacen:buscar_local(Key, Map, Metadatos),
            case Local of
                %% fue borrado en la replica
                {ok, {_Version, borrado}} ->
                    Client ! {Ref, not_found},
                    loop(Peers, Map, Metadatos, Pendientes);
                %% existe en la replica
                {ok, {_Version, {value, Value, Vencimiento}}} ->
                    case simple_kv_ttl:vigente(Vencimiento) of
                        true ->
                            Client ! {Ref, ok, Value};
                        false ->
                            Client ! {Ref, not_found}
                    end,
                    loop(Peers, Map, Metadatos, Pendientes);
                {ok, {_Version, desalojado}} ->
                    case Peers of
                        [] ->
                            Client ! {Ref, not_found},
                            loop(Peers, Map, Metadatos, Pendientes);
                        _ ->
                            ConsultaRef = make_ref(),
                            NuevoPendiente = {Client, Ref, Key, Peers, Local},
                            NuevosPendientes =
                                maps:put(ConsultaRef, NuevoPendiente, Pendientes),
                            lists:foreach(
                                fun(Peer) ->
                                    Peer ! {consultar, self(), ConsultaRef, Key}
                                end,
                                Peers
                            ),
                            loop(Peers, Map, Metadatos, NuevosPendientes)
                    end;
                error ->
                    case Peers of
                        [] ->
                            Client ! {Ref, not_found},
                            loop(Peers, Map, Metadatos, Pendientes);
                        _ ->
                            ConsultaRef = make_ref(),
                            NuevoPendiente = {Client, Ref, Key, Peers, error},
                            NuevosPendientes =
                                maps:put(ConsultaRef, NuevoPendiente, Pendientes),
                            lists:foreach(
                                fun(Peer) ->
                                    Peer ! {consultar, self(), ConsultaRef, Key}
                                end,
                                Peers
                            ),
                            loop(Peers, Map, Metadatos, NuevosPendientes)
                    end
            end;
        {replica_put, Key, {_, {value, _, _}} = Entry} ->
            {NewMap, NuevosMetadatos} =
                simple_kv_almacen:actualizar_estado_por_put_replicado(
                    Key, Entry, Map, Metadatos
                ),
            loop(Peers, NewMap, NuevosMetadatos, Pendientes);
        {replica_delete, Key, {_, borrado} = Entry} ->
            {NewMap, NuevosMetadatos} =
                simple_kv_almacen:actualizar_estado_por_delete_replicado(
                    Key, Entry, Map, Metadatos
                ),
            loop(Peers, NewMap, NuevosMetadatos, Pendientes);
        {respuesta_consulta, ConsultaRef, Peer, Resultado} ->
            case maps:find(ConsultaRef, Pendientes) of
                {ok, {Client, Ref, Key, Faltan, Mejor}} ->
                    case lists:member(Peer, Faltan) of
                        false ->
                            loop(Peers, Map, Metadatos, Pendientes);
                        true ->
                            NuevoMejor = simple_kv_replicacion:elegir_mayor(Mejor, Resultado),
                            Restantes = lists:delete(Peer, Faltan),
                            case Restantes of
                                [] ->
                                    Final = simple_kv_replicacion:elegir_mayor(
                                        NuevoMejor,
                                        simple_kv_almacen:buscar_local(Key, Map, Metadatos)
                                    ),
                                    responder_lectura(Client, Ref, Final),

                                    loop(
                                        Peers,
                                        Map,
                                        Metadatos,
                                        maps:remove(ConsultaRef, Pendientes)
                                    );
                                _ ->
                                    Actualizado =
                                        {Client, Ref, Key, Restantes, NuevoMejor},
                                    loop(
                                        Peers,
                                        Map,
                                        Metadatos,
                                        maps:put(
                                            ConsultaRef, Actualizado, Pendientes
                                        )
                                    )
                            end
                    end;
                error ->
                    loop(Peers, Map, Metadatos, Pendientes)
            end;
        _ ->
            loop(Peers, Map, Metadatos, Pendientes)
    end.

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
