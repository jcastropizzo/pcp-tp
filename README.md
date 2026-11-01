# PCP — TP: base de datos key-value replicada

## Estado actual

Cierre del **jueves 29/10/2026, Buenos Aires**. Energía final: **media-alta**. Check-in reportado por el tutor y aportado por el alumno; planificación no reejecutó las evaluaciones.

La sesión del jueves fue de ISW. No se reportan cambios de PCP ni pruebas nuevas; se conserva la evidencia técnica del lunes. No se agregan horas compensatorias.

### PCP: avance y nivel de evidencia

- [x] Incremento local con put/get/delete, mapa, receive y referencias de pedidos (trabajado el domingo).
- [x] `start_link(N)` recompilado y probado: tres procesos, cantidad, PIDs distintos y vivos; `function_clause` para `-1`, `0` y `1.0`.
- [x] Cambio local de `stop/1`: monitor creado antes de enviar stop, espera de `DOWN` y eliminación de la confirmación redundante de la réplica.
- [ ] Revisar la decisión de timeout de un segundo por PID y probar su camino de error.
- [ ] TTL, replicación y demás requisitos del TP.

**Evidencia completa disponible de la sesión del lunes:** salida de compilación sin advertencias y EUnit **11/11 antes de modificar stop/1**. Para la versión final de stop y sus tests, el alumno informó que pasan todos, pero no pegó una nueva salida completa. No se informaron modificaciones posteriores a esa ejecución. El test final comprueba que los procesos estén muertos inmediatamente al retornar stop, sin espera adicional en el test.

El timeout de un segundo por PID lanza `error(timeout)`: es una decisión de implementación, **no un requisito de la consigna**, y ese camino no fue probado. No marcar el cierre como completamente validado ni confundir estos tests con corrección concurrente general.

Se trabajó con código local pegado por el alumno; **no se comprobó igualdad de esta versión con GitHub**. La publicación del código del domingo sí se había verificado en `983fa40`; eso no acredita publicación de los cambios del lunes. El agente de planificación registra el check-in y no ejecutó nuevamente las pruebas.

Ayuda recibida: length, usort, funciones anónimas, tuplas, all, monitores, receive/after y error. Se distinguió confirmación de recepción de terminación efectiva. Aportes autónomos: comparar longitudes luego de eliminar duplicados y simplificar el cierre eliminando el acuse redundante.

No se inició replicación. Siguen pendientes expiración de TTL, conflictos, borrados sin resurrección, lecturas remotas sin deadlock, capacidad/desalojo, tests concurrentes y de bordes, revisión de mensajes inesperados en todos los puntos de recepción y documento de diseño ≤5 páginas.

### ISW: avance y autonomía

El domingo se trabajaron Idioms, patrones, Decorator, Adapter y Proxy, con **3/3 preguntas autónomas**. No se encontró material específico de cátedra para contrastar esas definiciones.

El lunes se trabajaron **Method Lookup, self, super, recursión y búsqueda fallida**, como preparación de cursada. **Su inclusión en el parcialito no está confirmada**; el alcance encontrado en el repositorio correspondía al primer parcial.

Fuente técnica utilizada en la sesión: [The Cuis-Smalltalk Book — Pseudo-variables](https://drcuis.github.io/TheCuisBook/Pseudo_002dvariables.html).

Dificultades iniciales: confundir la clase que define el método con el receptor y ubicar el inicio de super desde la clase del receptor. Después se resolvieron métodos heredados, envíos a otro objeto y ciclos recursivos. Evaluación final **2/2 correcta, con recorridos justificados y sin pistas**: `'E-base-intermedio'` y `40`.

Precisiones a consolidar: super conserva el receptor y cambia dónde empieza la búsqueda; no “es la superclase”. `doesNotUnderstand:` es un mensaje enviado, no el valor devuelto. No repetir indefinidamente ejercicios equivalentes ya superados.

El miércoles se trabajó **Visitor** con el [capítulo de Design Patterns alojado en MIT](https://people.csail.mit.edu/addy/pattern/pat5k.htm), elegido por el alumno como fuente externa al no encontrar material específico en el repo ISW. Se abordaron separación de operaciones, participantes, aceptar/visitas específicas, double dispatch, recorrido, encapsulamiento y costos de agregar operaciones frente a tipos. Ejemplo: documento con Texto, Imagen y Tabla; visitantes de estadísticas y HTML. También se revisó Decorator frente a métodos por combinación.

Autonomía: propuso separar la operación y usar double dispatch, escribió `Texto » aceptar:`, explicó extensiones, propuso el recorrido del documento y reconstruyó mensajes. Corrigió un error de copia en visitarImagen. Necesitó preguntas orientadoras para explicar propósito y conveniencia; se precisó que no hace falta una superclase común y que agregar tipos requiere revisar visitantes.

**Validación final del miércoles: 3/3 sin pistas.** Reconoció que visitar: self no despacha automáticamente por tipo del argumento; compuso cliente → Proxy de acceso → Adapter → biblioteca; resolvió 15 con self/super. El tutor completó la explicación de lookup y explicitó responsabilidades: no atribuir esas ampliaciones a producción autónoma. Pendiente verbal: decir “la búsqueda comienza en X”, conservando receptor, en lugar de “super es X”.

### ISW: check-in del jueves 29/10

**Alcance docente según fuentes consultadas por el tutor:** Alan Kay confirmado para el viernes; Fail Fast excluido y Pattern Abuser asignado al recuperatorio. Las conclusiones de *Cultures* se dieron el 20/10: eso confirma su tratamiento en cursada, no por sí solo su inclusión en el examen. Sigue sin temario completo confirmado. Visitor, Active Variables y Farley estudiados preventivamente; Observer y Composite validados por su relación con ejercicios de cursada.

Fuentes reportadas: calendario oficial, mails docentes, Alan Kay completo y apartados 7.7–7.8 de *Cultures* aportados por el alumno, PDF de Active Variables y traducción de Farley. El agente de planificación registra este reporte sin atribuirse verificación independiente de esas fuentes.

- **Active Variables:** mecanismo, sincronización, ciclos y transparencia comprendidos. Corrección necesaria: las excepciones no revierten una asignación; validación posterior correcta.
- **Kay:** buena comprensión de formación versus mercado y contrastación empírica; ayuda para distinguir experimentación de inducción matemática.
- **Cultures:** marco general y 7.7–7.8 trabajados; capítulo de conclusiones parcialmente cubierto. Ayuda en intercambio activo entre culturas, límites de la especificación formal y modificación por usuarios comunes.
- **Farley, capítulos 1–3:** autonomía en control de variables, acoplamiento y aprendizaje; ayuda en incremento versus publicación, causalidad y calidad técnica versus utilidad.
- **Simulacro:** tres respuestas autónomas conceptualmente correctas, con algunas justificaciones explícitas faltantes. No acredita cobertura completa del examen.
- **Method lookup/self/super:** caso nuevo autónomo correcto; receptor conservado y comienzo de búsqueda bien identificados. La precisión pendiente anterior quedó validada en este caso.
- **Composite:** propósito precisado con ayuda; extensión mediante protocolo común validada después.
- **Observer:** colaboración, nuevos suscriptores y desuscripción autónomos.

Próximo foco: respuestas breves con **concepto + justificación concreta**; no todas las distinciones corregidas tuvieron validación diferida. Sin reiniciar temas ya validados.

**Examen viernes 30/10, 17:00–17:30**, presencial en aula habitual, DNI y birome, sin dispositivos: reportado confirmado por calendario y recordatorio docente del 29/10. Número de aula pendiente de revalidar.

**Consulta de corrección práctica:** descartada por decisión del alumno. Asunto cerrado; no mantener recordatorios de consulta. Primer parcial: teórica A y práctica 6,13, confirmado por mail del 27/10.

### Tiempo y balance

- Jueves: disponibilidad confirmada de 3 h incluyendo pausas; bloques de 35, 30 y 25 min reportados completos, pausa de 10 min confirmada y comida intermedia. Otros temporizadores/interrupciones no identificados con precisión; distracciones y película de fondo. **Sin total efectivo fiable**: no registrar las 3 h ni la suma de bloques como tiempo efectivo medido. Energía final media-alta.

- Miércoles: plan de 150 min recortado por interrupciones y menor disponibilidad. **Tiempo efectivo no determinable**: hubo estimación de ~30 min y un temporizador, pero no medición fiable sin interrupciones. Los 15 min disponibles antes de validar y 10 al cierre no son una medición independiente. No registrar 140 ni 150 min como realizados.

- Domingo: mínimo registrado **207 min efectivos**, con energía final alta.
- Lunes PCP: **aproximadamente 50 min**, desglosados en 35 medidos y 15 estimados.
- Lunes ISW: **30 min medidos** hasta iniciar cierre, según temporizador de 45 con 15 restantes.
- Lunes: **65 min medidos + 15 estimados**, aproximadamente 80 min de trabajo registrado. Cierre no medido; comida excluida y pausa breve sin duración confirmada. No registrar las dos horas previstas como ejecutadas.

Ausencia a la teórica de PCP del lunes confirmada; su contenido sigue sin identificar. El trabajo del TP no la recupera automáticamente. Se conserva la planificación, sin horas compensatorias.

## Consigna y fecha

[Consigna original (PDF)](consigna/kv_replicado.pdf) · [Transcripción](https://github.com/jcastropizzo/pcp-material/blob/main/trabajos-practicos/tp-01-kv-replicado-erlang.transcripcion.md) · [Resumen de requisitos](https://github.com/jcastropizzo/pcp-material/blob/main/trabajos-practicos/tp-01-kv-replicado-erlang.resumen.md).

**Entrega confirmada: miércoles 11/11/2026 a las 23:59**, según el PDF y la confirmación del alumno del 25/10. Se descarta el 2/11 de la planificación anterior. Este plan usa horario de Buenos Aires. Solo queda por verificar la modalidad/canal de entrega.

Entregar implementación `.erl`, tests propios y documento de diseño de **máximo 5 páginas**. La API es fija: módulo `simple_kv`, exports `start_link/1, stop/1, put/3, put/4, delete/2, get/2`.

## Primer paso concreto

**ISW:** rendir el viernes 30/10 a las 17:00. Revalidar número de aula. Solo con disponibilidad real, repaso breve de concepto + justificación y distinciones corregidas; conclusiones de Cultures parcialmente cubiertas. No imponer otra sesión pesada.

**PCP:** partir de la versión local final del lunes. Conservar/identificar esa versión y registrar la salida de la suite al retomar; después abordar incrementalmente **TTL 0 y expiración positiva**, según la consigna. Mantener el timeout de stop como decisión pendiente de revisión, sin considerar el cierre definitivamente validado. No reiniciar el proyecto ni repetir toda la validación de start_link como si no se hubiera hecho.

No agregar bloques por el tiempo no consumido. El tutor prepara el check-in; el agente de planificación actualiza README y calendario.

## Sesión del lunes 26/10 — dos horas disponibles

Ausencia a PCP informada por obligaciones personales. El calendario identifica la clase como «Teórica», sin tema concreto: contenido por identificar; trabajar en el TP no cuenta como recuperar esa clase. Sesión **cerrada**; resultados y tiempos reales arriba. La tabla siguiente conserva el plan original, no tareas pendientes de repetir.

| Duración | Objetivo | Criterio de cierre |
| --- | --- | --- |
| 50 min PCP | Recompilar y ejecutar los seis tests; validar `start_link(N)` con múltiples procesos y argumentos inválidos. Si sobra tiempo, empezar a comprobar terminación en `stop/1`. | Resultados reales guardados o bloqueo reproducible. Sin exigir replicación. |
| 10 min | Pausa. | Descanso fuera del bloque efectivo. |
| 50 min ISW | Máximo 10 min para ubicar alcance del parcialito y elegir un pendiente. Si no se confirma, 30 min de Method Lookup y `super` como preparación para la clase del martes, sin asumir que entren en el examen. Últimos 10 min: dos ejercicios/respuestas sin ayuda y corrección. | Tema y fuente identificados, producción propia y dudas concretas. No repetir indefinidamente patrones ya validados. |
| 10 min | Cierre y check-in. | Evidencia, ayuda, tiempos medidos, bloqueos y próximo paso. |

**Total: 110 min efectivos + 10 min de pausa.** Esta disponibilidad reemplaza la consulta en clase y el repaso opcional del lunes; no añade horas compensatorias. El resto de la planificación se conserva. El tutor prepara el check-in; el agente de planificación mantiene el README y calendario.

## Plan hasta el viernes 30/10

Se conserva el plan acordado, con sus presupuestos y pausas; la ejecución real del domingo está registrada arriba. Los bloques del domingo que siguen describen lo previsto, no horas adicionales ni tareas para repetir. El resto está sujeto a disponibilidad real. El README mantiene el plan del TP; el calendario conserva tareas diarias y check-ins. Cada cierre actualiza el estado real y el siguiente paso. No recuperar atrasos acumulando automáticamente horas nocturnas.

| Día | Bloque | Objetivo y criterio de cierre |
| --- | --- | --- |
| Mié 21 | Cerrado | Consigna/documentación leídas y herramientas instaladas. Sin implementación. |
| Jue 22 | Avance parcial | Se hizo algo de ISW; contenido y resultado por identificar. |
| Vie 23 | Ausencia confirmada | No se asistió a ISW ni se estudió; recuperar material de la clase. |
| Sáb 24 | No realizado | Se perdió el bloque de 2 h 30 de PCP. No trasladarlo entero como carga adicional al domingo. |
| Dom 25 | Hasta 5 h incluyendo pausas | Seguir la secuencia detallada debajo: dos bloques PCP, dos ISW, diagnóstico y cierre. Un incremento local y comprensión comprobada de temas seleccionados; no exigir replicación. |
| Lun 26 | Ausencia; sesión de 2 h | Sesión detallada arriba: 50 min PCP + 10 pausa + 50 ISW + 10 cierre. Sustituye consultas previstas en clase; la teórica perdida queda pendiente de identificar. |
| Mar 27 | Sin estudio | Informado por el alumno. Asistencia a cursada sin confirmar; alcance del parcialito no resuelto. |
| Mié 28 | Sesión cerrada; plan de 150 min recortado | Visitor trabajado y validación ISW 3/3 sin pistas; tiempo efectivo desconocido. PCP no realizado, TTL pendiente. No trasladar automáticamente el bloque omitido. |
| Jue 29 | Sesión ISW cerrada; 3 h disponibles | Check-in arriba: simulacro 3 respuestas autónomas correctas con justificaciones incompletas; nuevas distinciones trabajadas, total efectivo desconocido. Energía media-alta. Sin bloque PCP obligatorio. |
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

**Hay atraso respecto del plan, pero perder el sábado no demuestra por sí solo que la entrega sea inviable. Tampoco hay evidencia para garantizar llegar.** Se retira la expectativa de tener el TP completo el 30/10. El primer incremento local ya se logró; resta abordar TTL y los requisitos distribuidos, revisar el timeout de cierre y estimar el trabajo pendiente. Con entrega confirmada el 11/11 a las 23:59, distribuir el resto tras el teórico con margen para integración, tests, documento y entrega, sin consumir toda la preparación de PCP 16/11 e ISW 17/11. No se agregan horas compensatorias.

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
- [ ] Count inválido y todos los TTL inválidos fallan con function_clause; TTL falla en el invocante. Parcial: TTL negativo probado previamente; Count -1, 0 y 1.0 probados el lunes. Resto de entradas inválidas pendiente.
- [ ] Procesos enlazados al invocante; stop espera terminación de todos. Parcial: cierre con monitor/DOWN y test de muerte inmediata informados aprobados; timeout de un segundo por PID sin probar ni justificar como decisión final.
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
- [ ] Última versión compilada sin advertencias con `erlc +warn_all`. Hay salida completa limpia con start_link(N), antes del cambio de stop. Para la versión final se informó aprobación de tests sin nueva salida completa.
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
