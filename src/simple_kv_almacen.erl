-module(simple_kv_almacen).
-export([buscar_local/3, registrar_metadatos/3, aplicar_actualizacion/4, version_no_obsoleta/3]).

buscar_local(Clave, Valores, Metadatos) ->
    case maps:find(Clave, Metadatos) of
        {ok, {Version, borrado}} ->
            {ok, {Version, borrado}};
        {ok, {Version, desalojado}} ->
            {ok, {Version, desalojado}};
        {ok, {_Version, valor}} ->
            maps:find(Clave, Valores);
        error ->
            error
    end.

registrar_metadatos(Clave, {Version, Contenido}, Metadatos) ->
    Estado =
        case Contenido of
            borrado -> borrado;
            {value, _, _} -> valor
        end,
    case maps:find(Clave, Metadatos) of
        {ok, {Version, desalojado}} when Estado =:= valor ->
            maps:put(Clave, {Version, valor}, Metadatos);
        {ok, {Actual, _}} when Actual >= Version ->
            Metadatos;
        _ ->
            maps:put(Clave, {Version, Estado}, Metadatos)
    end.

%% Una marca conserva la versión aunque el valor haya salido del mapa.
aplicar_actualizacion(Clave, {VersionNueva, Contenido} = Nueva, Valores, Metadatos) ->
    case maps:find(Clave, Metadatos) of
        {ok, {VersionActual, Estado}} when VersionActual == VersionNueva ->
            %% Una copia de igual versión puede completar un desalojo previo.
            case {Estado, Contenido} of
                {desalojado, {value, _, _}} ->
                    maps:put(Clave, Nueva, Valores);
                _ ->
                    Valores
            end;
        {ok, {VersionActual, _}} when VersionActual > VersionNueva ->
            Valores;
        _ ->
            case Contenido of
                borrado -> maps:remove(Clave, Valores);
                {value, _, _} -> maps:put(Clave, Nueva, Valores)
            end
    end.

%% Una versión igual permite recuperar una copia desalojada.
-spec version_no_obsoleta(
    term(),
    {integer(), term()},
    #{term() => {integer(), valor | borrado | desalojado}}
) -> boolean().
version_no_obsoleta(Clave, {VersionNueva, _Contenido}, Metadatos) ->
    case maps:find(Clave, Metadatos) of
        error -> true;
        {ok, {VersionActual, _Estado}} -> VersionNueva >= VersionActual
    end.
