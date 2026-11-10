# TP Key-Value replicado – Documento de diseño

## 1. Estructura de las réplicas

Cada réplica es un proceso de Erlang que corre un `loop` y va pasando su estado de una vuelta a la siguiente. En ese estado guarda varias cosas.

Primero, la lista de pids de las otras réplicas (`Peers`). La necesita porque cada vez que hay un cambio se lo tiene que avisar a las demás, y también para ofrecerles valores cuando desaloja o para preguntarles cuando le piden algo que no tiene.

También guarda `Alfa`, que es la cantidad máxima de valores que puede tener al mismo tiempo.

Los datos van en un mapa (`Map`). Para cada clave se guarda `{Version, Valor, Vence}`. La versión sirve para decidir qué cambio gana cuando dos llegan desordenados. El vencimiento se guarda como un instante absoluto, no como un TTL relativo, así cualquier réplica puede saber si el valor sigue vigente sin importar cuándo le llegó. Este mapa es lo único que cuenta para la capacidad α.

Aparte hay metadatos de claves que no tienen valor. Ahí están las lápidas de los borrados (la clave marcada como `borrado` con su versión) y las marcas de claves que fueron desalojadas. Las lápidas hacen falta para que un put viejo que llega tarde no vuelva a crear algo que ya se borró. Estos metadatos no ocupan lugar de α.

Por último, la réplica tiene una lista de `Pendientes`: los get que mandó a preguntar a otras réplicas y que todavía están esperando respuestas.

## 2. Protocolo de comunicación

Al arrancar, `start_link` crea todas las réplicas y le manda a cada una un mensaje `peers` con la lista de las demás y el valor de α. Cuando lo recibe, la réplica guarda esos datos y empieza a atender pedidos.

El cliente se comunica con una réplica mediante `put`, `get`, `delete` y `stop`. Todos llevan una `Ref` para que el cliente sepa que la respuesta que recibe es la suya.

Cuando una réplica recibe un `put` con clave, valor y TTL, genera una versión nueva, guarda el valor, le responde ok al cliente y le manda un `replica` a las demás. Si con eso se pasó de α, desaloja.

El `delete` es parecido: genera una versión nueva, saca el valor, deja una lápida, responde ok y también avisa con un `replica`.

El mensaje `replica` va de una réplica a todas las otras con la clave, la versión y el valor con su vencimiento, o la lápida si fue un borrado. La que lo recibe solo lo aplica si esa versión es mayor que la que ya tiene. Después revisa si se pasó de capacidad. No responde nada.

El mensaje `ofrecer` lo manda una réplica que está desalojando un valor, con la clave, la versión y el valor. La que lo recibe lo guarda solo si tiene lugar y si es más nuevo que lo que tiene. Si no, lo ignora. En ningún caso responde ni desaloja nada.

Cuando una réplica recibe un `get` y no tiene el valor porque lo desalojó, manda `consulta` a las demás con su pid, la `Ref` y la clave. Cada una contesta en el momento con un `respuesta` que trae lo que tiene de esa clave (versión y valor, lápida o nada). La que preguntó va anotando las respuestas y, cuando tiene todas, le contesta al cliente.

Con `stop`, la réplica responde ok y termina.

## 3. Resolución de conflictos y borrados

Elegimos last-writer-wins con lápidas. Cada put o delete recibe una versión que genera la réplica que lo atiende con `erlang:unique_integer([monotonic])`. Ese número nunca se repite y siempre crece, así que nunca hay dos versiones iguales.

Cuando a una réplica le llega un cambio sobre una clave, compara versiones y se queda con la mayor. El borrado funciona exactamente igual que un put, solo que en lugar de un valor guarda una lápida con su versión.

Esto funciona por varias razones. Como siempre se queda la versión más alta, no importa en qué orden lleguen los mensajes ni si llega alguno repetido: el resultado es el mismo. Entonces, una vez que todas las réplicas recibieron todos los cambios, todas tienen lo mismo. Si hay dos put concurrentes sobre la misma clave en réplicas distintas, todas eligen el de versión más alta, o sea que todas eligen el mismo. Y si un put viejo llega después de un delete, pierde porque su versión es menor que la de la lápida, así que el dato borrado no reaparece. En cambio, si el usuario hace un put nuevo después del borrado, ese tiene versión mayor y gana.

## 4. Detección de vencimiento

Cuando se hace un put se calcula `Vence = ahora + TTL`, o `infinity` si no tiene TTL, y ese valor viaja así en la replicación. No usamos timers: el vencimiento se revisa en el momento en que se usa el valor.

En un get, si `ahora >= Vence`, el valor se toma como si no existiera y se responde `not_found`. Lo mismo pasa cuando otra réplica responde una consulta: un valor vencido no se devuelve. Al desalojar, antes de sacar un valor válido se limpian los vencidos, que quedan marcados como borrados con su misma versión para que un mensaje viejo no los vuelva a crear.

Como todas las réplicas comparan contra el mismo instante absoluto, todas coinciden en cuándo vence un valor, aunque lo hayan recibido en momentos distintos.

## 5. Desalojo

Cada réplica puede tener como máximo α valores. Después de guardar un valor, ya sea por un put o por un `replica`, revisa si se pasó.

Si se pasó, primero saca los valores vencidos. Si con eso vuelve a estar dentro del límite, termina ahí y no se pierde nada válido. Si no alcanza, elige el valor de menor versión, que es el que se escribió hace más tiempo, se lo ofrece a las demás réplicas con `ofrecer`, lo saca de su mapa y deja una marca de que fue desalojado. Así, si después le piden esa clave, sabe que tiene que ir a buscarla a otra réplica.

Esto no genera mensajes infinitos. Una réplica solo acepta una oferta si tiene menos de α valores, así que después de aceptarla sigue dentro del límite y nunca necesita desalojar por eso. Además, no responde nada a la oferta. Entonces una oferta nunca dispara otro mensaje, y cada desalojo termina después de mandar un mensaje a cada réplica.

Tampoco se desaloja de más. Cada réplica atiende un mensaje por vez y solo desaloja hasta volver a α. Como los valores se agregan de a uno, en cada caso sale como mucho uno.

## 6. Algoritmo para get

Si la réplica tiene la clave vigente en su mapa, responde directamente. Si tiene una lápida, responde `not_found`. El caso interesante es cuando la clave fue desalojada o no la conoce: ahí tiene que preguntarles a las demás.

En ese caso manda `consulta` a todas las otras réplicas y anota el pedido en `Pendientes`, con el cliente, la `Ref` y cuántas respuestas le faltan. Después vuelve a su `loop` normal, sin quedarse bloqueada, y sigue atendiendo puts, gets, replicaciones, ofertas y consultas de otras réplicas mientras espera.

Cada respuesta que llega se suma al pedido pendiente. Cuando ya tiene todas, junta lo que le contestaron con lo que tiene ella, se queda con la versión más alta y, si es un valor vigente, se lo devuelve al cliente. Si no encontró nada, o lo que ganó es una lápida o un valor vencido, responde `not_found`.

Esto no produce deadlock porque ninguna réplica se queda trabada en un `receive` esperando a otra. Las consultas se responden en el momento con lo que cada réplica tiene, sin preguntarle a nadie más. Entonces, aunque dos réplicas se consulten entre sí al mismo tiempo, cada una contesta la consulta de la otra desde su `loop` normal y las dos terminan. El único que se queda esperando es el cliente, y siempre recibe su respuesta porque todas las réplicas consultadas contestan.
