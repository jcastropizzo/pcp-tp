-module(simple_kv_capacidad).
-export([hacer_lugar/4, aceptar_oferta/5, candidato_a_desalojar/1, desalojar/3]).

-type entry() :: {integer(), {value, term(), integer() | infinity}}.
-type valores() :: #{term() => entry()}.
-type metadatos() :: #{term() => {integer(), valor | borrado | desalojado}}.

%% ---------------------------------------------------------------------
%% Politica de desalojo (4.7)
%%
%% Se llama DESPUES de insertar un valor (put local o replica recibida).
%%  1. Si hay a lo sumo Alfa valores, no hace nada.
%%  2. Si hay mas de Alfa, primero retira los vencidos: no sirven para
%%     nada y sacarlos no pierde ningun dato valido.
%%  3. Si sigue habiendo mas de Alfa, desaloja el valor de MENOR version
%%     (el escrito hace mas tiempo). Antes de descartarlo lo ofrece a las
%%     demas replicas.
%%
%% Por que se conserva el 75 % mas reciente: las versiones salen de
%% erlang:unique_integer([monotonic]), que siempre crece. Como se inserta
%% de a un valor, cuando hay que desalojar hay Alfa + 1 valores y sale
%% solo el de menor version. Los Alfa mas recientes siguen disponibles,
%% que es mas que el 75 % pedido.
%% ---------------------------------------------------------------------
-spec hacer_lugar([pid()], pos_integer(), valores(), metadatos()) ->
    {valores(), metadatos()}.
hacer_lugar(Peers, Alfa, Map, Metadatos) ->
    case map_size(Map) > Alfa of
        false ->
            {Map, Metadatos};
        true ->
            {MapLimpio, MetadatosLimpios} = limpiar_vencidos(Map, Metadatos),
            desalojar_hasta(Peers, Alfa, MapLimpio, MetadatosLimpios)
    end.

%% Desaloja de a un valor mientras se supere Alfa.
-spec desalojar_hasta([pid()], pos_integer(), valores(), metadatos()) ->
    {valores(), metadatos()}.
desalojar_hasta(Peers, Alfa, Map, Metadatos) ->
    case map_size(Map) > Alfa of
        false ->
            {Map, Metadatos};
        true ->
            {Key, Entry} = candidato_a_desalojar(Map),
            simple_kv_replicacion:ofrecer(Peers, Key, Entry),
            {NuevoMap, NuevosMetadatos} = desalojar(Key, Map, Metadatos),
            desalojar_hasta(Peers, Alfa, NuevoMap, NuevosMetadatos)
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
