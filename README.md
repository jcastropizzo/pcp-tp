# PCP — TP: base de datos key-value replicada

## Estado actual

Actualizado al **domingo 25/10/2026, Buenos Aires**. El miércoles 21 se informó:
- [x] Leer la consigna.
- [x] Leer documentación de una clase de Erlang para recuperar conceptos.
- [x] Instalar Erlang CLI y rebar3.
- [ ] Crear y verificar el proyecto ejecutable.
- [ ] Implementar el primer comportamiento.
- [ ] Escribir y ejecutar tests.

Viernes 23 y sábado 24: sin estudio/avance informado. El bloque de PCP del sábado no se hizo. Falta confirmar el avance del jueves y la asistencia a ISW del viernes; no se dan por hechos.

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
| Mié 21 | Cerrado | Consigna/documentación leídas y herramientas instaladas. Sin implementación. |
| Jue 22 | Estado sin confirmar | Se había previsto ISW + lectura y merienda; no contar el estudio como realizado. |
| Vie 23 | Sin estudio informado | No había estudio extra obligatorio. Asistencia a ISW sin confirmar. |
| Sáb 24 | No realizado | Se perdió el bloque de 2 h 30 de PCP. No trasladarlo entero como carga adicional al domingo. |
| Dom 25 | PCP: 90 min, si hay disponibilidad | 20 min preparar/verificar proyecto; 55 min pedido/respuesta y put/get local; 15 min prueba reproducible y guardar. Cierre: caso local comprobado o bloqueo preciso; no exigir replicación. |
| Dom 25 | ISW: 45 min | Verificar avance del jueves/asistencia del viernes y atacar una laguna prioritaria para el teórico. Cierre: dos respuestas breves propias contrastadas con el material y pendientes explícitos. |
| Dom 25 | Cierre: 15 min | Actualizar estado real y preparar consulta concreta para PCP. Total orientativo: 2 h 30 efectivas más pausa de 10–15 min; no disponibilidad confirmada. |
| Lun 26 | Consulta durante cursada | Destrabar base local o revisar diseño de replicación si ya funciona. Confirmar fecha/modalidad del TP. Repaso ISW de 25 min solo si hay hueco real. |
| Mar 27 | Sin bloque PCP | ISW y compromisos previstos; confirmar alcance del teórico sin sumar sesión posterior. |
| Mié 28 | Consulta; hasta 60 min solo si la clase lo permite | Completar base local si falta. Solo después, primera propagación asincrónica entre dos réplicas y prueba sin conflictos. Cierre: incremento comprobado o bloqueo descrito; no fingir que todo el protocolo está resuelto. |
| Jue 29 | Sin bloque PCP obligatorio | Mantener preparación del teórico ISW (2 h orientativas), usando las lagunas reales del domingo/martes. |
| Vie 30 | 15 min, si hay hueco real | Rendir ISW; inventario de requisitos pendientes y planificación siguiente según fecha confirmada. Sin implementación pesada después de cursar. |

Si el domingo solo hay **90 min**: 60 min PCP + 25 min ISW + 5 min de cierre. Si hay menos, ajustar al tiempo real. No recuperar atrasos a costa de dormir ni asumir disponible la jornada completa.

**Hay atraso respecto del plan, pero perder el sábado no demuestra por sí solo que la entrega sea inviable. Tampoco hay evidencia para garantizar llegar.** Se retira la expectativa de tener el TP completo el 30/10. Primero hace falta un incremento ejecutable, confirmar el plazo y estimar el trabajo restante. Si rige 2/11 y no entra, decirlo y reorganizar con disponibilidad real; si rige 11/11, distribuir el resto tras el teórico con margen de entrega y sin consumir toda la preparación de PCP 16/11 e ISW 17/11.

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
