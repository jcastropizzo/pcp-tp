-module(simple_kv_capacidad).
-export([guardar/6, aceptar_oferta/6, entrada_mas_antigua/1]).

-type entrada() :: {integer(), {valor, term(), integer() | infinity}}.
-type valores() :: #{term() => entrada()}.
-type metadatos() :: #{term() => {integer(), valor | borrado | desalojado, reference()}}.
-type recientes() :: #{term() => integer()}.
-type estado() :: {valores(), metadatos(), recientes()}.

-spec guardar(pos_integer(), term(), reference(), entrada(), valores(),
              {metadatos(), recientes()}) -> {estado(), ninguna | {term(), reference(), entrada()}}.
guardar(Alfa, Clave, Reserva, Entrada, Valores, {Metadatos, Recientes}) ->
    NuevosRecientes = registrar_escritura(Alfa, Clave, Entrada, Recientes),
    case simple_kv_almacen:version_no_obsoleta(Clave, Entrada, Metadatos) of
        false ->
            {{Valores, Metadatos, NuevosRecientes}, ninguna};
        true ->
            case hay_lugar(Clave, Alfa, Valores) of
                true ->
                    {aplicar(Clave, Reserva, Entrada, Valores, Metadatos, NuevosRecientes),
                     ninguna};
                false ->
                    Elegibles = elegibles(Valores, NuevosRecientes),
                    Candidatos = case maps:is_key(Clave, NuevosRecientes) of
                        true -> Elegibles;
                        false -> maps:put(Clave, Entrada, Elegibles)
                    end,
                    {Victima, {_, {valor, _, Vence}} = Valor} = elegir_descarte(Candidatos),
                    ReservaVictima = case Victima =:= Clave of
                        true -> Reserva;
                        false -> element(3, maps:get(Victima, Metadatos))
                    end,
                    {Reducido, Meta} = desalojar(Victima, ReservaVictima, Valor, Valores, Metadatos),
                    Estado = case Victima =:= Clave of
                        true -> {Reducido, Meta, NuevosRecientes};
                        false -> aplicar(Clave, Reserva, Entrada, Reducido, Meta, NuevosRecientes)
                    end,
                    Oferta = case simple_kv_ttl:vigente(Vence) of
                        true -> {Victima, ReservaVictima, Valor};
                        false -> ninguna
                    end,
                    {Estado, Oferta}
            end
    end.

%% Aceptar una oferta puede liberar una plaza vencida elegible. Al tramitarla
%% sin emitir mensajes, el receptor corta la cadena de ofertas.
-spec aceptar_oferta(pos_integer(), term(), reference(), term(), valores(),
                     {metadatos(), recientes()}) -> estado().
aceptar_oferta(Alfa, Clave, Reserva, {_, {valor, _, Vence}} = Entrada,
               Valores, {Metadatos, Recientes}) ->
    case simple_kv_ttl:vigente(Vence)
         andalso simple_kv_almacen:version_no_obsoleta(Clave, Entrada, Metadatos) of
        false ->
            {Valores, Metadatos, Recientes};
        true ->
            NuevosRecientes = registrar_escritura(Alfa, Clave, Entrada, Recientes),
            case hay_lugar(Clave, Alfa, Valores) of
                true ->
                    aplicar(Clave, Reserva, Entrada, Valores, Metadatos, NuevosRecientes);
                false ->
                    case candidato_vencido(elegibles(Valores, NuevosRecientes)) of
                        ninguno ->
                            {Valores, Metadatos, Recientes};
                        {Victima, Valor} ->
                            {_, _, ReservaVictima} = maps:get(Victima, Metadatos),
                            {Reducido, Meta} = desalojar(Victima, ReservaVictima, Valor, Valores, Metadatos),
                            aplicar(Clave, Reserva, Entrada, Reducido, Meta, NuevosRecientes)
                    end
            end
    end;
aceptar_oferta(_Alfa, _Clave, _Reserva, _Entrada, Valores, {Metadatos, Recientes}) ->
    {Valores, Metadatos, Recientes}.

%% El ranking conserva hasta ceil(0,75 * Alfa) versiones de escritura.
%% Un borrado libera la plaza y conserva la escritura en el ranking histórico.
registrar_escritura(Alfa, Clave, {Version, _}, Recientes) ->
    case maps:find(Clave, Recientes) of
        {ok, Actual} when Actual >= Version ->
            Recientes;
        _ ->
            Nuevos = maps:put(Clave, Version, Recientes),
            case map_size(Nuevos) > (3 * Alfa + 3) div 4 of
                false -> Nuevos;
                true ->
                    {_, Primera} = lists:min([{V, K} || {K, V} <- maps:to_list(Nuevos)]),
                    maps:remove(Primera, Nuevos)
            end
    end.

hay_lugar(Clave, Alfa, Valores) ->
    maps:is_key(Clave, Valores) orelse map_size(Valores) < Alfa.

elegibles(Valores, Recientes) ->
    maps:without(maps:keys(Recientes), Valores).

elegir_descarte(Candidatos) ->
    case candidato_vencido(Candidatos) of
        ninguno -> entrada_mas_antigua(Candidatos);
        Vencido -> Vencido
    end.

candidato_vencido(Valores) ->
    Vencidos = maps:filter(
        fun(_Clave, {_, {valor, _, Vence}}) -> not simple_kv_ttl:vigente(Vence) end,
        Valores),
    entrada_mas_antigua(Vencidos).

-spec entrada_mas_antigua(valores()) -> ninguno | {term(), entrada()}.
entrada_mas_antigua(Valores) when is_map(Valores) ->
    maps:fold(
        fun
            (Clave, Entrada, ninguno) ->
                {Clave, Entrada};
            (Clave, {Version, _} = Entrada, {_, {VersionAcc, _}}) when Version < VersionAcc ->
                {Clave, Entrada};
            (_Clave, _Entrada, Acc) ->
                Acc
        end,
        ninguno,
        Valores
    ).

desalojar(Clave, Reserva, {Version, _}, Valores, Metadatos) ->
    {maps:remove(Clave, Valores), maps:put(Clave, {Version, desalojado, Reserva}, Metadatos)}.

aplicar(Clave, Reserva, Entrada, Valores, Metadatos, Recientes) ->
    {simple_kv_almacen:aplicar_actualizacion(Clave, Entrada, Valores, Metadatos),
     simple_kv_almacen:registrar_metadatos(Clave, Reserva, Entrada, Metadatos),
     Recientes}.
