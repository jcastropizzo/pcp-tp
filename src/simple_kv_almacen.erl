-module(simple_kv_almacen).
-export([buscar_local/3, registrar_metadata/3, aplicar_actualizacion/4, es_mensaje_nuevo/3]).

buscar_local(Key, Map, Metadatos) ->
    case maps:find(Key, Metadatos) of
        {ok, {Version, borrado}} ->
            {ok, {Version, borrado}};
        {ok, {Version, desalojado}} ->
            {ok, {Version, desalojado}};
        {ok, {_Version, valor}} ->
            maps:find(Key, Map);
        error ->
            error
    end.

registrar_metadata(Key, {Version, Contenido}, Metadatos) ->
    Estado =
        case Contenido of
            borrado -> borrado;
            {value, _, _} -> valor
        end,
    case maps:find(Key, Metadatos) of
        {ok, {Version, desalojado}} when Estado =:= valor ->
            maps:put(Key, {Version, valor}, Metadatos);
        {ok, {Actual, _}} when Actual >= Version ->
            Metadatos;
        _ ->
            maps:put(Key, {Version, Estado}, Metadatos)
    end.

%% Devuelve el mapa de valores resultante; NO modifica los metadatos.
%% Nueva es la entrada completa recibida: {VersionNueva, Contenido}.
aplicar_actualizacion(Key, {VersionNueva, Contenido} = Nueva, Map, Metadatos) ->
    %% Consultamos la version conocida aunque el valor ya no este en Map.
    case maps:find(Key, Metadatos) of
        {ok, {VersionActual, Estado}} when VersionActual == VersionNueva ->
            %% Misma version: recuperamos el valor solo si estaba desalojado.
            case {Estado, Contenido} of
                {desalojado, {value, _, _}} ->
                    maps:put(Key, Nueva, Map);
                _ ->
                    Map
            end;
        {ok, {VersionActual, _}} when VersionActual > VersionNueva ->
            %% Llego una actualizacion vieja: conservamos el mapa actual.
            Map;
        _ ->
            %% No conocemos la clave, o la version recibida es mas nueva.
            case Contenido of
                borrado -> maps:remove(Key, Map);
                {value, _, _} -> maps:put(Key, Nueva, Map)
            end
    end.

%% Compara versiones; una version igual tambien se considera aceptable.
-spec es_mensaje_nuevo(
    term(),
    {integer(), term()},
    #{term() => {integer(), valor | borrado | desalojado}}
) -> boolean().
es_mensaje_nuevo(Key, {VersionNueva, _Contenido}, Metadatos) ->
    case maps:find(Key, Metadatos) of
        error -> true;
        {ok, {VersionActual, _Estado}} -> VersionNueva >= VersionActual
    end.
