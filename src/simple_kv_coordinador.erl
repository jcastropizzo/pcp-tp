-module(simple_kv_coordinador).
-export([init/2]).

%% El coordinador solo retiene version y vencimiento de las claves residentes,
%% y metadatos de resolucion. Los valores circulan en mensajes, no en su estado.
init(Pids, Alfa) ->
    Monitores = [erlang:monitor(process, P) || P <- Pids],
    loop(Pids, Alfa, #{}, #{}, Monitores).

loop(Pids, Alfa, Indice, Meta, Monitores) ->
    receive
        {escritura, Origen, Cliente, Ref, put, Key, Val, TTL}
          when is_integer(TTL), TTL >= 0; TTL =:= infinity ->
            Version = simple_kv_replicacion:nueva_version(),
            Entry = {Version, {value, Val, simple_kv_ttl:expira(TTL)}},
            {Accion, NuevoIndice, NuevaMeta} = decidir(put, Alfa, Key, Entry, Indice, Meta),
            enviar(Pids, {ordenada, Origen, Cliente, Ref, Key, Entry, Accion, put}),
            loop(Pids, Alfa, NuevoIndice, NuevaMeta, Monitores);
        {escritura, Origen, Cliente, Ref, delete, Key} ->
            Version = simple_kv_replicacion:nueva_version(),
            Entry = {Version, borrado},
            {Accion, NuevoIndice, NuevaMeta} = decidir(delete, Alfa, Key, Entry, Indice, Meta),
            enviar(Pids, {ordenada, Origen, Cliente, Ref, Key, Entry, Accion, delete}),
            loop(Pids, Alfa, NuevoIndice, NuevaMeta, Monitores);
        {propuesta_oferta, Key, {VersionOferta, {value, _, VenceOferta}} = Entry}
          when is_integer(VersionOferta),
               (is_integer(VenceOferta) orelse VenceOferta =:= infinity) ->
            {Accion, NuevoIndice, NuevaMeta} = decidir(oferta, Alfa, Key, Entry, Indice, Meta),
            enviar(Pids, {ordenada, ninguno, ninguno, ninguno, Key, Entry, Accion, oferta}),
            loop(Pids, Alfa, NuevoIndice, NuevaMeta, Monitores);
        {propuesta_replica, Origen, Key, Entry} ->
            case tipo_entrada(Entry) of
                invalida -> loop(Pids, Alfa, Indice, Meta, Monitores);
                Tipo ->
                    {Accion, NuevoIndice, NuevaMeta} = decidir(Tipo, Alfa, Key, Entry, Indice, Meta),
                    enviar(Pids, {ordenada, Origen, ninguno, ninguno, Key, Entry, Accion, Tipo}),
                    loop(Pids, Alfa, NuevoIndice, NuevaMeta, Monitores)
            end;
        {barrera_consulta, Replica, Solicitante, Ref, Key} ->
            Replica ! {consulta_ordenada, Solicitante, Ref, Key},
            loop(Pids, Alfa, Indice, Meta, Monitores);
        {barrera_get, Replica, Cliente, Ref, Key} ->
            Replica ! {get_ordenado, Cliente, Ref, Key},
            loop(Pids, Alfa, Indice, Meta, Monitores);
        {'DOWN', Monitor, process, _Pid, _Motivo} ->
            Restantes = lists:delete(Monitor, Monitores),
            case Restantes of
                [] -> ok;
                _ -> loop(Pids, Alfa, Indice, Meta, Restantes)
            end;
        _ -> loop(Pids, Alfa, Indice, Meta, Monitores)
    end.

enviar(Pids, Mensaje) -> lists:foreach(fun(P)-> P ! Mensaje end, Pids).

tipo_entrada({V, borrado}) when is_integer(V) -> delete;
tipo_entrada({V, {value, _, T}}) when is_integer(V), (is_integer(T) orelse T =:= infinity) -> put;
tipo_entrada(_) -> invalida.

%% La politica existente opera sobre marcadores sin contenido; de esa manera
%% el reloj y la eleccion de victima se evaluan una sola vez, aqui.
decidir(Tipo, Alfa, Key, Entry, Indice, Meta) ->
    Falso = maps:map(fun(_, {V, Vence}) -> {V, {value, sin_valor, Vence}} end, Indice),
    FalsaEntry = case Entry of
        {V, {value, _, Vence}} -> {V, {value, sin_valor, Vence}};
        {V, borrado} -> {V, borrado}
    end,
    Nuevo = simple_kv_almacen:es_mensaje_nuevo(Key, FalsaEntry, Meta),
    case Nuevo of
        false -> {ignorar, Indice, Meta};
        true ->
            {NuevoMapa, NuevaMeta} = case Tipo of
                put -> simple_kv_capacidad:guardar([], Alfa, Key, FalsaEntry, Falso, Meta);
                oferta -> simple_kv_capacidad:aceptar_oferta(Key, FalsaEntry, Alfa, Falso, Meta);
                delete -> {simple_kv_almacen:aplicar_actualizacion(Key, FalsaEntry, Falso, Meta),
                           simple_kv_almacen:registrar_metadata(Key, FalsaEntry, Meta)}
            end,
            NuevoIndice = maps:map(fun(_, {V1, {value, _, T}}) -> {V1, T} end, NuevoMapa),
            Quitadas = [K || K <- maps:keys(Falso), not maps:is_key(K, NuevoMapa), K =/= Key],
            Accion = case {Tipo, maps:find(Key, NuevoMapa), maps:find(Key, NuevaMeta)} of
                {delete, _, _} -> borrar;
                {_, {ok, {V2, _}}, {ok, {V2, valor}}} -> {guardar, Quitadas};
                {_, _, {ok, {V3, desalojado}}} -> {rechazar, V3};
                _ -> ignorar
            end,
            {Accion, NuevoIndice, NuevaMeta}
    end.
