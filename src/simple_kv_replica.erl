-module(simple_kv_replica).
-export([init/0]).

-ifdef(TEST).
-export([init_sin_tandas/0]).
%% Los pares simulados de las pruebas unitarias no participan en barreras.
init_sin_tandas() -> configurar(sin_tandas).
-endif.

-define(MENSAJE(M, Tipo, Aridad),
        (is_tuple(M) andalso tuple_size(M) =:= Aridad andalso element(1, M) =:= Tipo)).
-define(LECTURA_LOCAL(K, Pares, Meta),
        (Pares =:= [] orelse (is_map_key(K, Meta) andalso element(2, map_get(K, Meta)) =/= desalojado))).

%% Estado de la réplica en los argumentos de loop/7.
%%   Pares      : pids de las otras réplicas
%%   Alfa       : capacidad máxima de valores (§4.7)
%%   Valores        : Clave => {Version, {valor, Valor, Vence}}      (solo valores)
%%   Metadatos  : Clave => {Version, valor | borrado | desalojado}
%%   Recientes  : Clave => versión de la escritura protegida (§4.7)
%%   Tanda      : número, fase, cupo usado y avisos recibidos
%%   Pendientes : RefConsulta => {Cliente, RefCliente, Clave, Faltan, Mejor}  (lecturas en curso, §4.8)

init() -> configurar(simple_kv_tandas:nueva(0)).

configurar(Tanda) ->
    receive
        {configurar, Pares, Alfa} -> loop(Pares, Alfa, #{}, #{}, #{}, #{}, Tanda)
    end.

continuar(Pares, Alfa, Valores, Metadatos, Recientes, Pendientes, Tanda) ->
    {Siguiente, Reducidos} =
        simple_kv_tandas:avanzar(Tanda, Pares, Alfa, Valores, {Metadatos, Pendientes}),
    loop(Pares, Alfa, Valores, Reducidos, Recientes, Pendientes, Siguiente).

loop(Pares, Alfa, Valores, Metadatos, Recientes, Pendientes, Tanda) ->
    {Numero, Fase} = simple_kv_tandas:estado(Tanda),
    receive
        %% La respuesta local permite que los pares se consulten entre sí sin bloquearse.
        {consultar, Solicitante, RefConsulta, Clave} ->
            Solicitante !
                {respuesta_consulta, RefConsulta, self(),
                 simple_kv_almacen:buscar_local(Clave, Valores, Metadatos)},
            continuar(Pares, Alfa, Valores, Metadatos, Recientes, Pendientes, Tanda);

        stop ->
            ok;

        {put, Cliente, RefCliente, Clave, Valor, TTL} when Fase =:= abierta ->
            Entrada = {simple_kv_replicacion:nueva_version(),
                     {valor, Valor, simple_kv_ttl:calcular_vencimiento(TTL)}},
            {NuevosValores, NuevosMetadatos, NuevosRecientes} =
                simple_kv_capacidad:guardar(Pares, Alfa, Clave, Entrada, Valores, {Metadatos, Recientes}),
            Cliente ! {RefCliente, ok},
            simple_kv_replicacion:replicar(Pares, Clave, Entrada),
            ConCambio = simple_kv_tandas:admitir_cambio(Tanda),
            continuar(Pares, Alfa, NuevosValores, NuevosMetadatos, NuevosRecientes, Pendientes, ConCambio);

        {delete, Cliente, RefCliente, Clave} when Fase =:= abierta ->
            Entrada = {simple_kv_replicacion:nueva_version(), borrado},
            NuevosMetadatos = simple_kv_almacen:registrar_metadatos(Clave, Entrada, Metadatos),
            NuevosValores = maps:remove(Clave, Valores),
            Cliente ! {RefCliente, ok},
            simple_kv_replicacion:replicar(Pares, Clave, Entrada),
            ConCambio = simple_kv_tandas:admitir_cambio(Tanda),
            continuar(Pares, Alfa, NuevosValores, NuevosMetadatos, Recientes, Pendientes, ConCambio);

        %% Durante el cierre se siguen atendiendo las lecturas locales, pero
        %% se espera para iniciar consultas nuevas a los pares.
        {get, Cliente, RefCliente, Clave}
                when Fase =:= abierta; ?LECTURA_LOCAL(Clave, Pares, Metadatos) ->
            Local = simple_kv_almacen:buscar_local(Clave, Valores, Metadatos),
            case Local of
                {ok, {_Version, {valor, _Valor, _Vence}}} ->
                    responder_lectura(Cliente, RefCliente, Local),
                    continuar(Pares, Alfa, Valores, Metadatos, Recientes, Pendientes, Tanda);
                {ok, {_Version, borrado}} ->
                    responder_lectura(Cliente, RefCliente, Local),
                    continuar(Pares, Alfa, Valores, Metadatos, Recientes, Pendientes, Tanda);
                _ when Pares =:= [] ->
                    responder_lectura(Cliente, RefCliente, Local),
                    continuar(Pares, Alfa, Valores, Metadatos, Recientes, Pendientes, Tanda);
                _ ->
                    NuevosPendientes =
                        consultar_pares(Pares, Cliente, RefCliente, Clave, Local, Pendientes),
                    continuar(Pares, Alfa, Valores, Metadatos, Recientes, NuevosPendientes, Tanda)
            end;

        {replicar, Clave, {_Version, borrado} = Entrada} when Fase =/= compactada ->
            NuevosValores = simple_kv_almacen:aplicar_actualizacion(Clave, Entrada, Valores, Metadatos),
            NuevosMetadatos = simple_kv_almacen:registrar_metadatos(Clave, Entrada, Metadatos),
            continuar(Pares, Alfa, NuevosValores, NuevosMetadatos, Recientes, Pendientes, Tanda);
        {replicar, Clave, {_Version, {valor, _, _}} = Entrada} when Fase =/= compactada ->
            {NuevosValores, NuevosMetadatos, NuevosRecientes} =
                simple_kv_capacidad:guardar(Pares, Alfa, Clave, Entrada, Valores, {Metadatos, Recientes}),
            continuar(Pares, Alfa, NuevosValores, NuevosMetadatos, NuevosRecientes, Pendientes, Tanda);

        {ofrecer, Clave, Entrada} when Fase =/= compactada ->
            {NuevosValores, NuevosMetadatos, NuevosRecientes} =
                simple_kv_capacidad:aceptar_oferta(Clave, Entrada, Alfa, Valores, Metadatos, Recientes),
            continuar(Pares, Alfa, NuevosValores, NuevosMetadatos, NuevosRecientes, Pendientes, Tanda);

        {respuesta_consulta, RefConsulta, Par, Resultado} ->
            {NuevosPendientes, Respuesta} =
                procesar_respuesta_consulta(RefConsulta, Par, Resultado, Valores, Metadatos, Pendientes),
            case Respuesta of
                sin_respuesta -> ok;
                {Cliente, RefCliente, Final} -> responder_lectura(Cliente, RefCliente, Final)
            end,
            continuar(Pares, Alfa, Valores, Metadatos, Recientes, NuevosPendientes, Tanda);

        {tanda, Numero, Par, Evento, Datos} ->
            Actualizada = case lists:member(Par, Pares) of
                true -> simple_kv_tandas:recibir(Par, Evento, Datos, Tanda);
                false -> Tanda
            end,
            continuar(Pares, Alfa, Valores, Metadatos, Recientes, Pendientes, Actualizada);

        {tanda, Anterior, _Par, _Evento, _Datos} when Anterior < Numero ->
            loop(Pares, Alfa, Valores, Metadatos, Recientes, Pendientes, Tanda);

        %% Selective receive deja en el buzón cambios aún no admitidos y
        %% tráfico de un par que ya abrió la tanda siguiente. Las consultas
        %% y los avisos de cierre siempre pueden avanzar por delante de ellos.
        Desconocido when not (
                    ?MENSAJE(Desconocido, put, 6) orelse ?MENSAJE(Desconocido, delete, 4) orelse
                    ?MENSAJE(Desconocido, get, 4) orelse ?MENSAJE(Desconocido, tanda, 5) orelse
                    (Fase =:= compactada andalso
                     (?MENSAJE(Desconocido, replicar, 3) orelse ?MENSAJE(Desconocido, ofrecer, 3)))) ->
            continuar(Pares, Alfa, Valores, Metadatos, Recientes, Pendientes, Tanda)
    end.

consultar_pares(Pares, Cliente, RefCliente, Clave, Local, Pendientes) ->
    Yo = self(),
    RefConsulta = make_ref(),
    lists:foreach(
        fun(Par) -> Par ! {consultar, Yo, RefConsulta, Clave} end,
        Pares
    ),
    maps:put(RefConsulta, {Cliente, RefCliente, Clave, Pares, Local}, Pendientes).

procesar_respuesta_consulta(RefConsulta, Par, Resultado, Valores, Metadatos, Pendientes) ->
    case maps:find(RefConsulta, Pendientes) of
        error ->
            {Pendientes, sin_respuesta};
        {ok, {Cliente, RefCliente, Clave, Faltan, Mejor}} ->
            case lists:delete(Par, Faltan) of
                Faltan ->
                    {Pendientes, sin_respuesta};
                Restantes ->
                    NuevoMejor = simple_kv_replicacion:elegir_mayor(Mejor, Resultado),
                    case Restantes of
                        [] ->
                            %% El estado local pudo cambiar mientras llegaban las respuestas.
                            Local = simple_kv_almacen:buscar_local(Clave, Valores, Metadatos),
                            Final = simple_kv_replicacion:elegir_mayor(NuevoMejor, Local),
                            {maps:remove(RefConsulta, Pendientes), {Cliente, RefCliente, Final}};
                        [_ | _] ->
                            Actualizado = {Cliente, RefCliente, Clave, Restantes, NuevoMejor},
                            {maps:put(RefConsulta, Actualizado, Pendientes), sin_respuesta}
                    end
            end
    end.

responder_lectura(Cliente, RefCliente, error) ->
    Cliente ! {RefCliente, not_found};
responder_lectura(Cliente, RefCliente, {ok, {_Version, borrado}}) ->
    Cliente ! {RefCliente, not_found};
responder_lectura(Cliente, RefCliente, {ok, {_Version, desalojado}}) ->
    Cliente ! {RefCliente, not_found};
responder_lectura(Cliente, RefCliente, {ok, {_Version, {valor, Valor, Vence}}}) ->
    case simple_kv_ttl:vigente(Vence) of
        true -> Cliente ! {RefCliente, ok, Valor};
        false -> Cliente ! {RefCliente, not_found}
    end.
