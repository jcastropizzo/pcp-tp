-module(simple_kv_almacen).
-export([buscar_local/3, registrar_metadata/3, aplicar_actualizacion/4, es_mensaje_nuevo/3, actualizar_estado_por_delete_replicado/4, actualizar_estado_por_put_replicado/4]).

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

-spec actualizar_estado_por_delete_replicado(term(), {integer(), borrado}, map(), map()) ->
    {map(), map()}.
actualizar_estado_por_delete_replicado(Key, {_, borrado} = Entry, Map, Metadatos) ->
    {aplicar_actualizacion(Key, Entry, Map, Metadatos),
     registrar_metadata(Key, Entry, Metadatos)}.

-spec actualizar_estado_por_put_replicado(
    term(), {integer(), {value, term(), integer() | infinity}}, map(), map()
) -> {map(), map()}.
actualizar_estado_por_put_replicado(Key, {_, {value, _, _}} = Entry, Map, Metadatos) ->
    case es_mensaje_nuevo(Key, Entry, Metadatos) of
        true ->
            %% Conservamos version y vencimiento recibidos.
            %% Aplicar primero permite distinguir una insercion
            %% de una sobrescritura o un duplicado sin cambios.
            MapActualizado = aplicar_actualizacion(
                Key, Entry, Map, Metadatos
            ),
            MetadatosActualizados = registrar_metadata(
                Key, Entry, Metadatos
            ),
            case simple_kv_capacidad:estado_capacidad(MapActualizado) of
                {excedida, _} ->
                    %% El candidato incluye la entrada recibida:
                    %% puede ser mas vieja que las conservadas.
                    %% PENDIENTE: ofrecer a pares antes de desalojar.
                    case simple_kv_capacidad:candidato_a_desalojar(MapActualizado) of
                        ninguno ->
                            erlang:error(capacidad_llena_sin_candidato);
                        {KeyDesalojada, _} ->
                            simple_kv_capacidad:desalojar(
                                KeyDesalojada,
                                MapActualizado,
                                MetadatosActualizados
                            )
                    end;
                _ ->
                    {MapActualizado, MetadatosActualizados}
            end;
        false ->
            {Map, Metadatos}
    end.

%% Devuelve el mapa de valores resultante; NO modifica los metadatos.
%% Nueva es la entrada completa recibida: {VersionNueva, Contenido}.
aplicar_actualizacion(Key, {VersionNueva, Contenido} = Nueva, Map, Metadatos) ->
    %% Consultamos la version conocida aunque el valor ya no este en Map.
    case maps:find(Key, Metadatos) of
        {ok, {VersionActual, Estado}} when VersionActual == VersionNueva ->
            %% Misma version: recuperamos el valor solo si estaba desalojado.
            %% En los demas casos conservamos el mapa sin cambios.
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
                %% Borrado explicito: quitamos el valor si estaba almacenado.
                %% Registrar la marca de borrado corresponde a otra funcion.
                borrado -> maps:remove(Key, Map);
                %% Escritura: guardamos o reemplazamos la entrada completa.
                %% El vencimiento se comprueba al leer, no en esta funcion.
                {value, _, _} -> maps:put(Key, Nueva, Map)
            end
    end.

%% Compara versiones; una version igual tambien se considera aceptable.
%% No modifica el estado ni decide si hace falta almacenar el valor.
-spec es_mensaje_nuevo(
    term(),
    {integer(), term()},
    #{term() => {integer(), valor | borrado | desalojado}}
) -> boolean().
es_mensaje_nuevo(Key, {VersionNueva, _Contenido}, Metadatos) ->
    case maps:find(Key, Metadatos) of
        % probablemente un put
        error -> true;
        % put o delete
        {ok, {VersionActual, _}} -> VersionNueva >= VersionActual
    end.
