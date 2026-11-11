-module(simple_kv_consultas).
-export([iniciar/6, responder/3, recibir_respuesta/6]).

%% Manda {consultar, ...} a todos los pares y registra el get pendiente.
iniciar(Peers, Client, Ref, Key, Local, Pendientes) ->
    Client ! {Ref, candidato, Local},
    Yo = self(),
    ConsultaRef = make_ref(),
    lists:foreach(
        fun(Peer) -> Peer ! {consultar, Yo, ConsultaRef, Key} end,
        Peers
    ),
    maps:put(ConsultaRef, {Client, Ref, Key, Peers}, Pendientes).

%% Tambien lo local pasa por el cliente para revisar TTL justo antes de retornar.
responder(Client, Ref, Resultado) ->
    Client ! {Ref, candidato, Resultado},
    Client ! {Ref, fin}.

%% Solo se acepta una respuesta de cada par esperado para esa consulta.
recibir_respuesta(ConsultaRef, Peer, Resultado, Map, Metadatos, Pendientes) ->
    case maps:find(ConsultaRef, Pendientes) of
        {ok, {Client, Ref, Key, Faltan}} ->
            case lists:member(Peer, Faltan) of
                false -> Pendientes;
                true ->
                    Client ! {Ref, candidato, Resultado},
                    Restantes = lists:delete(Peer, Faltan),
                    case Restantes of
                        [] ->
                            Client ! {Ref, candidato,
                                simple_kv_almacen:buscar_local(Key, Map, Metadatos)},
                            Client ! {Ref, fin},
                            maps:remove(ConsultaRef, Pendientes);
                        _ ->
                            maps:put(ConsultaRef, {Client, Ref, Key, Restantes}, Pendientes)
                    end
            end;
        error -> Pendientes
    end.
