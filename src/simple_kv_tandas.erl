-module(simple_kv_tandas).
-export([nueva/1, estado/1, admitir_cambio/1, recibir/4, avanzar/5]).

-record(tanda, {
    numero,
    fase = abierta,
    operaciones = 0,
    fin_actualizaciones = #{},
    fin_ofertas = #{},
    residentes = #{},
    compactadas = #{}
}).

nueva(Numero) -> #tanda{numero = Numero}.

estado(#tanda{numero = Numero, fase = Fase}) -> {Numero, Fase}.

admitir_cambio(#tanda{operaciones = N} = Tanda) -> Tanda#tanda{operaciones = N + 1}.

recibir(Par, actualizaciones, ok, Tanda) ->
    Tanda#tanda{fin_actualizaciones = (Tanda#tanda.fin_actualizaciones)#{Par => true}};
recibir(Par, ofertas, ok, Tanda) ->
    Tanda#tanda{fin_ofertas = (Tanda#tanda.fin_ofertas)#{Par => true}};
recibir(Par, residentes, Claves, Tanda) when is_list(Claves) ->
    Tanda#tanda{residentes = (Tanda#tanda.residentes)#{Par => Claves}};
recibir(Par, compactada, ok, Tanda) ->
    Tanda#tanda{compactadas = (Tanda#tanda.compactadas)#{Par => true}};
recibir(_Par, _Evento, _Datos, Tanda) -> Tanda.

%% Pares excluye a self(). Los mapas de avisos guardan un registro por par.
%% Cada transición puede avanzar sin otro mensaje (p. ej. con una sola réplica).
avanzar(#tanda{fase = abierta, operaciones = N, fin_actualizaciones = Avisos} = Tanda,
        Pares, Alfa, Valores, Estado) when N >= Alfa; map_size(Avisos) > 0 ->
    avisar(Pares, Tanda, actualizaciones, ok),
    avanzar(Tanda#tanda{fase = cerrando}, Pares, Alfa, Valores, Estado);
avanzar(#tanda{fase = cerrando, fin_actualizaciones = Avisos} = Tanda,
        Pares, Alfa, Valores, Estado) when map_size(Avisos) =:= length(Pares) ->
    %% Procesar la última actualización pudo generar una última oferta.
    avisar(Pares, Tanda, ofertas, ok),
    avanzar(Tanda#tanda{fase = ofertas}, Pares, Alfa, Valores, Estado);
avanzar(#tanda{fase = ofertas, fin_ofertas = Avisos} = Tanda,
        Pares, Alfa, Valores, {_, Pendientes} = Estado)
        when map_size(Avisos) =:= length(Pares), map_size(Pendientes) =:= 0 ->
    avisar(Pares, Tanda, residentes, maps:keys(Valores)),
    avanzar(Tanda#tanda{fase = residentes}, Pares, Alfa, Valores, Estado);
avanzar(#tanda{fase = residentes, residentes = Remotos} = Tanda,
        Pares, Alfa, Valores, {Metadatos, Pendientes})
        when map_size(Remotos) =:= length(Pares) ->
    Claves = maps:keys(Valores) ++ lists:append(maps:values(Remotos)),
    Reducidos = maps:with(Claves, Metadatos),
    avisar(Pares, Tanda, compactada, ok),
    avanzar(Tanda#tanda{fase = compactada, residentes = #{}},
            Pares, Alfa, Valores, {Reducidos, Pendientes});
avanzar(#tanda{fase = compactada, numero = Numero, compactadas = Avisos},
        Pares, _Alfa, _Valores, {Metadatos, _Pendientes})
        when map_size(Avisos) =:= length(Pares) ->
    {nueva(Numero + 1), Metadatos};
avanzar(Tanda, _Pares, _Alfa, _Valores, {Metadatos, _Pendientes}) ->
    {Tanda, Metadatos}.

avisar(Pares, #tanda{numero = Numero}, Evento, Datos) ->
    Mensaje = {tanda, Numero, self(), Evento, Datos},
    lists:foreach(fun(Par) -> Par ! Mensaje end, Pares).
