-module(simple_kv_capacidad).
-export([guardar/6, aceptar_oferta/5, candidato_a_desalojar/1, desalojar/3]).

-type entry() :: {integer(), {value, term(), integer() | infinity}}.
-type valores() :: #{term() => entry()}.
-type metadatos() :: #{term() => {integer(), valor | borrado | desalojado}}.

%% TTL controla visibilidad, no borrado fisico. Las Q=ceil(3*Alfa/4)
%% versiones mas recientes se protegen aun vencidas, sin distinguir origen.
%% Se reserva espacio ANTES de insertar: Map nunca tiene Alfa+1 valores.
-spec guardar([pid()], pos_integer(), term(), entry(), valores(), metadatos()) ->
    {valores(), metadatos()}.
guardar(Peers, Alfa, Key, Entry, Map, Metadatos) ->
    case simple_kv_almacen:es_mensaje_nuevo(Key, Entry, Metadatos) of
        false -> {Map, Metadatos};
        true ->
            case maps:is_key(Key, Map) orelse map_size(Map) < Alfa of
                true -> aplicar(Key, Entry, Map, Metadatos);
                false ->
                    %% Se considera al entrante sin guardarlo en otro mapa.
                    {Descarte, Entrada} = elegir_descarte(Key, Entry, Alfa, Map),
                    case Descarte =:= Key of
                        true -> rechazar(Peers, Key, Entry, Map, Metadatos);
                        false ->
                            ofrecer_si_vigente(Peers, Descarte, Entrada),
                            {Reducido, Meta} = desalojar(Descarte, Map, Metadatos),
                            aplicar(Key, Entry, Reducido, Meta)
                    end
            end
    end.

%% La lista auxiliar contiene SOLO claves/versiones. La proteccion se calcula
%% sobre residentes + entrante, con Q posiciones de la capacidad Alfa.
%% Del resto sale primero un vencido (el de menor version si hay varios);
%% si ninguno vencio, sale la version minima. Puede salir el entrante.
elegir_descarte(Key, {Version, _} = Entry, Alfa, Map) ->
    Orden = lists:sort([{Version, Key} | [{V, K} || {K, {V, _}} <- maps:to_list(Map)]]),
    Q = (3 * Alfa + 3) div 4,
    Elegibles = lists:sublist(Orden, length(Orden) - Q),
    EntradaDe = fun(K) ->
        case K =:= Key of true -> Entry; false -> maps:get(K, Map) end
    end,
    Vencidos = [{K, E} || {_, K} <- Elegibles,
                         E = {_, {value, _, Vence}} <- [EntradaDe(K)],
                         not simple_kv_ttl:vigente(Vence)],
    case Vencidos of
        [Primero | _] -> Primero;
        [] ->
            [{_, K} | _] = Elegibles,
            {K, EntradaDe(K)}
    end.

%% Mapa y metadatos se actualizan juntos para mantener coherencia de version.
aplicar(Key, Entry, Map, Meta) ->
    {simple_kv_almacen:aplicar_actualizacion(Key, Entry, Map, Meta),
     simple_kv_almacen:registrar_metadata(Key, Entry, Meta)}.

%% El vencimiento no fabrica lapidas: solo delete genera 'borrado'.
rechazar(Peers, Key, {Version, _} = Entry, Map, Meta) ->
    ofrecer_si_vigente(Peers, Key, Entry),
    {Map, maps:put(Key, {Version, desalojado}, Meta)}.

%% Un vencido no sirve a los pares; un vigente se ofrece antes del descarte.
ofrecer_si_vigente(Peers, Key, {_, {value, _, Vence}} = Entry) ->
    case simple_kv_ttl:vigente(Vence) of
        true -> simple_kv_replicacion:ofrecer(Peers, Key, Entry);
        false -> ok
    end.

%% Una oferta nunca genera mensajes ni desaloja vigentes. Puede ocupar una
%% vacante, reemplazar su clave o reutilizar SOLO un vencido no protegido.
%% No limpia otros vencidos como efecto lateral ni renueva el TTL recibido.
-spec aceptar_oferta(term(), term(), pos_integer(), valores(), metadatos()) ->
    {valores(), metadatos()}.
aceptar_oferta(Key, {_, {value, _, _}} = Entry, Alfa, Map, Metadatos) ->
    case simple_kv_almacen:es_mensaje_nuevo(Key, Entry, Metadatos) of
        false -> {Map, Metadatos};
        true ->
            case maps:is_key(Key, Map) orelse map_size(Map) < Alfa of
                true -> aplicar(Key, Entry, Map, Metadatos);
                false ->
                    {K, {_, {value, _, Vence}}} = elegir_descarte(Key, Entry, Alfa, Map),
                    case K =/= Key andalso not simple_kv_ttl:vigente(Vence) of
                        true ->
                            {Reducido, Meta} = desalojar(K, Map, Metadatos),
                            aplicar(Key, Entry, Reducido, Meta);
                        false -> rechazar([], Key, Entry, Map, Metadatos)
                    end
            end
    end;
aceptar_oferta(_Key, _Entry, _Alfa, Map, Metadatos) ->
    {Map, Metadatos}.

%% Selector minimo: el fallback cuando no hay vencidos elegibles.
-spec candidato_a_desalojar(valores()) -> ninguno | {term(), entry()}.
candidato_a_desalojar(Valores) when is_map(Valores) ->
    maps:fold(
        fun
            (Key, Entry, ninguno) -> {Key, Entry};
            (Key, {Version, _} = Entry, {_, {Actual, _}}) when Version < Actual ->
                {Key, Entry};
            (_, _, Acc) -> Acc
        end,
        ninguno,
        Valores
    ).

%% Conserva la version desalojada para distinguir ausencia local de delete.
-spec desalojar(term(), valores(), metadatos()) -> {valores(), metadatos()}.
desalojar(Key, Map, Metadatos) ->
    {ok, {Version, _}} = maps:find(Key, Map),
    {maps:remove(Key, Map), maps:put(Key, {Version, desalojado}, Metadatos)}.
