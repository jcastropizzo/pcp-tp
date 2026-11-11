# PCP — Base de datos key-value replicada

Almacén Erlang entre procesos de una misma VM BEAM. Requisitos: [consigna V5](consigna/kv_replicado.pdf). Diseño: [informe editable](informe_tp.md) · [documento final, cinco páginas](output/pdf/informe_tp.pdf).

**Entrega:** 11/11/2026 a las 23:59, mediante push al repositorio asignado por la cátedra. **Coloquio:** 18/11/2026, a coordinar con cada grupo.

## Qué hay y qué falta

Implementación, tests y documento de diseño preparados. Compilación estricta y **76 tests aprobados**, incluyendo capacidad bajo tráfico remoto, protección local, cierre lento y consultas simultáneas.

**Pendiente de los integrantes:** confirmar cuentas informadas a docentes, llevar los archivos al repositorio asignado y verificar el push final. Este es un repositorio privado de trabajo: publicar aquí no constituye la entrega.

Los checks indican comportamiento implementado con evidencia de código/pruebas o argumento en el informe. Una suite finita no demuestra todos los intercalados concurrentes.

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
- [x] Informe con justificación de convergencia lógica, diferenciada de la distribución física de copias permitida por el desalojo.

### TTL — §4.6

- [x] Vencimiento absoluto con reloj monotónico compartido en la VM; recibir una copia no renueva TTL.
- [x] Casos 0, `infinity`, finitos, inválidos y sobrescrituras.
- [x] Comprobación de vigencia en el cliente al finalizar get, también si un candidato remoto vence mientras faltan respuestas.
- [x] Limpieza de vencidos con conservación de versión; TTL cero con capacidad llena no desaloja otra clave vigente.

### Capacidad y desalojo — §4.7

- [x] Capacidad α recibida al iniciar; mapa con como máximo α valores. Se reserva espacio antes de insertar.
- [x] Sin copias de valores en estructuras secundarias de las réplicas: `Locales` contiene claves/versiones y `Pendientes` solo control de consultas. La reducción de resultados se realiza en el cliente.
- [x] Protección de Q = ceil(3α/4) últimas claves distintas escritas localmente, mientras sus versiones sigan vigentes y no sean reemplazadas/borradas. Redondeo hacia arriba para conservar al menos el 75 %.
- [x] Tráfico de otras claves remotas no desaloja esas versiones protegidas; puede descartarse el valor entrante si no hay candidato elegible.
- [x] Sobrescritura llena sin desalojar otra clave; selector por versión con varios `infinity`; capacidad receptora y duplicados.
- [x] Valores vigentes ofrecidos a todos los pares antes de descartarlos.
- [x] Ofertas aceptadas solo con espacio o reemplazo, vigencia y versión aceptable. No desalojan ni reenvían: intercambio finito.
- [x] Pruebas de cupo y límite para α de 3 a 16, escritores en dos nodos, tráfico remoto, deletes, TTL y sobrescrituras. Argumento de invariantes en el informe.

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

**Verificación del 10/11/2026:** ambos comandos aprobados y **76/76 tests EUnit**; compilación adicional con `erlc +warn_all -Werror` aprobada. Los tests combinan API pública con pruebas internas que fuerzan órdenes concretos. No distribuir `.beam` ni `_build/`: son productos generados y pueden ocultar fuentes actuales.

| Archivo | Responsabilidad |
| --- | --- |
| `src/simple_kv.erl` | API, reducción de lectura en cliente, creación y cierre |
| `src/simple_kv_replica.erl` | Ciclo de mensajes y control de consultas pendientes |
| `src/simple_kv_almacen.erl` | Metadatos y aplicación de versiones |
| `src/simple_kv_replicacion.erl` | Versiones, propagación, ofertas y selección de respuestas |
| `src/simple_kv_capacidad.erl` | Reserva de espacio, cupo local, ofertas y desalojo |
| `src/simple_kv_ttl.erl` | Cálculo y validación de vencimiento |
| `test/` | Suite EUnit, incluidas regresiones de la V5 |

## Documentación y entrega — §8

- [x] Implementación `.erl` y tests propios presentes.
- [x] Informe alineado con estructuras y protocolo reales, con tabla de mensajes, conflictos/borrados, TTL, capacidad y get sin deadlock.
- [x] PDF final de cinco páginas, generado y revisado visualmente.
- [x] Compilación y suite verificadas sobre los archivos finales de la rama de trabajo.
- [x] Cuentas `jcastropizzo` y `mariancarr` con acceso al repositorio privado de trabajo; eso no verifica acceso al repositorio de la cátedra ni inscripción de cuentas.
- [ ] Confirmar que ambos integrantes figuran en el repositorio asignado y sus cuentas fueron informadas a docentes.
- [ ] Trasladar los archivos finales al repositorio de la cátedra y ejecutar allí compilación y tests.
- [ ] Hacer push de implementación, tests e informe PDF a ese repositorio antes del vencimiento y verificar su presencia remota.

Para entregar hacen falta `src/*.erl`, `test/*.erl`, la configuración rebar3 y `output/pdf/informe_tp.pdf`. Conservar `informe_tp.md` como fuente editable. `cambios_simple_kv.md` remite a estos documentos para evitar mantener descripciones duplicadas.
