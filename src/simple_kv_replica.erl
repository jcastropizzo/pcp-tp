-module(simple_kv_replica).
-export([init/0]).

-record(replica, {
    pares, alfa, cupos,
    valores = #{}, metadatos = #{}, recientes = #{},
    pendientes = #{}, cierres = #{}
}).

init() ->
    receive
        {configurar, Pares, Alfa, Cupos} ->
            loop(#replica{pares = Pares, alfa = Alfa, cupos = Cupos})
    end.

loop(#replica{pares = Pares, alfa = Alfa, cupos = Cupos, valores = Valores,
              metadatos = Meta, recientes = Recientes, pendientes = Pendientes,
              cierres = Cierres} = Estado) ->
    receive
        {pedir_cupo, Cliente, Ref, Clave} ->
            Cupos ! {pedir_cupo, Cliente, Ref, Clave},
            loop(Estado);

        {cambiar, Cliente, Ref, Clave, Reserva, Id, Cambio} ->
            Entrada = {simple_kv_replicacion:nueva_version(), contenido(Cambio)},
            Nuevo = aplicar(Clave, Reserva, Id, Entrada, Estado),
            Cliente ! {Ref, ok},
            simple_kv_replicacion:replicar(Pares, Clave, Reserva, Id, Entrada),
            loop(Nuevo);

        {replicar, Clave, Reserva, Id, Entrada} ->
            loop(aplicar(Clave, Reserva, Id, Entrada, Estado));

        {ofrecer, Clave, Reserva, Id, Ref, Entrada} ->
            {V, M, R} = simple_kv_capacidad:aceptar_oferta(
                Alfa, Clave, Reserva, Entrada, Valores, {Meta, Recientes}),
            {Altas, Bajas} = cambios_de_residencia(Valores, V),
            Cupos ! {oferta_resuelta, Id, Ref, self(), Altas, Bajas},
            loop(Estado#replica{valores = V, metadatos = M, recientes = R});

        {get, Cliente, Ref, Clave} ->
            loop(leer(Cliente, Ref, Clave, Estado));

        %% Las consultas de pares siguen atendidas durante el olvido.
        {consultar, Solicitante, RefConsulta, Clave} ->
            Solicitante !
                {respuesta_consulta, RefConsulta, self(),
                 simple_kv_almacen:buscar_local(Clave, Valores, Meta)},
            loop(Estado);

        {respuesta_consulta, RefConsulta, Par, Resultado} ->
            {Nuevos, Respuesta} =
                procesar_respuesta_consulta(RefConsulta, Par, Resultado, Valores, Meta, Pendientes),
            case Respuesta of
                sin_respuesta -> ok;
                {Cliente, Ref, Final} ->
                    responder_lectura(Cliente, Ref, Final),
                    {_, _, Clave, _, _} = maps:get(RefConsulta, Pendientes),
                    avisar_si_drenada(Clave, Cierres, Nuevos, Cupos)
            end,
            loop(Estado#replica{pendientes = Nuevos});

        {preparar_olvido, Clave, Reserva} ->
            Nuevos = Cierres#{Clave => Reserva},
            avisar_si_drenada(Clave, Nuevos, Pendientes, Cupos),
            loop(Estado#replica{cierres = Nuevos});

        {olvidar, Clave, Reserva} when map_get(Clave, Cierres) =:= Reserva ->
            Reducidos = case maps:find(Clave, Meta) of
                {ok, {_, _, Reserva}} -> maps:remove(Clave, Meta);
                _ -> Meta
            end,
            Cupos ! {olvidada, Clave, Reserva, self()},
            loop(Estado#replica{metadatos = Reducidos, cierres = maps:remove(Clave, Cierres)});

        stop ->
            simple_kv_cupos:detener_replica(Cupos);

        _ ->
            loop(Estado)
    end.

contenido(borrado) -> borrado;
contenido({put, Valor, TTL}) -> {valor, Valor, simple_kv_ttl:calcular_vencimiento(TTL)}.

aplicar(Clave, Reserva, Id, Entrada,
        #replica{pares = Pares, alfa = Alfa, cupos = Cupos, valores = Valores,
                 metadatos = Meta, recientes = Recientes} = Estado) ->
    {{V, M, R}, Oferta} = case Entrada of
        {_, borrado} ->
            Borrados = simple_kv_almacen:aplicar_actualizacion(Clave, Entrada, Valores, Meta),
            Marcados = simple_kv_almacen:registrar_metadatos(Clave, Reserva, Entrada, Meta),
            {{Borrados, Marcados, Recientes}, ninguna};
        {_, {valor, _, _}} ->
            simple_kv_capacidad:guardar(Alfa, Clave, Reserva, Entrada, Valores, {Meta, Recientes})
    end,
    Ofertas = simple_kv_replicacion:ofrecer(Pares, Id, Oferta),
    {Altas, Bajas} = cambios_de_residencia(Valores, V),
    Cupos ! {aplicado, Id, self(), Altas, Bajas, Ofertas},
    Estado#replica{valores = V, metadatos = M, recientes = R}.

cambios_de_residencia(Antes, Despues) ->
    {[K || K <- maps:keys(Despues), not is_map_key(K, Antes)],
     [K || K <- maps:keys(Antes), not is_map_key(K, Despues)]}.

leer(Cliente, Ref, Clave, #replica{cierres = Cierres} = Estado)
        when is_map_key(Clave, Cierres) ->
    %% El coordinador ya confirmó que no hay copias ni cambios de esta clave.
    responder_lectura(Cliente, Ref, error),
    Estado;
leer(Cliente, Ref, Clave,
     #replica{pares = Pares, valores = Valores, metadatos = Meta,
              pendientes = Pendientes} = Estado) ->
    Local = simple_kv_almacen:buscar_local(Clave, Valores, Meta),
    case Local of
        {ok, {_, {valor, _, _}}} -> responder_lectura(Cliente, Ref, Local), Estado;
        {ok, {_, borrado}} -> responder_lectura(Cliente, Ref, Local), Estado;
        _ when Pares =:= [] -> responder_lectura(Cliente, Ref, Local), Estado;
        _ ->
            Nuevos = consultar_pares(Pares, Cliente, Ref, Clave, Local, Pendientes),
            Estado#replica{pendientes = Nuevos}
    end.

avisar_si_drenada(Clave, Cierres, Pendientes, Cupos) ->
    case maps:find(Clave, Cierres) of
        {ok, Reserva} ->
            case lists:any(fun({_, _, K, _, _}) -> K =:= Clave end, maps:values(Pendientes)) of
                true -> ok;
                false -> Cupos ! {lecturas_drenadas, Clave, Reserva, self()}
            end;
        error -> ok
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
