-module(simple_kv_cupos).
-export([init/2, detener_replica/1]).

-record(cupo, {ref, residentes = #{}, fase = libre}).
-record(cambio, {clave, aplicaciones, ofertas = #{}}).

init(Replicas, Alfa) ->
    loop(Replicas, length(Replicas) * Alfa + 1, #{}, #{}).

loop(Replicas, Limite, Cupos, Cambios) ->
    receive
        {pedir_cupo, Cliente, Pedido, Clave}
                when not is_map_key(Clave, Cupos), map_size(Cupos) < Limite;
                     is_map_key(Clave, Cupos),
                     (map_get(Clave, Cupos))#cupo.fase =:= libre ->
            Cupo = case maps:find(Clave, Cupos) of
                {ok, Existente} -> Existente;
                error -> #cupo{ref = make_ref()}
            end,
            Id = make_ref(),
            Cliente ! {Pedido, permiso, Cupo#cupo.ref, Id},
            Cambio = #cambio{clave = Clave, aplicaciones = Replicas},
            loop(Replicas, Limite, Cupos#{Clave => Cupo#cupo{fase = Id}},
                 Cambios#{Id => Cambio});

        {aplicado, Id, Replica, Altas, Bajas, Ofertas} ->
            case maps:find(Id, Cambios) of
                {ok, #cambio{aplicaciones = Faltan, ofertas = Envios} = Cambio} ->
                    case lists:member(Replica, Faltan) of
                        true ->
                            Actualizado = Cambio#cambio{
                                aplicaciones = lists:delete(Replica, Faltan),
                                ofertas = registrar_ofertas(Ofertas, Envios)
                            },
                            Nuevos = registrar_residencia(Replica, Altas, Bajas, Cupos),
                            continuar(Replicas, Limite, Nuevos, Cambios, Id, Actualizado);
                        false -> loop(Replicas, Limite, Cupos, Cambios)
                    end;
                error -> loop(Replicas, Limite, Cupos, Cambios)
            end;

        {oferta_resuelta, Id, Ref, Replica, Altas, Bajas} ->
            case maps:find(Id, Cambios) of
                {ok, #cambio{ofertas = Envios} = Cambio} when map_get(Ref, Envios) =:= resuelta ->
                    loop(Replicas, Limite, Cupos, Cambios#{Id => Cambio});
                {ok, #cambio{ofertas = Envios} = Cambio} ->
                    %% El resultado puede llegar antes del informe que enumera la oferta.
                    Nuevos = registrar_residencia(Replica, Altas, Bajas, Cupos),
                    continuar(Replicas, Limite, Nuevos, Cambios, Id,
                              Cambio#cambio{ofertas = Envios#{Ref => resuelta}});
                error -> loop(Replicas, Limite, Cupos, Cambios)
            end;

        {lecturas_drenadas, Clave, Ref, Replica} ->
            loop(Replicas, Limite, confirmar_olvido(Replicas, Clave, Ref, Replica,
                                                  preparando, Cupos), Cambios);

        {olvidada, Clave, Ref, Replica} ->
            loop(Replicas, Limite, confirmar_olvido(Replicas, Clave, Ref, Replica,
                                                  olvidando, Cupos), Cambios);

        {detener, Replica} ->
            case lists:delete(Replica, Replicas) of
                [] -> ok;
                Restantes ->
                    Replica ! {detenida, self()},
                    loop(Restantes, Limite, Cupos, Cambios)
            end
    end.

registrar_ofertas(Ofertas, Envios) ->
    lists:foldl(fun({Ref, Clave}, Acc) ->
        case maps:is_key(Ref, Acc) of
            true -> Acc;
            false -> Acc#{Ref => {en_vuelo, Clave}}
        end
    end, Envios, Ofertas).

registrar_residencia(Replica, Altas, Bajas, Cupos) ->
    ConAltas = lists:foldl(fun(Clave, Acc) ->
        #cupo{residentes = R} = Cupo = maps:get(Clave, Acc),
        Acc#{Clave := Cupo#cupo{residentes = R#{Replica => true}}}
    end, Cupos, Altas),
    lists:foldl(fun(Clave, Acc) ->
        #cupo{residentes = R} = Cupo = maps:get(Clave, Acc),
        Acc#{Clave := Cupo#cupo{residentes = maps:remove(Replica, R)}}
    end, ConAltas, Bajas).

continuar(Replicas, Limite, Cupos, Cambios, Id, Cambio) ->
    #cambio{clave = Clave, aplicaciones = Faltan, ofertas = Envios} = Cambio,
    case Faltan =:= [] andalso lists:all(fun(E) -> E =:= resuelta end, maps:values(Envios)) of
        true ->
            Cupo = maps:get(Clave, Cupos),
            evaluar_olvido(Replicas, Limite, Cupos#{Clave := Cupo#cupo{fase = libre}},
                           maps:remove(Id, Cambios));
        false ->
            evaluar_olvido(Replicas, Limite, Cupos, Cambios#{Id := Cambio})
    end.

evaluar_olvido(Replicas, Limite, Cupos, Cambios) ->
    EnVuelo = maps:from_list([{K, true} || C <- maps:values(Cambios),
                                          {en_vuelo, K} <- maps:values(C#cambio.ofertas)]),
    Nuevos = maps:map(fun
        (Clave, #cupo{fase = libre, residentes = R, ref = Ref} = Cupo)
                when map_size(R) =:= 0, not is_map_key(Clave, EnVuelo) ->
            difundir(Replicas, {preparar_olvido, Clave, Ref}),
            Cupo#cupo{fase = {preparando, Replicas}};
        (_, Cupo) -> Cupo
    end, Cupos),
    loop(Replicas, Limite, Nuevos, Cambios).

confirmar_olvido(Replicas, Clave, Ref, Replica, Fase, Cupos) ->
    case maps:find(Clave, Cupos) of
        {ok, #cupo{ref = Ref, fase = {Fase, Faltan}} = Cupo} ->
            case lists:delete(Replica, Faltan) of
                [] when Fase =:= preparando ->
                    difundir(Replicas, {olvidar, Clave, Ref}),
                    Cupos#{Clave := Cupo#cupo{fase = {olvidando, Replicas}}};
                [] -> maps:remove(Clave, Cupos);
                Restantes -> Cupos#{Clave := Cupo#cupo{fase = {Fase, Restantes}}}
            end;
        _ -> Cupos
    end.

difundir(Replicas, Mensaje) ->
    lists:foreach(fun(P) -> P ! Mensaje end, Replicas).

%% La última réplica espera también la salida del coordinador.
detener_replica(Coordinador) ->
    Monitor = erlang:monitor(process, Coordinador),
    Coordinador ! {detener, self()},
    receive
        {detenida, Coordinador} -> erlang:demonitor(Monitor, [flush]), ok;
        {'DOWN', Monitor, process, Coordinador, _} -> ok
    end.
