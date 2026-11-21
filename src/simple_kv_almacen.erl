-module(simple_kv_almacen).
-export([buscar_local/3, registrar_metadatos/4, aplicar_actualizacion/4, version_no_obsoleta/3]).

buscar_local(Clave, Valores, Metadatos) ->
    case maps:find(Clave, Metadatos) of
        {ok, {Version, borrado, _}} ->
            {ok, {Version, borrado}};
        {ok, {Version, desalojado, _}} ->
            {ok, {Version, desalojado}};
        {ok, {_Version, valor, _}} ->
            maps:find(Clave, Valores);
        error ->
            error
    end.

registrar_metadatos(Clave, Reserva, {Version, Contenido}, Metadatos) ->
    Estado =
        case Contenido of
            borrado -> borrado;
            {valor, _, _} -> valor
        end,
    case maps:find(Clave, Metadatos) of
        {ok, {Version, desalojado, _}} when Estado =:= valor ->
            maps:put(Clave, {Version, valor, Reserva}, Metadatos);
        {ok, {Actual, _, _}} when Actual >= Version ->
            Metadatos;
        _ ->
            maps:put(Clave, {Version, Estado, Reserva}, Metadatos)
    end.

%% Una marca conserva la versión aunque el valor haya salido del mapa.
aplicar_actualizacion(Clave, {VersionNueva, Contenido} = Nueva, Valores, Metadatos) ->
    case maps:find(Clave, Metadatos) of
        {ok, {VersionActual, Estado, _}} when VersionActual == VersionNueva ->
            %% Una copia de igual versión puede completar un desalojo previo.
            case {Estado, Contenido} of
                {desalojado, {valor, _, _}} ->
                    maps:put(Clave, Nueva, Valores);
                _ ->
                    Valores
            end;
        {ok, {VersionActual, _, _}} when VersionActual > VersionNueva ->
            Valores;
        _ ->
            case Contenido of
                borrado -> maps:remove(Clave, Valores);
                {valor, _, _} -> maps:put(Clave, Nueva, Valores)
            end
    end.

%% Una versión igual permite recuperar una copia desalojada.
-spec version_no_obsoleta(
    term(),
    {integer(), term()},
    #{term() => {integer(), valor | borrado | desalojado, reference()}}
) -> boolean().
version_no_obsoleta(Clave, {VersionNueva, _Contenido}, Metadatos) ->
    case maps:find(Clave, Metadatos) of
        error -> true;
        {ok, {VersionActual, _Estado, _}} -> VersionNueva >= VersionActual
    end.
