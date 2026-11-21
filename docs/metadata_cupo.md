# Cupo de metadata y contraejemplo de borrado

## Regla implementada

Por réplica, `Pares` contiene las otras réplicas, sin incluir al proceso local.
La función `simple_kv_almacen:cupo_metadatos/2` recibe la cantidad de peers y α.
El cupo es `max(1, length(Pares)) * Alfa`. Con tres réplicas y α = 4, cada
réplica tiene dos peers y el cupo es **8 entradas totales de metadata**.
Con una sola réplica se usa α como mínimo para conservar la información de
sus valores residentes. El máximo de plazas de valores del sistema, en cambio,
es `Count * Alfa`: peers y cantidad total de réplicas no son lo mismo.

Antes de volver al ciclo de recepción se conserva toda la metadata de claves
con valor residente. Las plazas restantes se completan con las marcas de mayor
versión, sean `borrado` o `desalojado`. Se eliminan las demás. No hay timeout,
confirmaciones ni barrera de propagación. El ranking `Recientes` no se modifica.

Como `map_size(Valores) <= Alfa <= cupo`, siempre entran los residentes. La
metadata del siguiente estado de recepción tiene como máximo el cupo. Durante
una transición se puede construir un mapa temporal con una entrada adicional;
la cota es de entradas persistentes, no de bytes, buzones ni lecturas pendientes.
Las claves y valores son términos de tamaño arbitrario.

El comentario de la función identifica el cupo como una heurística de tamaño
para α y cantidades de peers chicos. Para α grandes probablemente haya que
reevaluar el presupuesto de memoria y el costo del recorte, que ordena las
marcas al superar el cupo. Esto no afirma seguridad ni siquiera con α chico.

Esta regla acota el tamaño pero **no constituye recolección segura**. La cantidad
de valores guardados no acota cuántos borrados necesitan protección frente al
historial de mensajes. Los siguientes casos incumplen §4.5 de la consigna y
pueden producir resultados incorrectos aun después de estabilizar la propagación.

## Contraejemplo principal: escritura vieja después del borrado

### Preparación

- Tres réplicas reales: **P1, P2 y P3**. Capacidad α = 4 y cupo de metadata = 8
  en cada una. Pares de P1: `[P2,P3]`; de P2: `[P1,P3]`; de P3: `[P1,P2]`.
- Estado inicialmente vacío; procesos vivos, una única BEAM, sin fallas.
- Clave `k`, valor `rojo`, TTL `infinity`.
- Versiones simbólicas `V1 < V2 < V3 < ... < V10`, generadas en ese orden por
  el mecanismo existente. No son tiempos de reloj.
- Ocho claves de relleno distintas `d1` a `d8`, diferentes de `k`. Se borran
  aunque no existan: la API lo admite y cada borrado genera una marca nueva.

### Cronología permitida

Los instantes son pasos lógicos; no requieren un tiempo concreto en milisegundos.

| Instante | Proceso que ejecuta | Acción y mensajes | Estado relevante |
| --- | --- | --- | --- |
| t0 | Cliente → P1 | `put(P1, k, rojo)` | P1 genera V1 y guarda el valor. |
| t1 | P1 | Responde `ok` al cliente. El scheduler lo desplanifica **antes de ejecutar** `replicar/3`. | P1 tiene `k`; aún no envió su escritura a P2 ni P3. El `ok` no confirma propagación. |
| t2 | Cliente → P2 | `delete(P2, k)`. P2 genera V2 y envía a P1 y P3 `{replicar, k, {V2, borrado}}`. | P2 guarda la marca, aunque todavía no vio V1. P1 permanece sin ejecutar. |
| t3 | Cliente → P2 | Ocho llamadas `delete(P2, di)`, en orden. Para cada i, P2 genera V(i+2) y envía a P1 y P3 `{replicar, di, {V(i+2), borrado}}`. | En P2, al entrar d8 hay nueve marcas: se elimina `k`, que es la de menor versión. |
| t4 | P3 | Procesa el borrado de `k` y luego los ocho borrados de relleno de P2. | P3 también pierde la marca de `k`. No tiene valores. Su metadata contiene d1…d8. |
| t5 | P1 | Vuelve a ejecutar y completa el envío pendiente: a P2 y P3 les manda `{replicar, k, {V1, {valor, rojo, infinity}}}`. | P2 y P3 pueden dejar ese mensaje en el buzón sin procesarlo todavía. |
| t6 | P1 | Procesa los nueve mensajes de P2, en el orden enviado: primero borra `k` con V2; luego aplica d1…d8. | Ahora **las tres réplicas procesaron el borrado de k** y las tres olvidaron su marca. P1 ya no tiene el valor. La escritura V1 espera en P2/P3. |
| t7 | P3 | Procesa la escritura V1 de P1. | No encuentra metadata para `k`. `version_no_obsoleta/3` devuelve `true`; hay plaza libre y guarda `rojo`. |
| t8 | P2 | Procesa también V1, que había quedado pendiente. | Acepta el mismo valor por el mismo motivo. Se procesa el resto del tráfico. |
| t9 | Cliente → P3 | `get(P3, k)` | **Resultado requerido: `not_found`. Resultado actual: `{ok, rojo}`.** No hubo una escritura nueva de `k`. |

En t7, la metadata de `k` tiene una versión menor que las ocho marcas de
relleno, pero se conserva porque `k` volvió a ser un valor residente. Se elimina
una marca de relleno para mantener el cupo. El recorte no corrige la resurrección.

### Qué debe hacer Erlang y qué no se supone

1. El scheduler debe permitir que P1 quede pausado entre el `ok` local y el
   envío de réplicas. Ese intervalo existe en `simple_kv_replica`; no se agrega
   un bloqueo al programa. Una ejecución posible alcanza para el contraejemplo.
2. P2 y P3 ejecutan mientras P1 está pausado. P2 puede completar operaciones
   porque `put` y `delete` no esperan a sus peers.
3. Cada receptor procesa los mensajes de P2 en FIFO: borrado de `k`, d1, …, d8.
   **No se invierte ningún par de mensajes del mismo emisor al mismo destino.**
4. Se pausa la ejecución de P2 y P3 alrededor de t5 para que procesen V1 después
   de t6. Un mensaje puede estar en el buzón sin haber sido aplicado.
5. No se supone pérdida de mensajes, falla de procesos, reinicio, red entre
   máquinas ni alteración de versiones. La demora se obtiene por planificación
   y por el envío pendiente en P1, no por inventar un reordenamiento FIFO.

En t9 ya no quedan actualizaciones ni ofertas por procesar. P2/P3 conservan
`rojo`; P1, al consultar a sus pares, también puede responder `rojo`. Por lo
tanto, incluso un eventual acuerdo observable puede ser **incorrecto respecto
del borrado**. Esperar más no lo arregla: el protocolo no reenvía V2 y las tres
réplicas ya lo olvidaron.

## Variante: oferta vieja

Antes de enterarse del borrado, una réplica puede desalojar `k` y ofrecer la
copia V1. Si el emisor queda pausado antes del envío de esa oferta, el borrado
y el relleno pueden procesarse primero en el receptor. Al enviarse la oferta
pendiente, el receptor ya olvidó V2, tiene lugar y acepta V1. El envío de una
oferta usa la entrada capturada durante el desalojo; no vuelve a validar la
versión local justo antes de enviarla. Tampoco exige desordenar mensajes del
mismo emisor. El chequeo de TTL no lo impide porque el valor no vence.

## Pruebas y alcance de la evidencia

`test/simple_kv_metadatos_tests.erl` conserva las mediciones por tandas e incluye
dos pruebas adversas: escritura vieja y oferta vieja. Dos emisores controlados
inyectan mensajes del protocolo a tres réplicas reales. Cada entrega se confirma
con una consulta local del mismo emisor, aprovechando FIFO; no usa pausas
temporizadas como prueba de procesamiento.

El arnés fuerza el orden relevante después de olvidar las marcas. **No ejecuta
el `put`/`delete` original con una pausa real dentro de P1**: la cronología
anterior explica por qué ese orden es alcanzable por la implementación. La
variante de oferta prueba el receptor, no la planificación completa del emisor.

La prueba
`caso_borde_documentado_escritura_vieja_restaura_borrada_test/0` recorre la misma
secuencia de escritura vieja, verifica que las tres réplicas aplicaron el
borrado y respondían `not_found`, desplaza la marca con ocho borrados de
relleno y finalmente entrega V1. **Esta prueba pasa al observar `{ok, rojo}`**:
documenta el caso borde conocido y aceptado para el experimento, no el
cumplimiento de la consigna. No se realiza ninguna escritura nueva de `k`.

Las regresiones adversas exigen `not_found` y se dejan fallar con `{ok, rojo}`.
No se invierte la expectativa para que la suite aparente validar la seguridad.
Pasar las pruebas de tamaño acredita el cupo, no la preservación general de
versiones, borrados o convergencia. La pérdida de marcas también afecta otras
combinaciones de ofertas, reutilización y lecturas pendientes, no solo este
ejemplo. Este cambio es experimental y no está listo para reentrega.

## Resultado de la verificación

Compilación con `rebar3 compile` y compilación directa con
`erlc +warn_all -Werror` sin advertencias. Suite completa: **86 aprobados y
8 fallidos de 94**, sobre una copia temporal de los mismos fuentes.

Las dos mediciones por cinco tandas de doce claves pasan: metadata = 8 por
réplica en todas las tandas, `Recientes` = 3; valores = 4 con desalojo y 0 con
borrado. Las dos regresiones adversas fallan con `{ok, rojo}` en lugar de
`not_found`, reproduciendo el defecto documentado.

Los otros seis fallos son pruebas anteriores que inspeccionan marcas ahora
eliminadas por el cupo: tres en `simple_kv_capacidad_tests`, dos en
`simple_kv_consultas_tests` y una en `simple_kv_desalojo_tests`. Esas
expectativas se preservan; no se afirma que estén verificadas las operaciones
que esos tests dejan de ejecutar al fallar su inspección intermedia.
