# PCP — TP: base de datos key-value replicada

## Estado actual

Check-in del **miércoles 21/10/2026, 23:45, Buenos Aires**:
- [x] Leer la consigna.
- [x] Leer documentación de una clase de Erlang para recuperar conceptos.
- [x] Instalar Erlang CLI y rebar3.
- [ ] Crear y verificar el proyecto ejecutable.
- [ ] Implementar el primer comportamiento.
- [ ] Escribir y ejecutar tests.

No hay implementación informada. No se registró tiempo efectivo fiable. No se asume avance de otros integrantes.

## Consigna y fecha

[Original](https://github.com/jcastropizzo/pcp-material/blob/main/trabajos-practicos/tp-01-kv-replicado-erlang.pdf) · [Transcripción](https://github.com/jcastropizzo/pcp-material/blob/main/trabajos-practicos/tp-01-kv-replicado-erlang.transcripcion.md) · [Resumen de requisitos](https://github.com/jcastropizzo/pcp-material/blob/main/trabajos-practicos/tp-01-kv-replicado-erlang.resumen.md).

**El PDF indica entrega el 11/11/2026 a las 23:59.** En la planificación previa se había informado 2/11. Queda pendiente confirmar cuál rige y por qué canal se entrega. No se asume una prórroga; el PDF no explicita zona horaria. Este plan usa Buenos Aires.

Entregar implementación `.erl`, tests propios y documento de diseño de **máximo 5 páginas**. La API es fija: módulo `simple_kv`, exports `start_link/1, stop/1, put/3, put/4, delete/2, get/2`.

## Primer paso concreto

En la próxima sesión de PCP: abrir este repo, preparar una estructura mínima que compile y escribir el primer test observable para una réplica. Implementar pedido/respuesta correlacionado y put/get local con estado en argumentos de un ciclo receive. Es un incremento inicial; todavía no cumple el TP completo.

No usar behaviours OTP ni una plantilla que introduzca gen_server/supervisor. El resto de las restricciones está en el checklist. Consultar teoría puntual cuando bloquee el siguiente paso, sin convertir toda la sesión en lectura general.

## Plan hasta el viernes 30/10

Son presupuestos orientativos, no disponibilidad confirmada. El README mantiene el plan del TP; el calendario conserva tareas diarias y check-ins. Cada cierre actualiza el estado real y el siguiente paso. No recuperar atrasos acumulando automáticamente horas nocturnas.

| Día | Bloque | Objetivo y criterio de cierre |
| --- | --- | --- |
| Mié 21 | Cerrado | Consigna/documentación leídas y herramientas instaladas. Sin implementación. No agregar tareas a las 23:45. |
| Jue 22 | Sin bloque PCP | Se mantiene ISW: ejercicio + lectura, alrededor del trabajo y la merienda. |
| Vie 23 | Sin bloque PCP | Cursada ISW y cumpleaños de noche. |
| Sáb 24 | 25 min | Preparar proyecto y comprobar compilación; registrar versiones/comando que funcionó. |
| Sáb 24 | 60 min | Pedido/respuesta y put/get en una réplica; ejecución mínima observable. |
| Sáb 24 | 40 min | Test del comportamiento local; borrado/cierre solo si la base ya funciona. Revisar compilación sin advertencias. |
| Sáb 24 | 25 min | Guardar avance y esbozar estado/tabla de mensajes. Lista fiel de faltantes. Total 2 h 30 más pausa; cena y posible cine reservados. |
| Dom 25 | 90 min | Terminar base local si falta. Si está lista: diseño breve y primera propagación asincrónica entre dos réplicas; comprobar convergencia sin conflictos. |
| Dom 25 | 30 min | Inventario completo, estimación restante y preguntas para la cátedra. Además se preservan 60 min de ISW y hasta 45 min de margen por bloqueo real. |
| Lun 26 | Consulta durante cursada | Confirmar fecha/modalidad y dudas de protocolo. Sin asumir horas de programación en clase ni antes del trabajo. Repaso ISW breve solo si existe hueco real. |
| Mar 27 | Sin bloque PCP | ISW y compromisos ya previstos; no sumar sesión posterior. |
| Mié 28 | Consulta; hasta 60 min solo si la clase lo permite | Revisar conflictos/borrados y ausencia de esperas bloqueantes; si la base local sigue fallando, priorizar eso. Cambio acotado probado o bloqueo descrito. Cierre de 10 min. |
| Jue 29 | Sin bloque PCP obligatorio | Preparación del teórico de ISW. |
| Vie 30 | 15 min, si hay hueco real | Rendir ISW; registrar estado del TP y planificar el siguiente tramo según plazo confirmado. Sin implementación pesada después de cursar. |

**No hay evidencia para garantizar que todo el TP entre en estos bloques.** El objetivo del primer fin de semana es una base verificable y una estimación mejor, no declarar completo el sistema. Si rige 2/11 y el esfuerzo restante no entra, explicitarlo y reorganizar con disponibilidad real. Si rige 11/11, ubicar el resto después del teórico reservando margen antes de la entrega y tiempo para los parciales de PCP 16/11 e ISW 17/11. No se calendarizan todavía jornadas enteras de noviembre.

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
- [ ] Count inválido y TTL inválido fallan con function_clause; TTL falla en el invocante.
- [ ] Procesos enlazados al invocante; stop espera terminación de todos.
- [ ] put/3 equivale a TTL infinito; delete inexistente es válido.
- [ ] Replicación asincrónica de cambios y consistencia eventual.
- [ ] Política de conflictos determinista respecto del orden de recepción y justificada.
- [ ] Borrados sin resurrección por escrituras antiguas.
- [ ] TTL en milisegundos desde escritura, 0 e infinity, sin devolver vencidos.
- [ ] Máximo 16 valores por réplica y disponibilidad de las 12 claves más recientemente escritas.
- [ ] Desalojo distinto de borrado; ofrecimiento a otras réplicas; intercambio finito.
- [ ] Lectura sin información local considera otras réplicas.
- [ ] Esperas remotas no bloquean atención de pedidos; ausencia de deadlock.
- [ ] Respuestas correlacionadas y descarte de mensajes inesperados.
- [ ] Tests contemplan falta de orden global entre emisores.
- [ ] Sin behaviours OTP, ets/dets/mnesia/persistent_term ni diccionario de proceso.
- [ ] Estado exclusivamente en argumentos del ciclo de recepción.
- [ ] Compilación sin advertencias con `erlc +warn_all`.
- [ ] Tests observables de todos los comportamientos, incluidos casos concurrentes.
- [ ] Documento ≤5 páginas: estado, tabla de mensajes, conflictos/borrados, vencimiento, desalojo finito y get sin deadlock.
- [ ] Canal, plazo y recepción de entrega verificados.

Pasar tests no reemplaza justificar el diseño.

## Decisiones pendientes

- Fecha efectiva: 2/11 informado previamente vs 11/11 23:59 impreso.
- Modalidad/canal de entrega e integrantes y reparto real del trabajo.
- Interpretación de “12 claves más recientes” ante concurrencia, borrados y vencimiento.
- Compatibilidad entre convergencia y desalojos locales; tratamiento de metadatos frente al límite de valores.
- Política concreta de versiones, resolución de conflictos y retención de información sobre borrados.

## Cómo cerrar cada sesión

Actualizar checkboxes únicamente con evidencia. Registrar: comportamiento implementado, comando/test ejecutado y resultado, decisiones de diseño, bloqueo y siguiente paso. Anotar tiempo efectivo solo si fue medido. Mantener las notas de diseño junto al código para no reconstruirlas al final.
