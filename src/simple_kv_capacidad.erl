-module(simple_kv_capacidad).
-export([estado_capacidad/1]).
-export([candidato_a_desalojar/1]).
-export([desalojar/3]).

-type entry() :: {integer(), {value, term(), integer() | infinity}}.
-type valores() :: #{term() => entry()}.
-type metadatos() :: #{term() => {integer(), valor | borrado | desalojado}}.
-type estado_capacidad() ::
    {con_espacio, non_neg_integer()}
    | {llena, non_neg_integer()}
    | {excedida, non_neg_integer()}.

-define(CAPACIDAD_MAXIMA, 16).

%% Recibe exclusivamente el mapa de valores, sin metadatos de borrado.
%% Los valores vencidos siguen ocupando lugar hasta que se retiren.
-spec estado_capacidad(valores()) -> estado_capacidad().
estado_capacidad(Valores) when is_map(Valores) ->
    Cantidad = map_size(Valores),
    if
        Cantidad < ?CAPACIDAD_MAXIMA -> {con_espacio, Cantidad};
        Cantidad =:= ?CAPACIDAD_MAXIMA -> {llena, Cantidad};
        true -> {excedida, Cantidad}
    end.

-spec candidato_a_desalojar(valores()) -> ninguno | {term(), entry()}.
candidato_a_desalojar(Valores) when is_map(Valores) ->
    maps:fold(
        fun(Key, Entry, Acc) ->
            case Entry of
                {Version, {value, _Val, _Vencimiento}} ->
                    case Acc of
                        ninguno ->
                            {Key,Entry};
                        {_KeyAcc, {_VersionAcc,{value, _ValAcc, infinity}}} ->
                            Acc;
                        {_KeyAcc,{VersionAcc,{value, _ValAcc, _VencimientoAcc}}} ->
                            case Version > VersionAcc of
                                true -> Acc;
                                false -> {Key,Entry}
                            end
                    end
            end
        end,
        ninguno,
        Valores
    ).

-spec desalojar(term(), valores(), metadatos()) -> {valores(), metadatos()}.
desalojar(Key, Map, Metadatos) -> 
    {ok, {Version, _Entry}} = maps:find(Key, Map),
    NuevoMap = maps:remove(Key, Map),
    NuevosMetadatos = maps:put(Key,{Version, desalojado}, Metadatos),
    {NuevoMap, NuevosMetadatos}.