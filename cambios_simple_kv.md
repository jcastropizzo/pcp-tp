# Cambios en `simple_kv`: replicación, resolución de conflictos, tombstones y TTL

Este documento explica qué se cambió respecto del código original y por qué. El código original tenía la API sincrónica con el cliente (`make_ref` + `receive {Ref, ...}`), pero cada réplica era un mapa independiente: no replicaba, borraba con `maps:remove` e ignoraba el TTL.

---

## 1. Resumen de cambios

| Dónde | Antes | Ahora | Para qué |
|---|---|---|---|
| `start_link` | Solo creaba los procesos | Además les manda `{peers, OtrosPids}` | Que cada réplica sepa a quién replicar |
| `init/0` | No existía | Espera `{peers, Peers}` y entra al loop | Estado inicial de la réplica |
| `loop` | `loop(Map)` | `loop(Peers, Map)` | El estado incluye a los pares |
| Contenido del mapa | `Key => Val` | `Key => {Version, Dato}` | Poder comparar escrituras |
| `put` | `maps:put(Key, Val, Map)` | Guarda `{Version, {value, Val, Expira}}` y replica | Versiones + TTL + replicación |
| `delete` | `maps:remove(Key, Map)` | Guarda `{Version, tombstone}` y replica | Que un borrado no se pierda (4.5) |
| Mensaje nuevo | — | `{replica, Key, Entry}` → `aplicar_actualizacion` | Recibir cambios de otras réplicas |
| `get` | Devolvía el valor si existía | Distingue valor, vencido y tombstone | TTL y borrados |
| Auxiliares nuevas | — | `nueva_version`, `replicar`, `aplicar_actualizacion`, `expira`, `vigente` | Lógica de versiones, conflictos y TTL |

---

## 2. Replicación asincrónica (4.2)

### Las réplicas se conocen

```erlang
start_link(N) when is_integer(N), N >= 1 ->
    Pids = lists:map(
        fun(_) -> spawn_link(fun() -> init() end) end,
        lists:seq(1, N)
    ),
    lists:foreach(
        fun(Pid) -> Pid ! {peers, lists:delete(Pid, Pids)} end,
        Pids
    ),
    {ok, Pids}.

init() ->
    receive
        {peers, Peers} -> loop(Peers, #{})
    end.
```

- Primero se crean todos los procesos, y recién después se conocen todos los pids.
- A cada réplica se le manda la lista de **las otras** (`lists:delete(Pid, Pids)` saca su propio pid).
- `init/0` es un estado inicial: la réplica espera esa lista antes de atender pedidos. Si llega un `put` antes, queda en el buzón y se atiende después, porque el `receive` solo toma los mensajes que encajan con el patrón.

### Aplicar, responder, replicar

Cada `put` o `delete` sigue siempre el mismo orden:

```erlang
NewMap = maps:put(Key, Entry, Map),   % 1. aplica localmente
Client ! {Ref, ok},                   % 2. responde ya al cliente
replicar(Peers, Key, Entry),          % 3. avisa a las demás sin esperar
loop(Peers, NewMap);
```

```erlang
replicar(Peers, Key, Entry) ->
    lists:foreach(fun(P) -> P ! {replica, Key, Entry} end, Peers).
```

El envío con `!` es asincrónico: deja el mensaje en el buzón del otro proceso y sigue, sin esperar confirmación. Como no hay ningún `receive` esperando a las otras réplicas, `put` y `delete` devuelven `ok` sin esperar a que las demás apliquen el cambio, que es lo que pide el 4.2.

Es el mismo patrón que `release/1` del semáforo visto en clase (`S ! release`): mandar y seguir. No hacen falta semáforos porque cada réplica atiende **un mensaje por vez** y su `Map` no se comparte con nadie, así que ya hay exclusión mutua. Además, esperar a las otras réplicas sería replicación sincrónica y podría causar deadlock.

### Recibir cambios de otras réplicas

```erlang
{replica, Key, Entry} ->
    loop(Peers, aplicar_actualizacion(Key, Entry, Map));
```

Este mensaje no se responde. Solo se combina lo que llega con lo que ya hay, usando `aplicar_actualizacion` (sección 4).

---

## 3. Versiones

### El problema

Con replicación asincrónica, cada réplica puede recibir los cambios **en un orden distinto** (5.3: no hay garantía de orden entre emisores distintos). Si cada réplica se quedara con *el último que le llegó*, podrían terminar con valores diferentes para siempre:

```
put(P1, color, rojo)          put(P2, color, azul)

P3 recibe: rojo, azul  ->  azul
P4 recibe: azul, rojo  ->  rojo     ¡no convergen!
```

### La solución: cada escritura tiene una versión

```erlang
nueva_version() ->
    erlang:unique_integer([monotonic]).
```

`erlang:unique_integer([monotonic])` devuelve un entero que:

- **nunca se repite** dentro de la VM, así que dos escrituras nunca tienen la misma versión y no hay empates;
- **siempre es mayor** que los generados antes, así que una escritura hecha después tiene una versión mayor.

La versión se genera **una sola vez**, en la réplica que recibe el `put` o el `delete`, y **viaja con la entrada** a las demás. Todas las réplicas comparan exactamente el mismo número.

Esto es válido porque el enunciado garantiza que todo corre en **una única VM BEAM** (sección 7). En un sistema distribuido entre máquinas habría que usar relojes lógicos (por ejemplo, Lamport).

### Forma de las entradas en el mapa

```erlang
Key => {Version, {value, Val, Expira}}   % valor (con su vencimiento)
Key => {Version, tombstone}              % borrado
```

El primer elemento siempre es la versión. Eso permite que `aplicar_actualizacion` compare cualquier par de entradas, sean valores o borrados.

---

## 4. `aplicar_actualizacion`: resolución de conflictos (4.3 y 4.4)

```erlang
aplicar_actualizacion(Key, {VersionNueva, _} = Nueva, Map) ->
    case maps:find(Key, Map) of
        {ok, {VersionActual, _}} when VersionActual >= VersionNueva ->
            Map;
        _ ->
            maps:put(Key, Nueva, Map)
    end.
```

### Cómo funciona

- `{VersionNueva, _} = Nueva` hace dos cosas: extrae la versión de la entrada que llega y nombra la tupla completa como `Nueva`.
- `maps:find(Key, Map)` busca lo que la réplica ya tiene para esa clave.
  - Si ya tiene una entrada **con versión mayor o igual**, se queda con la suya y descarta la que llega.
  - En cualquier otro caso (la que llega es más nueva, o no tenía nada), guarda la nueva.

La política es **last-writer-wins**: gana siempre la escritura con la versión más alta.

### Por qué garantiza la convergencia

Quedarse con el máximo es:

- **conmutativo:** `max(a, b) = max(b, a)`, así que el orden de llegada no importa;
- **asociativo:** con tres o más cambios, el resultado es el mismo sin importar cómo se agrupen;
- **idempotente:** recibir el mismo cambio dos veces no cambia nada.

Entonces, cuando dejan de producirse escrituras y llegan todos los mensajes, todas las réplicas terminan con la entrada de versión máxima para cada clave. Eso es la **convergencia** que pide el 4.3.

### Ejemplo (4.4)

`put(P1, color, rojo)` genera la versión 10 y `put(P2, color, azul)` genera la versión 11.

| Orden de llegada a P3 | Paso 1 | Paso 2 | Resultado |
|---|---|---|---|
| rojo, azul | guarda rojo (10) | 11 > 10 → guarda azul | azul |
| azul, rojo | guarda azul (11) | 11 ≥ 10 → ignora rojo | azul |

En ambos órdenes el resultado es el mismo.

### Por qué el `put` local no usa `aplicar_actualizacion`

En la rama `put` del loop se hace directamente `maps:put`. La versión recién generada siempre es mayor que cualquier otra que esa réplica ya haya visto, así que siempre ganaría.

### Limitación

Si dos escrituras son concurrentes, una se pierde sin aviso. El enunciado solo pide que todas las réplicas elijan la misma, y LWW lo cumple.

---

## 5. Tombstone: borrado en un sistema replicado (4.5)

### El problema de borrar con `maps:remove`

El código original hacía `maps:remove(Key, Map)`. Con varias réplicas, eso permite que un dato borrado reaparezca:

1. `put(P1, color, rojo)`: P1 envía el cambio a P3, pero el mensaje se demora.
2. `delete(P2, color)`: P2 envía el borrado a P3, que llega primero.
3. P3 elimina la clave. Ya no tiene **ninguna información** sobre ella.
4. Llega el `put` demorado. P3 no tiene con qué compararlo, así que lo guarda: **el dato resucitó**.

### La solución: no borrar, dejar una marca

```erlang
{delete, Client, Ref, Key} ->
    Entry = {nueva_version(), tombstone},
    NewMap = maps:put(Key, Entry, Map),
    Client ! {Ref, ok},
    replicar(Peers, Key, Entry),
    loop(Peers, NewMap);
```

Una **tombstone** (lápida) es una entrada que dice "esta clave fue borrada en la versión V". Se guarda y se replica igual que un valor.

El mismo caso ahora:

1. `put(P1, color, rojo)` → versión 10, demorado.
2. `delete(P2, color)` → lápida con versión 20, llega primero a P3.
3. P3 guarda `{20, tombstone}`. La clave **sigue en el mapa**.
4. Llega el `put` con versión 10. `aplicar_actualizacion` ve 20 ≥ 10 y lo descarta.

El dato sigue borrado. Si después alguien hace un `put` nuevo, va a tener una versión mayor que 20 y sí gana. Así se cumple que **un dato borrado solo vuelve a aparecer mediante una nueva escritura**.

La ventaja es que **la regla de borrado es la misma que la de conflictos**: un `delete` es una escritura más, y `aplicar_actualizacion` no necesita casos especiales.

### Costo

Las lápidas no se eliminan nunca, así que ocupan memoria. Es aceptable por el supuesto de que los procesos no fallan. Borrarlas de forma segura requeriría saber que todas las réplicas ya recibieron todos los cambios anteriores.

---

## 6. TTL (4.6)

### Qué se guarda: cuándo vence, no cuánto dura

```erlang
{put, Client, Ref, Key, Val, Time} ->
    Entry = {nueva_version(), {value, Val, expira(Time)}},
    ...
```

```erlang
expira(infinity) -> infinity;
expira(Time) -> erlang:monotonic_time(millisecond) + Time.
```

- Con `infinity`, el valor no vence.
- Con un número, se guarda el **instante absoluto** de vencimiento: ahora + TTL.
- `erlang:monotonic_time(millisecond)` es un reloj en milisegundos que nunca retrocede, a diferencia de la hora del sistema, que se puede ajustar.

Ejemplo: si ahora es 5000 y se hace `put(P1, temp, 42, 50)`, se guarda `{Version, {value, 42, 5050}}`.

**¿Por qué el instante y no los milisegundos?** Porque la entrada viaja a las otras réplicas. Si viajara "50 ms", cada réplica contaría desde que le llega el mensaje y el valor viviría más en unas que en otras. Con el instante absoluto, todas vencen al mismo tiempo, porque comparten el reloj de la misma VM.

### Cuándo se detecta: al leer

```erlang
vigente(infinity) -> true;
vigente(Expira) -> erlang:monotonic_time(millisecond) < Expira.
```

```erlang
{get, Client, Ref, Key} ->
    case maps:find(Key, Map) of
        {ok, {_Version, {value, Value, Expira}}} ->
            case vigente(Expira) of
                true  -> Client ! {Ref, ok, Value};
                false -> Client ! {Ref, not_found}
            end;
        {ok, {_Version, tombstone}} ->
            Client ! {Ref, not_found};
        error ->
            Client ! {Ref, not_found}
    end,
    loop(Peers, Map);
```

El `get` tiene tres casos:

| Lo que encuentra | Respuesta |
|---|---|
| Valor vigente | `{ok, Value}` |
| Valor vencido | `not_found` |
| Tombstone | `not_found` |
| Nada | `not_found` |

A esto se le llama **detección perezosa**: el valor vencido sigue en el mapa, pero nadie lo ve. Como la comprobación se hace justo en el momento de responder, **nunca se devuelve un valor vencido**.

### TTL = 0

`expira(0)` devuelve "ahora", así que el valor nace vencido. Igual se guarda con su versión, y por eso **reemplaza al valor anterior**:

```erlang
put(P1, k, viejo),
put(P1, k, nuevo, 0),
get(P1, k).            %% not_found, no 'viejo'
```

Si no se guardara, `get` devolvería `viejo`, que es incorrecto.

## 7. Lo que todavía no está implementado

- **4.7, capacidad y desalojo:** el límite de 16 valores no se controla.
- **4.8, lectura con consulta a otras réplicas:** si la réplica no tiene información sobre una clave, responde `not_found` sin preguntar a las demás.
