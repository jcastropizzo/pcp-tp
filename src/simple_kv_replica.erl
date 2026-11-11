-module(simple_kv_replica).
-export([init/0]).

%% Estado de la réplica en los argumentos de loop/6.
%%   Pares      : pids de las otras réplicas
%%   Alfa       : capacidad máxima de valores (§4.7)
%%   Valores        : Clave => {Version, {valor, Valor, Vence}}      (solo valores)
%%   Metadatos  : Clave => {Version, valor | borrado | desalojado}
%%   Recientes  : Clave => versión de la escritura protegida (§4.7)
%%   Pendientes : RefConsulta => {Cliente, RefCliente, Clave, Faltan, Mejor}  (lecturas en curso, §4.8)

init() ->
    receive
        {configurar, Pares, Alfa} -> loop(Pares, Alfa, #{}, #{}, #{}, #{})
    end.

loop(Pares, Alfa, Valores, Metadatos, Recientes, Pendientes) ->
    receive
        %% La respuesta local permite que los pares se consulten entre sí sin bloquearse.
        {consultar, Solicitante, RefConsulta, Clave} ->
            Solicitante !
                {respuesta_consulta, RefConsulta, self(),
                 simple_kv_almacen:buscar_local(Clave, Valores, Metadatos)},
            loop(Pares, Alfa, Valores, Metadatos, Recientes, Pendientes);

        stop ->
            ok;

        {put, Cliente, RefCliente, Clave, Valor, TTL} ->
            Entrada = {simple_kv_replicacion:nueva_version(),
                     {valor, Valor, simple_kv_ttl:calcular_vencimiento(TTL)}},
            {NuevosValores, NuevosMetadatos, NuevosRecientes} =
                simple_kv_capacidad:guardar(Pares, Alfa, Clave, Entrada, Valores, {Metadatos, Recientes}),
            Cliente ! {RefCliente, ok},
            simple_kv_replicacion:replicar(Pares, Clave, Entrada),
            loop(Pares, Alfa, NuevosValores, NuevosMetadatos, NuevosRecientes, Pendientes);

        {delete, Cliente, RefCliente, Clave} ->
            Entrada = {simple_kv_replicacion:nueva_version(), borrado},
            NuevosMetadatos = simple_kv_almacen:registrar_metadatos(Clave, Entrada, Metadatos),
            NuevosValores = maps:remove(Clave, Valores),
            Cliente ! {RefCliente, ok},
            simple_kv_replicacion:replicar(Pares, Clave, Entrada),
            loop(Pares, Alfa, NuevosValores, NuevosMetadatos, Recientes, Pendientes);

        {get, Cliente, RefCliente, Clave} ->
            Local = simple_kv_almacen:buscar_local(Clave, Valores, Metadatos),
            case Local of
                {ok, {_Version, {valor, _Valor, _Vence}}} ->
                    responder_lectura(Cliente, RefCliente, Local),
                    loop(Pares, Alfa, Valores, Metadatos, Recientes, Pendientes);
                {ok, {_Version, borrado}} ->
                    responder_lectura(Cliente, RefCliente, Local),
                    loop(Pares, Alfa, Valores, Metadatos, Recientes, Pendientes);
                _ when Pares =:= [] ->
                    responder_lectura(Cliente, RefCliente, Local),
                    loop(Pares, Alfa, Valores, Metadatos, Recientes, Pendientes);
                _ ->
                    NuevosPendientes =
                        consultar_pares(Pares, Cliente, RefCliente, Clave, Local, Pendientes),
                    loop(Pares, Alfa, Valores, Metadatos, Recientes, NuevosPendientes)
            end;

        {replicar, Clave, {_Version, borrado} = Entrada} ->
            NuevosValores = simple_kv_almacen:aplicar_actualizacion(Clave, Entrada, Valores, Metadatos),
            NuevosMetadatos = simple_kv_almacen:registrar_metadatos(Clave, Entrada, Metadatos),
            loop(Pares, Alfa, NuevosValores, NuevosMetadatos, Recientes, Pendientes);
        {replicar, Clave, {_Version, {valor, _, _}} = Entrada} ->
            {NuevosValores, NuevosMetadatos, NuevosRecientes} =
                simple_kv_capacidad:guardar(Pares, Alfa, Clave, Entrada, Valores, {Metadatos, Recientes}),
            loop(Pares, Alfa, NuevosValores, NuevosMetadatos, NuevosRecientes, Pendientes);

        {ofrecer, Clave, Entrada} ->
            {NuevosValores, NuevosMetadatos, NuevosRecientes} =
                simple_kv_capacidad:aceptar_oferta(Clave, Entrada, Alfa, Valores, Metadatos, Recientes),
            loop(Pares, Alfa, NuevosValores, NuevosMetadatos, NuevosRecientes, Pendientes);

        {respuesta_consulta, RefConsulta, Par, Resultado} ->
            {NuevosPendientes, Respuesta} =
                procesar_respuesta_consulta(RefConsulta, Par, Resultado, Valores, Metadatos, Pendientes),
            case Respuesta of
                sin_respuesta -> ok;
                {Cliente, RefCliente, Final} -> responder_lectura(Cliente, RefCliente, Final)
            end,
            loop(Pares, Alfa, Valores, Metadatos, Recientes, NuevosPendientes);

        _ ->
            loop(Pares, Alfa, Valores, Metadatos, Recientes, Pendientes)
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
