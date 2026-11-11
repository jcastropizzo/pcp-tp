# PCP — Base de datos key-value replicada

Almacén Erlang entre procesos de una misma VM BEAM. Requisitos: [consigna V5](consigna/kv_replicado.pdf). Diseño: [informe editable](informe_tp.md) · [documento final, cinco páginas](output/pdf/informe_tp.pdf).

**Entrega:** 11/11/2026 a las 23:59, mediante push al repositorio asignado por la cátedra. **Coloquio:** 18/11/2026, a coordinar con cada grupo.

## Qué hay y qué falta

Selector corregido y pruebas actualizadas. El cierre integral de convergencia sigue pendiente por los casos de borrado/TTL indicados abajo. Compilación estricta y **94 tests aprobados**, incluyendo protección por recencia frente a TTL, capacidad bajo tráfico remoto, cierre lento y consultas simultáneas.

**Pendiente de los integrantes:** confirmar cuentas informadas a docentes, llevar los archivos al repositorio asignado y verificar el push final. Este es un repositorio privado de trabajo: publicar aquí no constituye la entrega.

Los checks indican comportamiento implementado con evidencia de código/pruebas o argumento en el informe. Una suite finita no demuestra todos los intercalados concurrentes.

## Política de desalojo: recencia protegida y TTL

Fuente: [consigna V5, §§4.6–4.7](consigna/kv_replicado.pdf). Citas textuales:

> «el 75 % escrito más recientemente (en el nodo local) siempre siga disponible» (§4.7).

> «nunca se devuelve un valor vencido» (§4.6).

> «No es válido tener entradas adicionales en alguna estructura secundaria, α es el tope de valores permitidos para un nodo.» (§4.7).

**Decisión de diseño acordada:** conservar físicamente las entradas del 75 % protegido aunque estén vencidas; `get` devuelve `not_found` para ellas. El PDF no prescribe literalmente esa conservación física ni el redondeo: son la interpretación implementada. Se usa Q = ceil(3α/4), redondeando hacia arriba. La recencia se ordena por versión entre las entradas residentes y la entrante, sin cupos separados por origen. No se agrega un estado `Locales`.

### Árbol de decisión para put y replicación

1. Descartar versiones anteriores a la conocida. Una sobrescritura aceptable reemplaza su clave sin desalojar otra.
2. Si `map_size(Map) < α`, guardar la entrada, **incluso si ya venció**. Vencido no implica borrado físico ni vacante automática.
3. Si no hay espacio, considerar residentes más entrante sin construir otro mapa de valores. Proteger las Q versiones mayores, incluido el entrante si le corresponde.
4. Entre los **no protegidos**, elegir primero un vencido; si hay varios, el de menor versión. Si ninguno venció, elegir la menor versión elegible.
5. El candidato puede ser el entrante. Si sale un residente, retirarlo antes de insertar para no superar α. Antes de descartar un vigente, ofrecerlo a los pares; un vencido no se ofrece.
6. Conservar versión y estado `desalojado` al descartar. TTL no fabrica una lápida `borrado`; esa marca corresponde a `delete` explícito, que sí puede quitar una entrada protegida.

La preferencia por vencidos solo opera fuera del cupo protegido: **no es una política top-α pura cuando hay TTL**. Por ejemplo, α=4, versiones 1 vigente, 2 vencida, 3 y 4 vigentes, entrante 5: se protegen 3,4,5 y se retira 2, conservando 1.

### Ofertas y lecturas

Una oferta puede ocupar una vacante, reemplazar su clave o reutilizar un vencido no protegido mediante el mismo ranking. Nunca desaloja vigentes ni genera otros mensajes. Una oferta rechazada no limpia entradas protegidas como efecto lateral. Si se conserva una copia vencida, mantiene su vencimiento y sigue siendo invisible para `get`.

Las lecturas no quitan las entradas vencidas del mapa. La comprobación final de TTL en el cliente evita devolverlas incluso si vencieron mientras faltaban respuestas remotas.

### Verificación del criterio

Los tests citan la consigna y separan visibilidad por API de almacenamiento físico mediante consultas locales. Suite específica: `test/simple_kv_proteccion_ttl_tests.erl`.

| Caso | Resultado exigido |
| --- | --- |
| Vencido dentro de las Q recientes | Permanece en Map con metadato `valor`; get responde `not_found` |
| Vencido fuera de las Q recientes | Se prefiere antes que un vigente elegible más viejo |
| Ningún vencido elegible | Sale la menor versión no protegida |
| Entrante vencido reciente / antiguo | Se conserva si está protegido; puede descartarse si es elegible |
| α=3,4,5,7,16 | Q se redondea hacia arriba y nunca se supera α |
| Replicación, ofertas y sobrescrituras | No limpian protegidos; no renuevan TTL ni crean borrados por vencer |
| `delete` explícito | Elimina y deja lápida aunque la entrada estuviera protegida |

### Convergencia pendiente

**Convergencia significa mapas iguales**, no solo acuerdo sobre versiones. Con puts de claves distintas y TTL infinito, se conserva el mismo top-α tras recibir las mismas escrituras. Hay pruebas que comparan contenido local, sin `get/2`, que podría ocultar diferencias consultando un par.

- [x] Proteger por recencia sin excepción de origen y conservar físicamente protegidos vencidos.
- [x] Priorizar vencidos exclusivamente entre no protegidos, incluyendo al entrante.
- [ ] Cerrar convergencia con borrados, sobrescrituras y TTL. Caso comprobado, α=3: `a1,b2,c3,d4,delete(d)5` deja `{b,c}`; `delete(d)5,a1,b2,c3,d4` deja `{a,b,c}`. El selector no recupera copias descartadas cuando aparece una vacante. La preferencia por vencidos puede además depender del instante de recepción.
- [ ] Confirmar con cátedra la interpretación de «en el nodo local» frente a igualdad final de mapas: no se garantiza un cupo independiente por origen.

## Checklist de requisitos V5

### Interfaz y réplicas — §3 y §4.1

- [x] API `start_link/2`, `stop/1`, `put/3`, `put/4`, `delete/2`, `get/2`. La V5 permite extensiones.
- [x] `start_link(Count, Alfa)` crea Count réplicas independientes enlazadas al invocante. Count no entero positivo falla con `function_clause`; Alfa se valida entero ≥3.
- [x] Claves y valores admiten cualquier término; pruebas con mapas, tuplas, listas, binarios y pid.
- [x] Guardar, sobrescribir, borrar incluso una clave inexistente y leer `{ok, Value}` o `not_found`.
- [x] `put/3` equivale a TTL `infinity`. TTL inválido falla en el proceso invocante.
- [x] `stop/1` espera terminación mediante monitor, sin timeout arbitrario. Regresión con réplica demorada más de un segundo.

### Replicación, conflictos y borrados — §4.2–4.5

- [x] Puts/deletes se propagan a todos los pares sin esperar confirmaciones.
- [x] Cada escritura obtiene una versión única creciente dentro de la VM; replicaciones y ofertas la conservan.
- [x] Gana la versión mayor independientemente del orden de llegada. Pruebas con órdenes opuestos y escritores concurrentes.
- [x] Lápidas con versión impiden resurrección por puts antiguos; un delete viejo tampoco elimina un valor nuevo.
- [x] Desalojo local y borrado se distinguen en metadatos. Un desalojado se puede recuperar con una copia de igual versión.
- [ ] Completar la justificación de igualdad final de mapas incluyendo borrados, TTL y recuperación tras desalojo. El informe distingue el caso demostrado de los casos abiertos.

### TTL — §4.6

- [x] Vencimiento absoluto con reloj monotónico compartido en la VM; recibir una copia no renueva TTL.
- [x] Casos 0, `infinity`, finitos, inválidos y sobrescrituras.
- [x] Comprobación de vigencia en el cliente al finalizar get, también si un candidato remoto vence mientras faltan respuestas.
- [x] Conservación física de vencidos protegidos, incluso TTL cero; nunca son devueltos. Solo se reutilizan vencidos no protegidos al necesitar espacio.

### Capacidad y desalojo — §4.7

- [x] Capacidad α recibida al iniciar; mapa con como máximo α valores. Se reserva espacio antes de insertar.
- [x] Sin copias de valores en estructuras secundarias de las réplicas: `Pendientes` contiene solo control de consultas. La reducción de resultados se realiza en el cliente.
- [x] Proteger Q = ceil(3α/4) versiones mayores, con entrante incluido; entre el resto priorizar vencidos y luego menor versión. Sin cupos por origen.
- [x] Sobrescritura llena sin desalojar otra clave; selector por versión con varios `infinity`; capacidad receptora y duplicados.
- [x] Valores vigentes ofrecidos a todos los pares antes de descartarlos.
- [x] Ofertas con versión aceptable: usan vacante, reemplazo o vencido no protegido; nunca desalojan vigentes ni reenvían. Conservan TTL incluso si expiró en tránsito.
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

**Verificación del 10/11/2026:** ambos comandos aprobados y **94/94 tests EUnit**; compilación adicional con `erlc +warn_all -Werror` aprobada. Los tests combinan API pública con pruebas internas que fuerzan órdenes concretos. No distribuir `.beam` ni `_build/`: son productos generados y pueden ocultar fuentes actuales.

| Archivo | Responsabilidad |
| --- | --- |
| `src/simple_kv.erl` | API, reducción de lectura en cliente, creación y cierre |
| `src/simple_kv_replica.erl` | Ciclo de mensajes y control de consultas pendientes |
| `src/simple_kv_almacen.erl` | Metadatos y aplicación de versiones |
| `src/simple_kv_replicacion.erl` | Versiones, propagación, ofertas y selección de respuestas |
| `src/simple_kv_capacidad.erl` | Reserva de espacio, protección por recencia, ofertas y desalojo |
| `src/simple_kv_ttl.erl` | Cálculo y validación de vencimiento |
| `test/` | Suite EUnit, incluidas regresiones de la V5 |

## Documentación y entrega — §8

- [x] Implementación `.erl` y tests propios presentes.
- [x] Informe actualizado con estructuras y protocolo reales, tabla de mensajes y alcance de las garantías verificadas. Convergencia integral pendiente según el caso documentado.
- [x] PDF actualizado de cinco páginas, generado y revisado visualmente.
- [x] Compilación y suite verificadas sobre los archivos finales de la rama de trabajo.
- [x] Cuentas `jcastropizzo` y `mariancarr` con acceso al repositorio privado de trabajo; eso no verifica acceso al repositorio de la cátedra ni inscripción de cuentas.
- [ ] Confirmar que ambos integrantes figuran en el repositorio asignado y sus cuentas fueron informadas a docentes.
- [ ] Trasladar los archivos finales al repositorio de la cátedra y ejecutar allí compilación y tests.
- [ ] Hacer push de implementación, tests e informe PDF a ese repositorio antes del vencimiento y verificar su presencia remota.

Para entregar hacen falta `src/*.erl`, `test/*.erl`, la configuración rebar3 y `output/pdf/informe_tp.pdf`. Conservar `informe_tp.md` como fuente editable. `cambios_simple_kv.md` remite a estos documentos para evitar mantener descripciones duplicadas.
