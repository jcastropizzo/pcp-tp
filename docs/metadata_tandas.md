# Recolección de metadata por tandas

Con `N` réplicas y capacidad local `α`, cada réplica puede **originar hasta
α operaciones `put` o `delete` por tanda**. Un cambio admitido se aplica
localmente, responde `ok` y se envía a los demás por el mecanismo asíncrono
existente. La réplica que agota su cupo empieza el cierre. Recibir el primer
aviso de cierre también hace que una réplica deje de admitir cambios, aunque
le quede cupo local.

| Fase | Aviso enviado a todos los pares | Condición para avanzar |
| --- | --- | --- |
| Cerrar actualizaciones | `{tanda, Ronda, Emisor, actualizaciones, ok}` | Haber procesado el aviso de todos los pares. Se envía después de propagar la última actualización local. |
| Cerrar ofertas | `{tanda, Ronda, Emisor, ofertas, ok}` | Haber procesado los avisos de ofertas de todos los pares y terminado las lecturas locales pendientes. Se envía después del cierre de actualizaciones. |
| Intercambiar residentes | `{tanda, Ronda, Emisor, residentes, Claves}` | Tener las listas de todos los pares. Cada lista sale de las claves de `Valores`, incluidos los residentes vencidos. |
| Compactar y reabrir | `{tanda, Ronda, Emisor, compactada, ok}` | Haber compactado localmente y recibido esa confirmación de todos los pares. Cada réplica abre entonces la siguiente ronda. |

El cierre es entre pares y cada aviso identifica su ronda y emisor. Cada
réplica cuenta como máximo un aviso por par en cada fase. La réplica sigue
respondiendo consultas entre pares y lecturas que puede resolver localmente
durante el cierre. Pospone las lecturas que iniciarían una consulta nueva
hasta la próxima tanda. Una réplica que ya abrió la siguiente puede enviar
antes de que otro par termine de recibir todas las confirmaciones. El
receptor deja en el buzón las actualizaciones y ofertas de esa nueva tanda
mientras está compactado, y los avisos cuya ronda aún no abrió.

## Por qué se puede olvidar una marca

1. Para cada emisor, su aviso de actualizaciones llega después de su último
   `replicar` del período. Al procesar los avisos de todos, el receptor ya
   procesó todas las actualizaciones de esa tanda. Por ejemplo, si el envío
   de un `put` viejo quedó pausado y llegó antes el `delete` de otra réplica,
   el receptor todavía tiene la marca cuando procesa el `put`.
2. Procesar esas actualizaciones puede emitir ofertas. Cada emisor manda su
   aviso de ofertas cuando ya procesó las actualizaciones de todos. Aceptar
   ofertas termina localmente y no emite más ofertas. El segundo cierre,
   también por FIFO entre emisor y receptor, cubre el último envío posible.
3. Antes de anunciar sus claves residentes, cada réplica completa sus
   lecturas pendientes. Por eso, cuando todas anunciaron sus claves, no
   queda un candidato de lectura de esa tanda que dependa de una marca por
   eliminar. Las lecturas vuelven a comparar con el estado local al finalizar.
4. Se conserva la metadata local de **toda clave residente en alguna
   réplica**, incluso si está desalojada en la réplica que compacta. Para
   una clave ausente en todas, ya no queda una copia ni una actualización u
   oferta de esa tanda que pueda recuperarla. Un `put` de una tanda posterior
   puede crearla de nuevo con una versión nueva.

## Cotas y progreso

El único mapa de almacenamiento es `Valores` y tiene a lo sumo **α** entradas.
El cierre no mueve valores ni cambia `Recientes`. Se conserva el ranking
existente, su tratamiento de borrados y su máximo de `ceil(3 × α / 4)`.

Al compactar, la unión de claves residentes contiene a lo sumo **N × α**
claves, así que esa es la cota de `Metadatos` por réplica en ese punto. Entre
cierres se admiten como máximo **N × α** cambios en todo el sistema. Cada uno
puede incorporar como máximo una clave al conjunto rastreado. Una oferta
corresponde a una escritura de la tanda o a una clave residente al inicio.
Por eso la cota durante toda la tanda es **2 × N × α** entradas por réplica.
Los avisos agregan estado de control de orden **N** y las listas de residentes
hasta **N × α** referencias a claves. Estas cotas cuentan entradas, no bytes,
ni incluyen los pedidos de clientes no admitidos que quedan en el buzón o
las lecturas transitorias.

Una tanda parcial puede quedar abierta si cesa la actividad antes de llenar
un cupo. Su metadata sigue dentro de la cota y se recolecta al cerrar esa
tanda. El cierre progresa si los procesos siguen vivos y procesan
eventualmente sus mensajes. Tras consumir su cupo, los **pedidos nuevos
pueden esperar** por el cierre de la tanda anterior. El `ok` de un cambio
admitido sigue sin depender de que sus pares apliquen ese cambio.

El caso que revivía un borrado con el cupo anterior queda como antecedente en
[la nota del experimento](metadata_cupo.md). Las pruebas de esta rama usan
la API real y controlan la planificación para reproducir una escritura
atrasada, una oferta atrasada y una lectura con un candidato viejo. También
verifican la reutilización de la clave y miden la cota en el ciclo de recepción.
