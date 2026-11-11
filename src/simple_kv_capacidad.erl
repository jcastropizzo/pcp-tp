-module(simple_kv_capacidad).
-export([guardar/6, aceptar_oferta/6, candidato_a_desalojar/1]).

-type entry() :: {integer(), {value, term(), integer() | infinity}}.
-type valores() :: #{term() => entry()}.
-type metadatos() :: #{term() => {integer(), valor | borrado | desalojado}}.
-type recientes() :: #{term() => integer()}.
-type estado() :: {valores(), metadatos(), recientes()}.

-spec guardar([pid()], pos_integer(), term(), entry(), valores(),
              {metadatos(), recientes()}) -> estado().
guardar(Peers, Alfa, Key, Entry, Map, {Metadatos, Recientes}) ->
    NuevosRecientes = registrar_escritura(Alfa, Key, Entry, Recientes),
    case simple_kv_almacen:es_mensaje_nuevo(Key, Entry, Metadatos) of
        false ->
            {Map, Metadatos, NuevosRecientes};
        true ->
            case hay_lugar(Key, Alfa, Map) of
                true ->
                    aplicar(Key, Entry, Map, Metadatos, NuevosRecientes);
                false ->
                    Elegibles = elegibles(Map, NuevosRecientes),
                    Candidatos = case maps:is_key(Key, NuevosRecientes) of
                        true -> Elegibles;
                        false -> maps:put(Key, Entry, Elegibles)
                    end,
                    {Victima, Valor} = elegir_descarte(Candidatos),
                    {Reducido, Meta} = desalojar(Peers, Victima, Valor, Map, Metadatos),
                    case Victima =:= Key of
                        true -> {Reducido, Meta, NuevosRecientes};
                        false -> aplicar(Key, Entry, Reducido, Meta, NuevosRecientes)
                    end
            end
    end.

%% Las ofertas pueden reutilizar una plaza vencida no protegida. No generan
%% ofertas nuevas, aun cuando el receptor tenga el mapa lleno.
-spec aceptar_oferta(term(), term(), pos_integer(), valores(), metadatos(),
                     recientes()) -> estado().
aceptar_oferta(Key, {_, {value, _, Vence}} = Entry, Alfa, Map, Metadatos, Recientes) ->
    case simple_kv_ttl:vigente(Vence)
         andalso simple_kv_almacen:es_mensaje_nuevo(Key, Entry, Metadatos) of
        false ->
            {Map, Metadatos, Recientes};
        true ->
            NuevosRecientes = registrar_escritura(Alfa, Key, Entry, Recientes),
            case hay_lugar(Key, Alfa, Map) of
                true ->
                    aplicar(Key, Entry, Map, Metadatos, NuevosRecientes);
                false ->
                    case candidato_vencido(elegibles(Map, NuevosRecientes)) of
                        ninguno ->
                            {Map, Metadatos, Recientes};
                        {Victima, Valor} ->
                            {Reducido, Meta} = desalojar([], Victima, Valor, Map, Metadatos),
                            aplicar(Key, Entry, Reducido, Meta, NuevosRecientes)
                    end
            end
    end;
aceptar_oferta(_Key, _Entry, _Alfa, Map, Metadatos, Recientes) ->
    {Map, Metadatos, Recientes}.

%% El ranking guarda a lo sumo ceil(0,75 * Alfa) claves y versiones de put.
%% Un delete libera la plaza del valor y deja intacto el orden de las escrituras.
registrar_escritura(Alfa, Key, {Version, _}, Recientes) ->
    case maps:find(Key, Recientes) of
        {ok, Actual} when Actual >= Version ->
            Recientes;
        _ ->
            Nuevos = maps:put(Key, Version, Recientes),
            case map_size(Nuevos) > (3 * Alfa + 3) div 4 of
                false -> Nuevos;
                true ->
                    {_, Primera} = lists:min([{V, K} || {K, V} <- maps:to_list(Nuevos)]),
                    maps:remove(Primera, Nuevos)
            end
    end.

hay_lugar(Key, Alfa, Map) ->
    maps:is_key(Key, Map) orelse map_size(Map) < Alfa.

elegibles(Map, Recientes) ->
    maps:without(maps:keys(Recientes), Map).

elegir_descarte(Candidatos) ->
    case candidato_vencido(Candidatos) of
        ninguno -> candidato_a_desalojar(Candidatos);
        Vencido -> Vencido
    end.

candidato_vencido(Valores) ->
    Vencidos = maps:filter(
        fun(_Key, {_, {value, _, Vence}}) -> not simple_kv_ttl:vigente(Vence) end,
        Valores),
    candidato_a_desalojar(Vencidos).

-spec candidato_a_desalojar(valores()) -> ninguno | {term(), entry()}.
candidato_a_desalojar(Valores) when is_map(Valores) ->
    maps:fold(
        fun
            (Key, Entry, ninguno) ->
                {Key, Entry};
            (Key, {Version, _} = Entry, {_, {VersionAcc, _}}) when Version < VersionAcc ->
                {Key, Entry};
            (_Key, _Entry, Acc) ->
                Acc
        end,
        ninguno,
        Valores
    ).

desalojar(Peers, Key, {Version, {value, _, Vence}} = Entry, Map, Metadatos) ->
    case simple_kv_ttl:vigente(Vence) of
        true -> simple_kv_replicacion:ofrecer(Peers, Key, Entry);
        false -> ok
    end,
    {maps:remove(Key, Map), maps:put(Key, {Version, desalojado}, Metadatos)}.

aplicar(Key, Entry, Map, Metadatos, Recientes) ->
    {simple_kv_almacen:aplicar_actualizacion(Key, Entry, Map, Metadatos),
     simple_kv_almacen:registrar_metadata(Key, Entry, Metadatos),
     Recientes}.
