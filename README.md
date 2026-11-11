# PCP — Base de datos key-value replicada

Almacén Erlang entre procesos de una misma VM BEAM. Requisitos: [consigna V5](consigna/kv_replicado.pdf). Diseño: [informe editable](informe_tp.md) · [documento final, cinco páginas](output/pdf/informe_tp.pdf).

**Entrega:** 11/11/2026 a las 23:59, mediante push al repositorio asignado por la cátedra. **Coloquio:** 18/11/2026, a coordinar con cada grupo.

## Requisitos del trabajo práctico

La [consigna V5](consigna/kv_replicado.pdf) es la fuente normativa. El checklist posterior distingue el estado de esta implementación; una decisión de diseño o un test aprobado no reemplaza un requisito de la consigna.

- **API (§3):** conservar las firmas de `start_link/2`, `stop/1`, `put/3`, `put/4`, `delete/2` y `get/2`. La API puede extenderse. `start_link` crea procesos enlazados y valida `Count`; `put/4` valida TTL en el invocante; `stop` retorna cuando terminaron todas las réplicas.
- **Replicación y consistencia (§4.2–4.5):** propagar cada escritura y borrado asincrónicamente, sin esperar su aplicación en los pares. Al cesar las escrituras las réplicas deben converger; resolver conflictos concurrentes sin depender del orden de llegada y evitar que un mensaje viejo resucite un borrado.
- **TTL (§4.6):** `infinity` no vence; `0` vence inmediatamente; nunca devolver un valor vencido. Un TTL inválido falla con `function_clause` en el proceso invocante.
- **Capacidad (§4.7):** cada réplica admite como máximo α valores, sin entradas adicionales en estructuras secundarias; se puede asumir α ≥ 3. La consigna exige que el 75 % escrito más recientemente **en el nodo local** siga disponible. Antes de descartar un valor vigente, dar a los pares oportunidad de conservarlo mediante un intercambio que termine. La pérdida es admisible en el peor caso indicado por la consigna.
- **Lectura y concurrencia (§4.8 y §5):** si falta información local, considerar la de las demás réplicas; asociar respuestas a pedidos, descartar mensajes inesperados y evitar deadlocks. Una réplica que espera información debe seguir atendiendo pedidos. El orden entre emisores distintos no está garantizado.
- **Restricciones y supuestos (§6–7):** sin behaviours OTP, ETS, DETS, Mnesia, `persistent_term` ni diccionario de proceso; estado en los argumentos del ciclo; compilación sin advertencias. Una VM BEAM, procesos sin fallas y una sola llamada final a `stop/1` con todos los identificadores.
- **Entrega (§8):** código `.erl`, tests propios que muestren los comportamientos mediante la interfaz externa y documento de diseño de hasta cinco páginas. Hacer push al repositorio asignado por la cátedra, con ambos integrantes y cuentas informadas a docentes.

El informe debe explicar la estructura de cada réplica; incluir una **tabla de todos los mensajes** con emisor, receptor, contenido y efecto; justificar conflictos y borrados; describir detección de TTL; justificar la política de desalojo y la terminación de sus mensajes; y explicar el `get` remoto y por qué no produce deadlock.

## Qué hay y qué falta

Un coordinador ordena escrituras y ofertas y comunica a todas las réplicas una única decisión de capacidad. La respuesta al cliente espera la aplicación en la réplica elegida, pero no en sus pares. Compilación estricta y **100 tests aprobados**, incluyendo réplicas atrasadas, TTL y ofertas coordinadas.

**Pendiente de los integrantes:** confirmar cuentas informadas a docentes, llevar los archivos al repositorio asignado y verificar el push final. Este es un repositorio privado de trabajo: publicar aquí no constituye la entrega.

Los checks señalan funciones implementadas o casos probados, no certifican el cumplimiento integral del requisito. En particular, debe revisarse la garantía del 75 % frente a todos los metadatos registrados y confirmar la interpretación con la cátedra. Una suite finita no demuestra todos los intercalados concurrentes.

## Política de desalojo: recencia protegida y TTL

Fuente: [consigna V5, §§4.6–4.7](consigna/kv_replicado.pdf). Citas textuales:

> «el 75 % escrito más recientemente (en el nodo local) siempre siga disponible» (§4.7).

> «nunca se devuelve un valor vencido» (§4.6).

> «No es válido tener entradas adicionales en alguna estructura secundaria, α es el tope de valores permitidos para un nodo.» (§4.7).

**Decisión de diseño acordada:** conservar físicamente las entradas del 75 % protegido aunque estén vencidas; `get` devuelve `not_found` para ellas. El PDF no prescribe literalmente esa conservación física ni el redondeo: son la interpretación implementada. Se usa Q = ceil(3α/4), redondeando hacia arriba. La recencia se ordena por versión entre las entradas residentes y la entrante, sin cupos separados por origen. No se agrega un estado `Locales`.

### Árbol de decisión para put y replicación

1. La réplica deriva el pedido al coordinador, que asigna versión y decide una sola vez. Para entradas recibidas, descarta versiones anteriores a la conocida. Una sobrescritura aceptable reemplaza su clave sin desalojar otra.
2. Si `map_size(Map) < α`, guardar la entrada, **incluso si ya venció**. Vencido no implica borrado físico ni vacante automática.
3. Si no hay espacio, considerar residentes más entrante sin construir otro mapa de valores. Proteger las Q versiones mayores, incluido el entrante si le corresponde.
4. Entre los **no protegidos**, elegir primero un vencido; si hay varios, el de menor versión. Si ninguno venció, elegir la menor versión elegible.
5. El candidato puede ser el entrante. El coordinador ordena su decisión a todas las réplicas. Si sale un residente, cada réplica lo retira antes de insertar para no superar α. Cada réplica ofrece el valor a los pares antes de descartarlo si sigue vigente; un vencido no se ofrece.
6. Conservar versión y estado `desalojado` al descartar. TTL no fabrica una lápida `borrado`; esa marca corresponde a `delete` explícito, que sí puede quitar una entrada protegida.

La preferencia por vencidos solo opera fuera del cupo protegido: **no es una política top-α pura cuando hay TTL**. Por ejemplo, α=4, versiones 1 vigente, 2 vencida, 3 y 4 vigentes, entrante 5: se protegen 3,4,5 y se retira 2, conservando 1.

### Ofertas y lecturas

Cada réplica ofrece a sus pares un valor vigente antes de descartarlo. Los receptores proponen la oferta al coordinador; este la procesa en el mismo orden global que las escrituras y distribuye su decisión a todas las réplicas. Una oferta puede ocupar una vacante, reemplazar su clave o reutilizar un vencido no protegido. No desaloja vigentes ni origina nuevas ofertas, de modo que el intercambio termina. Si se conserva una copia vencida, mantiene su vencimiento y sigue siendo invisible para `get`.

Las lecturas no quitan las entradas vencidas del mapa. La comprobación final de TTL en el cliente evita devolverlas incluso si vencieron mientras faltaban respuestas remotas.

### Verificación del criterio

Los tests citan la consigna y separan visibilidad por API de almacenamiento físico mediante consultas locales. Suite específica: `test/simple_kv_proteccion_ttl_tests.erl`; el orden del coordinador se prueba en `test/simple_kv_coordinador_tests.erl`.

| Caso | Resultado exigido |
| --- | --- |
| Vencido dentro de las Q recientes | Permanece en Map con metadato `valor`; get responde `not_found` |
| Vencido fuera de las Q recientes | Se prefiere antes que un vigente elegible más viejo |
| Ningún vencido elegible | Sale la menor versión no protegida |
| Entrante vencido reciente / antiguo | Se conserva si está protegido; puede descartarse si es elegible |
| α=3,4,5,7,16 | Q se redondea hacia arriba y nunca se supera α |
| Replicación, ofertas y sobrescrituras | No limpian protegidos; no renuevan TTL ni crean borrados por vencer |
| `delete` explícito | Elimina y deja lápida aunque la entrada estuviera protegida |

### Orden y convergencia

**La consistencia eventual se evalúa desde afuera:** cuando cesan las escrituras y se propagan los cambios, las lecturas a los distintos nodos deben responder de forma consistente y correcta. Las réplicas pueden tener estados internos distintos. Este diseño usa mapas iguales como estrategia para alcanzar esa propiedad, no como requisito externo en sí mismo. Cada `put` o `delete` se envía al coordinador, que asigna versión y calcula una sola vez la decisión de capacidad usando su índice de claves, versiones y vencimientos. No conserva valores de usuario en su estado. Envía el mismo evento ordenado a todas las réplicas; la réplica que recibió el pedido responde al cliente al aplicar su evento, sin esperar a los pares.

Las ofertas recibidas también se proponen al coordinador. Sus decisiones se emiten en el mismo flujo; una oferta aplicada no genera nuevas ofertas. Las réplicas no recalculan la víctima con su propio reloj al aplicar un evento. Como todos los eventos salen del mismo proceso, cada réplica los recibe en el mismo orden. Si cesan las escrituras y se procesan los mensajes, aplican las mismas transiciones a partir del mismo estado inicial. En particular, el antiguo contraejemplo de `put(d)` y `delete(d)` se ordena igual en todas. Una oferta pendiente puede volver a incorporar una copia cuando queda espacio, pero esa decisión también se aplica a todas.

- [x] Pruebas de réplica pausada durante puts/delete, aceptación de oferta coordinada y decisión de TTL aplicada después del vencimiento. Se comparan entradas locales completas, incluidas versiones y vencimientos.
- [x] La escritura termina en la réplica de origen incluso con otro nodo pausado; el coordinador termina después de detener la última réplica.
- [ ] Revisar la garantía del 75 % cuando hay metadatos de entradas desalojadas y borrados, y contrastar con cátedra la interpretación de «registro local». El selector actual ordena residentes más entrante, sin cupos independientes por origen.
- [ ] Completar la revisión de todos los intercalados y de la cobertura por interfaz pública. La prueba de un escenario y el orden común no sustituyen una revisión completa de la consigna.

## Checklist de requisitos V5

### Interfaz y réplicas — §3 y §4.1

- [x] API `start_link/2`, `stop/1`, `put/3`, `put/4`, `delete/2`, `get/2`. La V5 permite extensiones.
- [x] `start_link(Count, Alfa)` crea Count réplicas independientes enlazadas al invocante. Count no entero positivo falla con `function_clause`; Alfa se valida entero ≥3.
- [x] Claves y valores admiten cualquier término; pruebas con mapas, tuplas, listas, binarios y pid.
- [x] Guardar, sobrescribir, borrar incluso una clave inexistente y leer `{ok, Value}` o `not_found`.
- [x] `put/3` equivale a TTL `infinity`. TTL inválido falla en el proceso invocante.
- [x] `stop/1` espera terminación mediante monitor, sin timeout arbitrario. Regresión con réplica demorada más de un segundo.

### Replicación, conflictos y borrados — §4.2–4.5

- [x] Implementación: puts/deletes se propagan a todos los pares sin esperar confirmaciones.
- [x] Cada escritura obtiene una versión única creciente dentro de la VM; replicaciones y ofertas la conservan.
- [x] En los escenarios probados, gana la versión mayor independientemente del orden de llegada; hay pruebas con órdenes opuestos y escritores concurrentes.
- [x] Lápidas con versión impiden resurrección por puts antiguos; un delete viejo tampoco elimina un valor nuevo.
- [x] Desalojo local y borrado se distinguen en metadatos. Un desalojado se puede recuperar con una copia de igual versión.
- [x] El coordinador emite escrituras y ofertas en un orden común y decide una única víctima. Pruebas comparan mapas completos tras borrado, TTL y ofertas.
- [ ] Revisar el argumento de convergencia bajo todos los intercalados y su interacción con el 75 % registrado localmente.

### TTL — §4.6

- [x] Vencimiento absoluto con reloj monotónico compartido en la VM; recibir una copia no renueva TTL.
- [x] Casos 0, `infinity`, finitos, inválidos y sobrescrituras.
- [x] Comprobación de vigencia en el cliente al finalizar get, también si un candidato remoto vence mientras faltan respuestas.
- [x] Conservación física de vencidos protegidos, incluso TTL cero; nunca son devueltos. Solo se reutilizan vencidos no protegidos al necesitar espacio.

### Capacidad y desalojo — §4.7

- [x] Capacidad α recibida al iniciar; mapa con como máximo α valores. Se reserva espacio antes de insertar.
- [x] `Pendientes` contiene solo control de consultas. El coordinador conserva versiones y vencimientos, sin valores de usuario persistentes; los valores viajan en mensajes. La reducción de lecturas se realiza en el cliente.
- [x] Proteger Q = ceil(3α/4) versiones mayores, con entrante incluido; entre el resto priorizar vencidos y luego menor versión. Sin cupos por origen.
- [x] Sobrescritura llena sin desalojar otra clave; selector por versión con varios `infinity`; capacidad receptora y duplicados.
- [x] Valores vigentes ofrecidos a todos los pares antes de descartarlos.
- [x] Las ofertas se ordenan mediante el coordinador: usan vacante, reemplazo o vencido no protegido; su aplicación no genera nuevas ofertas ni desaloja vigentes. Conservan TTL incluso si expiró en tránsito.
- [x] Pruebas de límite y selección para α de 3 a 16, tres órdenes de entrega, desplazamiento de valores locales por remotos y mapas iguales con escritores concurrentes. Pruebas funcionales de deletes, TTL y sobrescrituras.

### Lecturas y concurrencia — §4.8 y §5

- [x] Consultar a todos los pares si la clave es desconocida o está desalojada; considerar estado local inicial y final.
- [x] Pedidos correlacionados con referencias; filtro de consulta existente y pares que todavía faltan. Regresiones de duplicados, referencias desconocidas y emisores ajenos.
- [x] La réplica sigue atendiendo mensajes mientras espera pares. Cada consulta se responde con información local sin iniciar otra consulta.
- [x] Pruebas de lectura remota tras desalojo, cambio mientras espera, consultas simultáneas y lecturas cruzadas sin deadlock.
- [x] Descarte de mensajes inesperados en ciclo principal e inicialización.
- [x] Informe con argumento de progreso bajo los supuestos del TP. No se promete linealizabilidad ni tolerancia a fallas.

### Restricciones — §6 y §7

- [x] Estado persistente en argumentos del ciclo de recepción.
- [x] Sin behaviours OTP, ETS, DETS, Mnesia, `persistent_term` ni diccionario del proceso.
- [x] Compilación sin advertencias, tratadas además como errores.
- [x] Una sola VM, procesos que no fallan y una invocación final de stop con todas las réplicas.

## Compilar y probar

Requiere Erlang/OTP y rebar3. Desde la raíz:

```sh
rebar3 compile
rebar3 eunit
```

**Verificación del 10/11/2026:** ambos comandos aprobados y **100/100 tests EUnit**; compilación adicional con `erlc +warn_all -Werror` aprobada. Los tests combinan API pública con pruebas internas que fuerzan órdenes concretos. No distribuir `.beam` ni `_build/`: son productos generados y pueden ocultar fuentes actuales.

| Archivo | Responsabilidad |
| --- | --- |
| `src/simple_kv.erl` | API, reducción de lectura en cliente, creación y cierre |
| `src/simple_kv_replica.erl` | Aplica eventos ordenados y atiende lecturas y ofertas |
| `src/simple_kv_coordinador.erl` | Ordena escrituras, ofertas y barreras; mantiene solo metadatos |
| `src/simple_kv_almacen.erl` | Metadatos y aplicación de versiones |
| `src/simple_kv_replicacion.erl` | Versiones, propagación, ofertas y selección de respuestas |
| `src/simple_kv_capacidad.erl` | Reserva de espacio, protección por recencia, ofertas y desalojo |
| `src/simple_kv_ttl.erl` | Cálculo y validación de vencimiento |
| `test/` | Suite EUnit, incluidas regresiones de la V5 |

## Documentación y entrega — §8

- [x] Implementación `.erl` y tests propios presentes. Hay tests internos del protocolo que complementan las pruebas por API.
- [ ] Verificar cobertura de todos los comportamientos exigidos mediante la interfaz externa; los tests internos por sí solos no la acreditan.
- [x] Informe actualizado con coordinador, tabla de mensajes y argumento de orden.
- [ ] Revisar la garantía del 75 % sobre los metadatos registrados y la cobertura integral por API pública.
- [x] PDF actualizado de cinco páginas, generado y revisado visualmente.
- [x] Compilación y suite verificadas sobre los archivos finales de la rama de trabajo.
- [x] Cuentas `jcastropizzo` y `mariancarr` con acceso al repositorio privado de trabajo; eso no verifica acceso al repositorio de la cátedra ni inscripción de cuentas.
- [ ] Confirmar que ambos integrantes figuran en el repositorio asignado y sus cuentas fueron informadas a docentes.
- [ ] Trasladar los archivos finales al repositorio de la cátedra y ejecutar allí compilación y tests.
- [ ] Hacer push de implementación, tests e informe PDF a ese repositorio antes del vencimiento y verificar su presencia remota.

Para entregar hacen falta `src/*.erl`, `test/*.erl`, la configuración rebar3 y `output/pdf/informe_tp.pdf`. Conservar `informe_tp.md` como fuente editable. `cambios_simple_kv.md` remite a estos documentos para evitar mantener descripciones duplicadas.
