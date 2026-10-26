# PCP — TP: base de datos key-value replicada

## Estado actual

Actualizado al cierre de la sesión del **domingo 25/10/2026, Buenos Aires**. Energía final: **alta**.

- [x] Consigna leída y herramientas Erlang CLI/rebar3 instaladas.
- [x] Primer incremento local implementado en `simple_kv`.
- [x] Seis tests EUnit aprobados y compilación con `erlc +warn_all` sin advertencias, **antes del último cambio en `start_link/1`**, según el check-in.
- [ ] Compilar y probar nuevamente el último `start_link(N)`, incluidos múltiples procesos y argumentos inválidos.
- [ ] Comprobar que `stop/1` espera la terminación efectiva de todos los procesos.
- [ ] Completar TTL, replicación y demás requisitos del TP.

### PCP: implementación y evidencia

Se implementaron `put/3`, `put/4`, `get/2` y `delete/2`, con estado en un mapa y ciclo `receive`. Los pedidos y respuestas usan referencias de `make_ref/0`. Hay un `stop/1` provisional y descarte de mensajes inesperados en el ciclo principal. Tener `put/4` no significa que la expiración de TTL esté implementada.

Los **6/6 tests aprobados antes de la última modificación** cubrieron:
1. Escritura y lectura local.
2. Lectura de clave inexistente.
3. Escritura, borrado y lectura posterior.
4. Borrado de clave inexistente.
5. Continuidad después de un mensaje desconocido.
6. TTL negativo produce `function_clause`.

La generalización final de `start_link(N)` quedó pendiente de compilación y prueba. El éxito de los seis tests anteriores **no valida ese último cambio**, la concurrencia ni los requisitos distribuidos.

**Publicación verificada por el agente de planificación:** en [`983fa40`](https://github.com/jcastropizzo/pcp-tp/commit/983fa40ccb34a6477e6359550c067aaf302f1de9) están [`src/simple_kv.erl`](src/simple_kv.erl), [`test/simple_kv_tests.erl`](test/simple_kv_tests.erl) y el cambio a `start_link(N)`. El check-in original solo informaba commits locales; la lectura de GitHub resolvió esa incertidumbre. Esta actualización documental no volvió a ejecutar compilación ni tests.

Pendientes: validar `start_link(N)` y argumentos inválidos; terminación efectiva en `stop/1`; expiración de TTL; replicación asincrónica y conflictos; prevención de resurrección; lecturas remotas sin deadlock; capacidad y desalojo; tests concurrentes y casos límite; descarte de mensajes inesperados en todos los puntos de recepción; documento de diseño de máximo cinco páginas.

### ISW: recuperación y autonomía

Se trabajaron **Idioms, introducción a patrones, Decorator, Adapter y Proxy**. Validación: **3/3 preguntas correctas, respondidas autónomamente y sin pistas**, según el check-in.

Se pudo identificar y combinar Decorator/Proxy, justificar el orden de composición, reconocer Adapter y explicar el desacoplamiento de interfaces externas, y distinguir idioms de patrones. Durante el aprendizaje hubo correcciones en Proxy/Decorator en casos ambiguos, herencia/composición y terminología de acoplamiento.

No se encontró material específico de la cátedra para contrastar las definiciones. Esto registra recuperación concreta y desempeño sobre las preguntas trabajadas; **no certifica toda la clase ni todo el alcance del parcialito**. El parcialito sigue previsto para el **30/10 a las 17:00**; falta confirmar su alcance completo.

### Tiempo y balance

| Bloque | Registro |
| --- | --- |
| Reconstrucción ISW | Aproximadamente 2 min, no cronometrados; excluidos del mínimo confirmado. |
| PCP inicial | 75 min cronometrados. |
| Recuperación ISW | 60 min cronometrados. |
| PCP: comprobación | 60 min cronometrados. |
| Validación ISW | 12 min al último control; cierre anticipado, duración final podría ser ligeramente mayor. |
| Cierre | Sin medición registrada. |

**Mínimo efectivo confirmado: 207 min (3 h 27 min)**, sin descansos ni estimaciones. No se equipara la disponibilidad de cinco horas con tiempo estudiado.

Se alcanzaron ambos objetivos de la sesión: incremento local comprobable y recuperación concreta de ISW. El TP sigue incompleto. Se conserva la planificación y **no se agregan horas compensatorias**.

Contexto previo: jueves 22 hubo algo de ISW sin identificar; viernes 23 no se asistió ni se estudió; sábado 24 no se realizó el bloque PCP. La sesión del domingo no se cuenta como recuperación automática de todos esos pendientes.

## Consigna y fecha

[Consigna original (PDF)](consigna/kv_replicado.pdf) · [Transcripción](https://github.com/jcastropizzo/pcp-material/blob/main/trabajos-practicos/tp-01-kv-replicado-erlang.transcripcion.md) · [Resumen de requisitos](https://github.com/jcastropizzo/pcp-material/blob/main/trabajos-practicos/tp-01-kv-replicado-erlang.resumen.md).

**Entrega confirmada: miércoles 11/11/2026 a las 23:59**, según el PDF y la confirmación del alumno del 25/10. Se descarta el 2/11 de la planificación anterior. Este plan usa horario de Buenos Aires. Solo queda por verificar la modalidad/canal de entrega.

Entregar implementación `.erl`, tests propios y documento de diseño de **máximo 5 páginas**. La API es fija: módulo `simple_kv`, exports `start_link/1, stop/1, put/3, put/4, delete/2, get/2`.

## Primer paso concreto

**Verificar `start_link(N)` con tests incrementales antes de avanzar a replicación.** Partir del código existente, no volver a crear el proyecto.

1. Recompilar el último cambio con `erlc +warn_all` y volver a ejecutar los seis tests.
2. Añadir comprobaciones de múltiples procesos y de argumentos inválidos.
3. Registrar resultados reales; mantener pendiente comprobar terminación efectiva en `stop/1`.

El trabajo continúa dentro de los bloques ya previstos; no se agrega una sesión por haber terminado con energía alta. Para ISW, conservar la preparación del parcialito y confirmar el alcance completo; no repetir indefinidamente las preguntas ya validadas.

No usar behaviours OTP ni una plantilla que introduzca gen_server/supervisor. El resto de las restricciones está en el checklist. Consultar teoría puntual cuando bloquee el siguiente paso.

## Plan hasta el viernes 30/10

Se conserva el plan acordado, con sus presupuestos y pausas; la ejecución real del domingo está registrada arriba. Los bloques del domingo que siguen describen lo previsto, no horas adicionales ni tareas para repetir. El resto está sujeto a disponibilidad real. El README mantiene el plan del TP; el calendario conserva tareas diarias y check-ins. Cada cierre actualiza el estado real y el siguiente paso. No recuperar atrasos acumulando automáticamente horas nocturnas.

| Día | Bloque | Objetivo y criterio de cierre |
| --- | --- | --- |
| Mié 21 | Cerrado | Consigna/documentación leídas y herramientas instaladas. Sin implementación. |
| Jue 22 | Avance parcial | Se hizo algo de ISW; contenido y resultado por identificar. |
| Vie 23 | Ausencia confirmada | No se asistió a ISW ni se estudió; recuperar material de la clase. |
| Sáb 24 | No realizado | Se perdió el bloque de 2 h 30 de PCP. No trasladarlo entero como carga adicional al domingo. |
| Dom 25 | Hasta 5 h incluyendo pausas | Seguir la secuencia detallada debajo: dos bloques PCP, dos ISW, diagnóstico y cierre. Un incremento local y comprensión comprobada de temas seleccionados; no exigir replicación. |
| Lun 26 | Consulta durante cursada | Destrabar base local o revisar diseño de replicación si ya funciona. Confirmar modalidad/canal de entrega del TP. Repaso ISW de 25 min solo si hay hueco real. |
| Mar 27 | Sin bloque PCP | ISW y compromisos previstos; confirmar alcance del teórico sin sumar sesión posterior. |
| Mié 28 | Consulta; hasta 60 min solo si la clase lo permite | Completar base local si falta. Solo después, primera propagación asincrónica entre dos réplicas y prueba sin conflictos. Cierre: incremento comprobado o bloqueo descrito; no fingir que todo el protocolo está resuelto. |
| Jue 29 | Sin bloque PCP obligatorio | Mantener preparación del teórico ISW (2 h orientativas), usando las lagunas reales del domingo/martes. |
| Vie 30 | 15 min, si hay hueco real | Rendir ISW; inventario de requisitos pendientes y planificación siguiente hacia la entrega del 11/11. Sin implementación pesada después de cursar. |

### Sesión del domingo 25 — máximo 5 horas

| Duración | Bloque | Objetivo y criterio de cierre |
| --- | --- | --- |
| 15 min | Ubicar el avance de ISW | Revisar archivos, tests, apuntes o chat del jueves y localizar el material de la clase del viernes. Cierre: una lista breve de hecho / pendiente / desconocido. Si no se reconstruye en 15 min, dejarlo como desconocido y seguir. |
| 75 min | PCP: primer incremento | Preparar/verificar proyecto mínimo, escribir un test observable y construir pedido/respuesta + put/get en una réplica. Consultar solo Erlang necesario. Cierre: código que compile y un intento ejecutable; registrar error concreto si bloquea. Sin behaviours OTP. |
| 10 min | Pausa | Levantarse y cortar pantalla. |
| 60 min | ISW: recuperar clase perdida | Calendario del viernes 23: Idioms, introducción a patrones, Decorator, Adapter y Proxy. Localizar material oficial y trabajar uno o dos puntos prioritarios según diagnóstico. Cierre: explicar problema, solución y ejemplo con tus palabras; lista explícita de lo no cubierto. El tema de clase no determina por sí solo todo el alcance del parcialito. |
| 20 min | Pausa larga | Comer o salir un rato; no contar como estudio. |
| 60 min | PCP: comprobar y completar | Retomar el mismo incremento, corregir y probar escritura/lectura y clave ausente. Solo si la base queda verde, sumar borrado o cierre de procesos. Cierre: avance guardado, comando/test reproducible, estado de la API y próxima duda de diseño. Replicación no es una obligación hoy. |
| 15 min | Pausa | Cortar antes del bloque final de ISW. |
| 30 min | ISW: prueba de comprensión | Responder tres preguntas cortas sin mirar sobre lo estudiado; después contrastar y corregir. Respuesta directa + justificación, 2–4 oraciones. Cierre: dudas concretas para el martes; no contar una lectura como dominio. |
| 15 min | Cierre | Actualizar README y check-in: código/tests que funcionan, ayuda recibida, temas de ISW comprendidos, pendientes y siguiente paso. No seguir agregando funciones. |

**Total: 4 h 15 efectivas y 45 min de pausas.** No hay horario fijo de inicio. Si baja la energía después de la pausa larga, reducir el segundo bloque PCP a 30 min, usar 10 min de pausa entre materias y conservar ISW + cierre: total 4 h 25 incluyendo descansos. Si hay saturación antes, guardar el estado real y anotar lo pendiente. No agregar tareas por haber tenido hasta cinco horas disponibles.

La clase perdida del viernes contenía, según calendario oficial, Idioms, introducción a patrones, Decorator, Adapter y Proxy. Esto orienta la recuperación; el alcance del parcialito debe confirmarse con la cátedra. El viernes 30 sigue anunciado el parcialito en los primeros 30 minutos de la clase de las 17.

**Hay atraso respecto del plan, pero perder el sábado no demuestra por sí solo que la entrega sea inviable. Tampoco hay evidencia para garantizar llegar.** Se retira la expectativa de tener el TP completo el 30/10. El primer incremento local ya se logró; resta validar la última modificación y estimar el trabajo pendiente. Con entrega confirmada el 11/11 a las 23:59, distribuir el resto tras el teórico con margen para integración, tests, documento y entrega, sin consumir toda la preparación de PCP 16/11 e ISW 17/11. No se agregan horas compensatorias.

## Secuencia de implementación restante

Orden propuesto sujeto al diseño; cada etapa requiere tests y notas para el documento, no solo código.

| Etapa | Criterio de finalización |
| --- | --- |
| Base local | API básica, validaciones, correlación de pedidos, estado en receive y cierre comprobables. |
| Replicación y versiones | Propagación asincrónica y política de conflictos que converja ante órdenes distintos. |
| Borrados y TTL | Mensajes antiguos no resucitan datos; nunca se devuelve un valor vencido; casos 0/infinity/invalidación cubiertos. |
| Lectura remota | Consulta de información ausente sin bloquear atención de otras solicitudes; pedidos simultáneos comprobados. |
| Capacidad y desalojo | Límite 16, disponibilidad de 12 claves recientes y ofrecimiento finito a otras réplicas, con interpretación confirmada. |
| Integración y entrega | Tests de cada requisito, revisión de interacciones, compilación limpia, documento completo y entrega verificada. |

Diseñar temprano la interacción entre versiones, borrados, TTL, consultas y desalojo; no tratar estas etapas como módulos independientes cuya suma garantiza corrección.

## Checklist del alcance

- [ ] API exacta y claves/valores arbitrarios de Erlang.
- [ ] Count inválido y todos los TTL inválidos fallan con function_clause; TTL falla en el invocante. Parcial: probado TTL negativo antes del último cambio; Count y demás casos pendientes.
- [ ] Procesos enlazados al invocante; stop espera terminación de todos.
- [ ] put/3 equivale a TTL infinito; delete inexistente es válido. Parcial: delete de clave inexistente probado; expiración y semántica completa de TTL pendientes.
- [ ] Replicación asincrónica de cambios y consistencia eventual.
- [ ] Política de conflictos determinista respecto del orden de recepción y justificada.
- [ ] Borrados sin resurrección por escrituras antiguas.
- [ ] TTL en milisegundos desde escritura, 0 e infinity, sin devolver vencidos.
- [ ] Máximo 16 valores por réplica y disponibilidad de las 12 claves más recientemente escritas.
- [ ] Desalojo distinto de borrado; ofrecimiento a otras réplicas; intercambio finito.
- [ ] Lectura sin información local considera otras réplicas.
- [ ] Esperas remotas no bloquean atención de pedidos; ausencia de deadlock.
- [ ] Respuestas correlacionadas y descarte de mensajes inesperados. Parcial: referencias implementadas y mensaje desconocido probado en el ciclo principal; revisar todos los puntos de recepción.
- [ ] Tests contemplan falta de orden global entre emisores.
- [ ] Sin behaviours OTP, ets/dets/mnesia/persistent_term ni diccionario de proceso.
- [ ] Estado exclusivamente en argumentos del ciclo de recepción.
- [ ] Última versión compilada sin advertencias con `erlc +warn_all`. La versión anterior al cambio final en `start_link/1` sí compiló limpia, según el check-in.
- [ ] Tests observables de todos los comportamientos, incluidos casos concurrentes.
- [ ] Documento ≤5 páginas: estado, tabla de mensajes, conflictos/borrados, vencimiento, desalojo finito y get sin deadlock.
- [x] Plazo confirmado: 11/11/2026 a las 23:59.
- [ ] Canal y recepción de entrega verificados.

Pasar tests no reemplaza justificar el diseño.

## Decisiones pendientes

- Modalidad/canal de entrega e integrantes y reparto real del trabajo.
- Interpretación de “12 claves más recientes” ante concurrencia, borrados y vencimiento.
- Compatibilidad entre convergencia y desalojos locales; tratamiento de metadatos frente al límite de valores.
- Política concreta de versiones, resolución de conflictos y retención de información sobre borrados.

## Cómo cerrar cada sesión

Actualizar checkboxes únicamente con evidencia. Registrar: comportamiento implementado, comando/test ejecutado y resultado, decisiones de diseño, bloqueo y siguiente paso. Anotar tiempo efectivo solo si fue medido. Mantener las notas de diseño junto al código para no reconstruirlas al final.
