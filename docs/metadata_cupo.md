# Cupo de metadata y contraejemplo de borrado

## Regla implementada

Por réplica, `Pares` contiene las otras réplicas, sin incluir al proceso local.
La función `simple_kv_almacen:cupo_metadatos/2` recibe la cantidad de peers y α.
El cupo es `max(2, length(Pares)) * Alfa`. Con tres réplicas y α = 4, cada
réplica tiene dos peers y el cupo es **8 entradas totales de metadata**.
Con 0, 1 o 2 peers se usa `2 * Alfa` como piso; para más de 2 peers se
usa su cantidad real. Este piso también se aplica a una sola réplica. El máximo de plazas de valores del sistema, en cambio,
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

## Reproduccion por API y alcance de la evidencia

`caso_borde_documentado_put_viejo_restaura_borrada_por_api_test/0` usa tres
replicas creadas por `simple_kv:start_link/2` y realiza las escrituras, borrados
y lectura mediante `put/3`, `delete/2` y `get/2`. No invoca `nueva_version/0`,
no fija versiones o lineas de codigo numericas y no arma ni reenvia mensajes
del protocolo. Los envios salen de los procesos de replica originales.

Para que el orden no dependa del azar, el test usa el debugger de OTP sin
interfaz grafica: interpreta `simple_kv_replicacion` y coloca un punto de pausa
por nombre de funcion, al entrar a `replicar/3`. Ejecuta un unico
`put(P1, k, rojo)` y comprueba que P1 quedo detenido antes de enviar. Desactiva
el punto para las siguientes operaciones, pero mantiene P1 detenido.

Mientras P1 esta pausado:

1. Ejecuta `delete(P2, k)` y verifica por observacion que P2/P3 aplicaron su
   marca; `get(P3, k)` da `not_found`.
2. Calcula el cupo con `cupo_metadatos/2` y hace esa cantidad de llamadas
   `delete(P2, {relleno, N})` a claves distintas. En este escenario son ocho.
3. Verifica que P2 y P3 procesaron el ultimo borrado de relleno y olvidaron
   `k`, sin guardar su valor.

Despues libera P1. La implementacion real envia su escritura pendiente y
procesa los borrados acumulados. El test espera observar `k` residente en
P3 y que P1 haya procesado la secuencia de borrados, sin su valor original.
Finalmente verifica **`get(P3, k) =:= {ok, rojo}`**. No hay otro `put` de `k`.

Las trazas solo observan el estado para esperar precondiciones; no fabrican
trafico ni cambian el estado. Las esperas comprueban condiciones con plazo,
no usan una pausa fija como prueba de entrega. La limpieza retira las trazas,
reanuda P1, detiene las replicas y deja de interpretar el modulo.

Esta prueba reemplaza los tres tests anteriores del mismo caso que inyectaban
mensajes con emisores controlados (dos regresiones fallidas y una prueba del
comportamiento conocido). El caso de oferta vieja sigue documentado arriba,
pero no se presenta como verificado por una prueba de API independiente.

La pausa fuerza una planificacion posible del programa sin modificar el
protocolo. **Demuestra que el caso es alcanzable por API, no su frecuencia ni
que vaya a aparecer en una corrida sin instrumentacion.** En esta ejecucion
P3 puede procesar V1 antes de que P1 termine sus borrados; al final se verifica
que P1 tambien los proceso y que P3 conserva el dato resucitado. No se exige
forzar exactamente el suborden t6-t7 del ejemplo mas fuerte de arriba.

El resultado esperado de este test es la resurreccion: **pasa para documentar
una limitacion conocida y aceptada para el experimento**. No valida §4.5 ni
convierte el cupo en recoleccion segura. Tambien pueden verse afectadas otras
combinaciones de ofertas, reutilizacion y lecturas pendientes. Este cambio
sigue siendo experimental y no esta listo para reentrega.

## Resultado de la verificacion

Compilacion con `rebar3 compile` y compilacion directa con
`erlc +warn_all -Werror` sin advertencias. Suite completa: **92/92 aprobados**,
sobre una copia temporal de los mismos fuentes. Incluye los 83 tests historicos
sin modificar, cinco tests del calculo/recorte y cuatro tests de metadata.

Con tres replicas y alfa = 4, las dos mediciones por cinco tandas de doce
claves pasan: metadata = 8 por replica en todas las tandas, `Recientes` = 3;
valores = 4 con desalojo y 0 con borrado. La prueba por API del caso borde pasa
al observar `{ok, rojo}` en lugar del resultado correcto segun la consigna,
`not_found`. Que la suite pase no acredita la seguridad del borrado.

El nuevo piso de dos peers conserva las marcas esperadas por seis pruebas
historicas que fallaban con el piso anterior de uno; no se cambiaron sus
expectativas. El componente `debugger` de OTP y la compilacion con `debug_info`
(ya configurada en `rebar.config`) son necesarios para la prueba por API.
