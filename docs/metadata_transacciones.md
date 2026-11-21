# Cupo duro de metadata con transacciones por clave

Diseño implementado para el TP de PCP. Las reservas acotan el crecimiento de
metadata de `main` y la recolección confirmada evita olvidar marcas que todavía
protegen contra mensajes demorados.

## 1. Contrato

- `Valores` tiene **a lo sumo α entradas en cada réplica**. Se sigue usando la
  política actual de `Recientes`, con `ceil(3 × α / 4)` claves protegidas,
  incluidos sus criterios de TTL, actualización y desalojo.
- Con `N` réplicas, el tope duro es **`C = N × α + 1` claves de metadata** por
  réplica. Una marca de borrado o desalojo pendiente de confirmación sigue
  ocupando su cupo. El tope cuenta entradas, independientemente del tamaño de
  las claves.
- La comparación de versiones sigue siendo por clave. Para dos escrituras
  de la misma clave, gana la mayor versión. Las escrituras de claves distintas
  pueden coexistir y ejecutarse en paralelo. Ante presión de capacidad decide
  la política actual de desalojo.
- El TTL comienza al aplicar el `put` admitido. Se replica el mismo vencimiento
  absoluto y se verifica al responder una lectura, como en el protocolo actual.
- Se conserva la API. Una vez admitido un `put` o `delete`, la réplica lo aplica
  localmente y responde `ok` sin esperar las confirmaciones de ese cambio. La
  espera puede ocurrir antes de la admisión, por cupo o por una operación sobre
  la misma clave.
- Se mantienen los supuestos del TP. Las réplicas se ejecutan en una única BEAM,
  no se caen y procesan eventualmente los mensajes del protocolo.

## 2. Quién lleva el cupo

Cada instancia tiene un coordinador de cupos, implementado con un proceso y un
ciclo `receive`. Las réplicas siguen aplicando escrituras, eligiendo víctimas y
respondiendo lecturas. El coordinador lleva **claves y referencias**, sin copias
de los valores. Su estado, como el de las réplicas, vive en el ciclo del proceso.

El coordinador mantiene una tabla `Cupos` de hasta `C` claves. Cada entrada
contiene una referencia de la reserva, el cambio admitido para esa clave si lo
hay, las réplicas que conservan una copia y los envíos aún sin confirmar. La
recolección tiene sus propias confirmaciones, asociadas a la misma reserva.
Cada entrada local de `Metadatos` lleva esa referencia junto a su versión y
estado. Las réplicas usan la referencia para asociar el olvido a la reserva
correcta, incluso si se vuelve a usar la misma clave más adelante.

1. Antes de aplicar un `put` o `delete`, su réplica pide permiso para la clave.
   Si la clave ya tiene una reserva libre de otro cambio o recolección, usa esa
   reserva. Si es nueva y hay cupo, se reserva una entrada antes de autorizar el
   cambio. Esto incluye un `delete` de una clave desconocida.
2. Con el cupo lleno, un pedido de clave nueva espera. Un pedido de una clave ya
   reservada puede avanzar si su clave está disponible. El tráfico de las
   operaciones ya admitidas, las consultas entre pares y las confirmaciones
   siguen tramitándose.
3. Hay un cambio de cliente en curso por clave. Las réplicas asignan la versión
   real con el mecanismo actual al aplicar el cambio. El coordinador devuelve
   disponibilidad para otro cambio de la misma clave cuando se procesaron sus
   réplicas y ofertas. Si la clave quedó recolectable en ese punto, primero se
   cierra su recolección.

Se usa `N × α + 1` porque el sistema puede conservar hasta `N × α` claves
residentes **distintas**, y todavía hace falta una plaza para intentar escribir
una clave nueva cuando todas esas plazas están ocupadas. Por ejemplo, con tres
réplicas y α = 4, el tope es **13**. El cupo experimental de 8 puede quedar por
debajo de la cantidad de claves que todavía tienen una copia y cuya metadata
hay que conservar.

## 3. Cambios, ofertas y confirmaciones

Se conserva el envío directo entre réplicas. Cada actualización lleva la
referencia de la reserva y el identificador del cambio que la originó. Una
oferta lleva además su propia referencia y la reserva de la **clave ofrecida**,
que puede ser distinta de la clave del `put` que provocó el desalojo.

El coordinador registra los `N` participantes de un cambio antes de dar permiso.
Cada participante, incluido el que recibió el pedido del cliente, informa
cuándo lo procesó. El informe identifica las claves que ingresaron o salieron
de su `Valores` y todas las ofertas que generó al hacerlo. Así, cuando una
réplica suelta una copia para ofrecerla, su informe registra **en un mismo
paso** la salida de la copia y las transferencias que quedan pendientes. La
réplica conserva la regla de ofrecer el valor vigente antes de descartarlo.

El receptor de una oferta decide con las mismas reglas que hoy. Informa si
conservó la clave y qué cambió en `Valores`, incluida la posible salida de un
vencido. Como hoy, aceptar una oferta no dispara otra oferta. El coordinador
actualiza la información de residencia al procesar ese informe y da por
terminado ese envío.

Los informes de una misma réplica salen de su ciclo en el mismo orden en que
procesó los cambios. Entre réplicas distintas, puede llegar el resultado de
una oferta antes del informe del emisor que la registró. En ese caso, se
guarda el resultado por identificador de cambio y referencia de oferta hasta
recibir ese informe. El cambio que provocó la oferta sigue pendiente hasta
recibir todos los informes de aplicación y cerrar todas sus ofertas. Cada
confirmación se cuenta una sola vez, por réplica o por referencia de envío.

| Mensaje lógico | Emisor → receptor | Efecto |
| --- | --- | --- |
| `pedir_cupo(Cliente, RefPedido, Clave)` | Réplica → coordinador | La réplica reenvía el pedido del cliente. |
| `{RefPedido, permiso, Reserva, IdCambio}` | Coordinador → cliente | Concede el permiso para enviar el cambio a su réplica. |
| `replicar(Clave, Reserva, IdCambio, Entrada)` | Origen → pares | Aplica el valor o borrado versionado usando las reglas actuales. |
| `ofrecer(Clave, Reserva, IdCambio, RefOferta, Entrada)` | Réplica que desaloja → par | Ofrece la copia vigente. Cada destinatario tiene su propia referencia de envío. |
| `aplicado(IdCambio, Replica, Altas, Bajas, Ofertas)` | Cada réplica → coordinador | Confirma el resultado local del cambio, incluidos los desalojos y los envíos que generó. |
| `oferta_resuelta(IdCambio, RefOferta, Replica, Altas, Bajas)` | Receptor de oferta → coordinador | Informa si quedó una copia y actualiza la residencia de las claves afectadas. |
| `preparar_olvido(Clave, Reserva)` | Coordinador → réplicas | Deja la clave en cierre y da tiempo a que terminen las consultas pendientes de esa clave. |
| `lecturas_drenadas(Clave, Reserva, Replica)` | Cada réplica → coordinador | Confirma que terminó sus lecturas anteriores y que pospone nuevas consultas para esa clave. |
| `olvidar(Clave, Reserva)` | Coordinador → réplicas | Elimina la metadata de esa reserva. |
| `olvidada(Clave, Reserva, Replica)` | Cada réplica → coordinador | Confirma la eliminación. El coordinador devuelve el cupo al recibir todas. |

La admisión es un intercambio interno de la API. El cliente conserva el valor
del `put` hasta recibir el permiso. En ese momento manda
`{cambiar, Cliente, RefPedido, Clave, Reserva, IdCambio, Contenido}` a su réplica.
Al iniciar se configura cada réplica con su capacidad, pares y coordinador.
Al terminar, cada réplica notifica al coordinador con `{detener, Replica}`.
La última espera su salida.

`Altas` y `Bajas` informan cambios en la **presencia física** de claves en el
mapa, sin transportar sus valores. Un vencido que todavía ocupa plaza cuenta
como residente para este control. El coordinador procesa cada informe completo
antes de evaluar si alguna clave se puede recolectar.

## 4. Qué se recolecta

### Borrado explícito

El `delete(k)` instala `{V, borrado}` y libera la plaza local. Cada réplica
confirma que procesó ese borrado después de aplicar `V` o preservar una versión
posterior que ya conocía. La marca queda disponible para rechazar una oferta
anterior que todavía esté en camino. Las confirmaciones de aplicación **y** el registro de
envíos pendientes son necesarios antes de iniciar el olvido. Si queda un
residente de una versión posterior, se conserva la entrada de esa clave.

### Desalojo

La réplica libera su plaza, conserva la marca y tramita las ofertas. Las
respuestas indican quién conserva la clave, y un desalojo posterior o un
borrado actualizan esa información. Si alguien la conserva, las demás réplicas
pueden seguir leyéndola por consulta. Si se confirmó que nadie la conserva y
que no queda ningún envío capaz de volver a instalarla, se puede olvidar su
metadata. El resultado es el retiro de la reserva que quedó sin copias. Un
`put` posterior recibe una reserva y una versión nuevas.

### Cierre de una clave sin copias

El coordinador inicia `preparar_olvido` cuando no hay copias reportadas, no
queda un cambio admitido para la clave y cerraron sus transferencias. Desde
ese momento retiene la reserva y deja en espera los permisos para esa clave.
Si llega un `get` nuevo para esta clave durante el cierre, la réplica responde
`not_found` localmente porque la ausencia global ya fue comprobada. Mantiene su
marca mientras terminan las lecturas anteriores y sigue contestando las
consultas que ya le enviaron sus pares. Las operaciones de otras claves siguen
su curso.

Después de todas las confirmaciones `lecturas_drenadas`, se emite `olvidar`.
Cada réplica descarta solo la entrada identificada por esa reserva, vuelve a
admitir consultas para la clave y confirma.
Al recibir todos los `olvidada` se libera la plaza y se pueden admitir los
pedidos retenidos. Una lectura posterior consulta el estado actual. Puede ver
la clave ausente o una copia de una escritura nueva que ya se haya aplicado.

## 5. Por qué funciona

**El tope se cumple incluso durante una demora.** Toda clave que figura en
`Metadatos` tiene una reserva vigente. Una aplicación de `put` o `delete` usa
una reserva concedida antes del envío. Un desalojo solo cambia el estado de una
clave que ya estaba reservada. Una oferta usa esa misma reserva. El coordinador
espera la eliminación en todas las réplicas antes de prestar la plaza de nuevo.
Por eso el número de entradas de `Metadatos` en cada réplica es menor o igual
al número de reservas, y este nunca supera `C`.

**Una copia no pasa inadvertida mientras está viajando.** Un `put` entra en el
registro antes de enviar sus actualizaciones. Una oferta nace de una copia
residente o de una actualización admitida que se descarta al llegar. El
coordinador sigue contando esa residencia o esa aplicación hasta que procesa
el informe que registra las ofertas. Cada recepción cierra su envío y a la vez
informa la copia que quedó, si la hubo. Si los informes se cruzan, una oferta
ya resuelta se concilia por referencia sin volver a abrir el envío. Así, ante
la ausencia de residentes, cambios admitidos y envíos pendientes para una clave,
ningún envío anterior puede volver a guardar una versión de esa reserva.

**El olvido tampoco revive una lectura pendiente.** Durante el cierre, las
lecturas que ya tenían un candidato pueden terminar y comparar con la marca
local. Cuando todas terminan se quitan las marcas. Las referencias de consulta
del protocolo actual permiten ignorar respuestas para lecturas ya finalizadas.

**Hay lugar para progresar cuando se estabiliza la actividad.** Con el cupo
lleno hay `N × α + 1` reservas y, aun usando todas las plazas de valores,
hay a lo sumo `N × α` claves con copia física. Cuando terminan los cambios y las
ofertas admitidos, al menos una reserva puede entrar en recolección. Se prioriza
iniciar ese cierre al procesar el informe que demuestra la ausencia y se da
curso a los pedidos de entrada nueva en orden de llegada cuando se libera
cupo. Se garantiza el avance al drenar el trabajo admitido. La ausencia de
inanición bajo una carga concurrente que nunca cesa es una propiedad aparte.

Las confirmaciones agregan control acotado. Cada reserva tiene a lo sumo un
cambio de cliente en curso. Cada cambio tiene `N` aplicaciones y cada una puede
emitir una oferta a lo sumo a sus `N − 1` pares. El registro de control queda
acotado por el número de reservas y participantes. Los pedidos todavía no
admitidos quedan esperando como mensajes, al igual que los valores en tránsito
y las consultas pendientes del protocolo actual. El tope de `Metadatos` se
aplica a las entradas del mapa, no a los buzones ni a bytes de memoria total.

## 6. Caso adverso y pruebas por API

Con P1, P2 y P3, α = 4 y cupo 13, supongamos que P1 desaloja `k` al procesar
un `put` de otra clave y queda demorado justo antes de enviar su oferta vieja.

1. P2 ejecuta `delete(k)` y P3 aplica la marca, aunque todavía no llegó la
   oferta de P1. P1 aún debe confirmar el borrado y el cambio que provocó el
   desalojo todavía tiene trabajo pendiente.
2. P1 reanuda, envía la oferta con la versión anterior y procesa el borrado de
   P2. P3 rechaza la oferta porque la marca sigue presente. La respuesta al
   envío también se registra, aunque no haya instalado nada.
3. Al recibir todas las aplicaciones y los resultados de las ofertas, el
   coordinador puede iniciar el cierre de `k` si ninguna réplica la conserva.
   Primero espera las lecturas pendientes y después libera el cupo.
4. `get(k)` devuelve `not_found` una vez estabilizada la propagación. Un nuevo
   `put(k, azul)` vuelve a crearla con una versión mayor y obtiene su propio
   permiso. El mensaje viejo nunca recupera `rojo`.

La suite cubre estos escenarios con `start_link`, `put`, `delete`, `get` y
`stop`. Los casos adversos usan operaciones de la API y controlan la
planificación de las réplicas con el depurador de OTP. En la prueba de lectura
pendiente, un par controlado retiene una respuesta de consulta y sigue
participando en el protocolo de cupos.

- Dos `put` sobre claves distintas con espacio. Se admiten en paralelo y se
  conservan ambos valores si caben. Con dos escrituras sobre la misma clave
  se conserva la última versión.
- `delete` con una escritura de esa misma clave todavía sin confirmar. La
  escritura ya admitida termina su propagación, el borrado se admite después
  y `k` queda ausente. Verificar también la oferta vieja del ejemplo anterior.
- Desalojo con copia en otro par y desalojo de la última copia. En el primer
  caso, la lectura remota recupera el valor. En el segundo, el cupo se libera
  al finalizar las confirmaciones.
- Réplica demorada y más de `C` claves distintas en pedidos concurrentes. Los
  nuevos pedidos esperan al alcanzar el cupo, las confirmaciones pueden
  avanzar y ninguna réplica supera `C` en metadata ni α en `Valores`.
- Lectura con candidato anterior al borrado, reutilización de la clave, TTL
  y conservación de la política de `Recientes`.
- Una sola réplica y varias réplicas. Al llamar `stop` al final se detienen las
  réplicas y el coordinador de esa instancia.

El cambio se limita a la admisión, el seguimiento de aplicaciones y ofertas,
y el olvido de la clave. Las reglas de selección de víctima, lectura por
consulta, TTL, versiones y protección de los recientes se reutilizan.
