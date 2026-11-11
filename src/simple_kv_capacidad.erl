-module(simple_kv_capacidad).
-export([guardar/6, aceptar_oferta/5, candidato_a_desalojar/1, desalojar/3]).

-type entry() :: {integer(), {value, term(), integer() | infinity}}.
-type valores() :: #{term() => entry()}.
-type metadatos() :: #{term() => {integer(), valor | borrado | desalojado}}.

%% Conserva las Alfa entradas de mayor version, sin distinguir origen.
%% Reserva lugar antes de insertar, sin construir un mapa de Alfa+1 valores.
guardar(Peers, Alfa, Key, {Version, {value, _, Vence}} = Entry, Map, Metadatos) ->
    case simple_kv_ttl:vigente(Vence) of
        false ->
            Borrado = {Version, borrado},
            {simple_kv_almacen:aplicar_actualizacion(Key, Borrado, Map, Metadatos),
             simple_kv_almacen:registrar_metadata(Key, Borrado, Metadatos)};
        true -> guardar_vigente(Peers, Alfa, Key, Entry, Map, Metadatos)
    end.

guardar_vigente(Peers, Alfa, Key, Entry, Map, Metadatos) ->
    {Limpio, Meta} = limpiar_vencidos(Map, Metadatos),
    case maps:is_key(Key, Limpio) orelse map_size(Limpio) < Alfa of
        true -> aplicar(Key, Entry, Limpio, Meta);
        false ->
            {Version, _} = Entry,
            Candidato = candidato_a_desalojar(Limpio),
            case Candidato of
                ninguno -> rechazar(Peers, Key, Entry, Limpio, Meta);
                {OtraKey, {OtraVersion, _} = OtraEntry} ->
                    case Version > OtraVersion of
                        true ->
                            simple_kv_replicacion:ofrecer(Peers, OtraKey, OtraEntry),
                            {Reducido, NuevaMeta} = desalojar(OtraKey, Limpio, Meta),
                            aplicar(Key, Entry, Reducido, NuevaMeta);
                        false -> rechazar(Peers, Key, Entry, Limpio, Meta)
                    end
            end
    end.

aplicar(Key, {Version, {value, _, Vence}} = Entry, Map, Meta) ->
    Aplicada = case simple_kv_ttl:vigente(Vence) of
        true -> Entry;
        false -> {Version, borrado}
    end,
    {simple_kv_almacen:aplicar_actualizacion(Key, Aplicada, Map, Meta),
     simple_kv_almacen:registrar_metadata(Key, Aplicada, Meta)}.

rechazar(Peers, Key, {Version, {value, _, Vence}} = Entry, Map, Meta) ->
    case simple_kv_ttl:vigente(Vence) of
        true ->
            simple_kv_replicacion:ofrecer(Peers, Key, Entry),
            {Map, maps:put(Key, {Version, desalojado}, Meta)};
        false -> {Map, maps:put(Key, {Version, borrado}, Meta)}
    end.

%% ---------------------------------------------------------------------
%% Recepcion de una oferta
%%
%% La replica que recibe la oferta la guarda SOLO si:
%%  - el valor sigue vigente,
%%  - no conoce una version mas nueva de la clave, y
%%  - tiene lugar (o la clave ya ocupa un lugar en su Map).
%%
%% Nunca desaloja ni manda mensajes al procesar una oferta. Por eso cada
%% desalojo genera como mucho un mensaje por par y la secuencia termina.
%% Si todas las replicas estan llenas, el valor se pierde (lo admite 4.7).
%% ---------------------------------------------------------------------
-spec aceptar_oferta(term(), term(), pos_integer(), valores(), metadatos()) ->
    {valores(), metadatos()}.
aceptar_oferta(Key, {_Version, {value, _Val, Vence}} = Entry, Alfa, Map, Metadatos) ->
    {MapLimpio, MetadatosLimpios} = limpiar_vencidos(Map, Metadatos),
    Vigente = simple_kv_ttl:vigente(Vence),
    EsNuevo = simple_kv_almacen:es_mensaje_nuevo(Key, Entry, MetadatosLimpios),
    HayLugar = maps:is_key(Key, MapLimpio) orelse map_size(MapLimpio) < Alfa,
    case Vigente andalso EsNuevo andalso HayLugar of
        true ->
            {simple_kv_almacen:aplicar_actualizacion(Key, Entry, MapLimpio, MetadatosLimpios),
             simple_kv_almacen:registrar_metadata(Key, Entry, MetadatosLimpios)};
        false ->
            {MapLimpio, MetadatosLimpios}
    end;
aceptar_oferta(_Key, _Entry, _Alfa, Map, Metadatos) ->
    {Map, Metadatos}.

%% ---------------------------------------------------------------------
%% Auxiliares
%% ---------------------------------------------------------------------

%% El valor de menor version: el escrito hace mas tiempo.
-spec candidato_a_desalojar(valores()) -> ninguno | {term(), entry()}.
candidato_a_desalojar(Valores) when is_map(Valores) ->
    maps:fold(
        fun
            (Key, Entry, ninguno) ->
                {Key, Entry};
            (Key, {Version, _} = Entry, {_KeyAcc, {VersionAcc, _}}) when Version < VersionAcc ->
                {Key, Entry};
            (_Key, _Entry, Acc) ->
                Acc
        end,
        ninguno,
        Valores
    ).

%% Saca el valor del Map y deja la marca 'desalojado' con SU MISMA version.
-spec desalojar(term(), valores(), metadatos()) -> {valores(), metadatos()}.
desalojar(Key, Map, Metadatos) -> 
    {ok, {Version, _Contenido}} = maps:find(Key, Map),
    NuevoMap = maps:remove(Key, Map),
    NuevosMetadatos = maps:put(Key, {Version, desalojado}, Metadatos),
    {NuevoMap, NuevosMetadatos}.

%% Un valor vencido sale del Map y queda como 'borrado' con su misma
%% version: ya no existe para nadie y un put viejo atrasado no lo revive.
-spec limpiar_vencidos(valores(), metadatos()) -> {valores(), metadatos()}.
limpiar_vencidos(Map, Metadatos) ->
    maps:fold(
        fun(Key, {Version, {value, _Val, Vence}}, {M, Meta}) ->
            case simple_kv_ttl:vigente(Vence) of
                true -> {M, Meta};
                false -> {maps:remove(Key, M), maps:put(Key, {Version, borrado}, Meta)}
            end
        end,
        {Map, Metadatos},
        Map
    ).
