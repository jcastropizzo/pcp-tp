-module(simple_kv_capacidad).
-export([guardar/6, aceptar_oferta/6, entrada_mas_antigua/1]).

-type entrada() :: {integer(), {value, term(), integer() | infinity}}.
-type valores() :: #{term() => entrada()}.
-type metadatos() :: #{term() => {integer(), valor | borrado | desalojado}}.
-type recientes() :: #{term() => integer()}.
-type estado() :: {valores(), metadatos(), recientes()}.

-spec guardar([pid()], pos_integer(), term(), entrada(), valores(),
              {metadatos(), recientes()}) -> estado().
guardar(Pares, Alfa, Clave, Entrada, Valores, {Metadatos, Recientes}) ->
    NuevosRecientes = registrar_escritura(Alfa, Clave, Entrada, Recientes),
    case simple_kv_almacen:version_no_obsoleta(Clave, Entrada, Metadatos) of
        false ->
            {Valores, Metadatos, NuevosRecientes};
        true ->
            case hay_lugar(Clave, Alfa, Valores) of
                true ->
                    aplicar(Clave, Entrada, Valores, Metadatos, NuevosRecientes);
                false ->
                    Elegibles = elegibles(Valores, NuevosRecientes),
                    Candidatos = case maps:is_key(Clave, NuevosRecientes) of
                        true -> Elegibles;
                        false -> maps:put(Clave, Entrada, Elegibles)
                    end,
                    {Victima, Valor} = elegir_descarte(Candidatos),
                    {Reducido, Meta} = desalojar(Pares, Victima, Valor, Valores, Metadatos),
                    case Victima =:= Clave of
                        true -> {Reducido, Meta, NuevosRecientes};
                        false -> aplicar(Clave, Entrada, Reducido, Meta, NuevosRecientes)
                    end
            end
    end.

%% Aceptar una oferta puede liberar una plaza vencida elegible. Al tramitarla
%% sin emitir mensajes, el receptor corta la cadena de ofertas.
-spec aceptar_oferta(term(), term(), pos_integer(), valores(), metadatos(),
                     recientes()) -> estado().
aceptar_oferta(Clave, {_, {value, _, Vence}} = Entrada, Alfa, Valores, Metadatos, Recientes) ->
    case simple_kv_ttl:vigente(Vence)
         andalso simple_kv_almacen:version_no_obsoleta(Clave, Entrada, Metadatos) of
        false ->
            {Valores, Metadatos, Recientes};
        true ->
            NuevosRecientes = registrar_escritura(Alfa, Clave, Entrada, Recientes),
            case hay_lugar(Clave, Alfa, Valores) of
                true ->
                    aplicar(Clave, Entrada, Valores, Metadatos, NuevosRecientes);
                false ->
                    case candidato_vencido(elegibles(Valores, NuevosRecientes)) of
                        ninguno ->
                            {Valores, Metadatos, Recientes};
                        {Victima, Valor} ->
                            {Reducido, Meta} = desalojar([], Victima, Valor, Valores, Metadatos),
                            aplicar(Clave, Entrada, Reducido, Meta, NuevosRecientes)
                    end
            end
    end;
aceptar_oferta(_Clave, _Entrada, _Alfa, Valores, Metadatos, Recientes) ->
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
        fun(_Clave, {_, {value, _, Vence}}) -> not simple_kv_ttl:vigente(Vence) end,
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

desalojar(Pares, Clave, {Version, {value, _, Vence}} = Entrada, Valores, Metadatos) ->
    case simple_kv_ttl:vigente(Vence) of
        true -> simple_kv_replicacion:ofrecer(Pares, Clave, Entrada);
        false -> ok
    end,
    {maps:remove(Clave, Valores), maps:put(Clave, {Version, desalojado}, Metadatos)}.

aplicar(Clave, Entrada, Valores, Metadatos, Recientes) ->
    {simple_kv_almacen:aplicar_actualizacion(Clave, Entrada, Valores, Metadatos),
     simple_kv_almacen:registrar_metadatos(Clave, Entrada, Metadatos),
     Recientes}.
