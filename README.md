# PCP — TP: base de datos key-value replicada

Este README contiene exclusivamente información de PCP y su TP. La planificación general y otras materias se mantienen fuera de este repositorio.

## Estado actual — cierre de sesión iniciada el 1/11/2026

Check-in reportado por alumno/tutor con continuidad posterior. Planificación leyó el log de cierre y comprobó HEAD y estado Git; no reejecutó pruebas ni auditó la implementación completa.

Se recuperó la base local y se incorporaron TTL, versiones, replicación asincrónica y borrados con metadatos, partiendo del aporte del compañero y con guía del tutor. Se implementaron consultas remotas sin espera bloqueante dentro del ciclo, representación explícita de valores desalojados y recuperación de igual versión. Capacidad iniciada: selector, desalojo local y manejo de valores replicados con límite de almacenamiento. Esto no acredita cumplimiento completo ni corrección concurrente general.

Se configuró rebar3 y se separaron módulos/tests. Comando habitual: `rebar3 eunit`.

## Evidencia y versión

- Repo local: `/Users/howdytest/playground/pcp-tp`.
- HEAD comprobado: `c8bc08c50171b163dcc6c45ffa8e48593e7681ae`.
- Cambios preparados respecto de HEAD: `src/simple_kv_almacen.erl`, `src/simple_kv_replica.erl`, `test/simple_kv_almacen_tests.erl`.
- Log local: `/Users/howdytest/Documents/ChatGPT/planificacion/pcp-cierre-sesion-01.log`: comandos, salida completa, Git y huellas de archivos. Su marca UTC corresponde al 2/11 a las 23:50 de Buenos Aires; no mide duración de estudio.
- Log leído por planificación: compilación `erlc +warn_all -Werror -o /private/tmp/pcp-cierre-Cnlbjf src/*.erl test/*.erl`, código 0; EUnit de seis módulos, **38/38 aprobados**, código 0. Esta ejecución usó `erl -noshell`; no confundirla con una nueva ejecución observada de `rebar3 eunit`.
- Igualdad de la implementación local con GitHub no verificada. Este cambio de README no publica el código local.

La evidencia previa de 11 tests queda superada por esta suite de cierre. No dar por resuelto el timeout propio de stop ni su camino de error sin comprobar su estado actual.

## Decisiones y participación

Separar valores y metadatos; estados `valor`, `borrado` y `desalojado`; conservar versión al desalojar; recuperar un valor desalojado de igual versión; capacidad máxima declarada como constante.

Julián propuso separar metadatos, razonó sobre TTL y referencias de expiración, escribió tests y realizó cambios incrementales. Hubo ayuda sustancial con código, patrones Erlang, alcance de variables y diseño. El tutor implementó configuración, refactorización, tests, comentarios, `es_mensaje_nuevo/3` y rama de valores replicados. No atribuir esos cambios a producción autónoma; no hay validación autónoma global del diseño.

## Próximo paso con tutor

**Probar el selector con dos valores infinity y versiones en orden contrario al de las claves.** Cierre: test reproducible, corrección únicamente de ese caso si falla y regresión guardada. Después elegir el siguiente incremento; sin ampliar capacidad antes de cerrar ese caso.

No hay bloque futuro confirmado. Se expresó intención de retomar “mañana”, sin fecha absoluta, horario ni cantidad de horas confirmados.

## Pendientes prioritarios

- Oportunidad de conservación en otros pares antes de descartar valores vigentes, sin cadenas infinitas.
- Sobrescritura con capacidad llena.
- Selector con varios valores infinity.
- Pruebas permanentes de capacidad receptora y lectura remota tras desalojo.
- Mensajes fuera de orden, conflictos concurrentes y consultas simultáneas.
- Integración de TTL, versiones, borrados, recuperación y capacidad; justificar diseño, no solo tests.
- Documento de diseño ≤5 páginas.
- Verificar canal de entrega, código publicado y recepción final.
- Teórica PCP del lunes 26/10 perdida: contenido por identificar; hacer TP no la recupera.

## Tiempo

Sin cronometraje fiable ni estimación final confirmada. Pausa de 10 minutos reportada; otras interrupciones no registradas. Última energía reportada alta; energía final desconocida. Las 5 h iniciales eran disponibilidad, no trabajo realizado. Tiempos de tests no equivalen a estudio. Sin horas compensatorias.

## Consigna y fecha

[Consigna original (PDF)](consigna/kv_replicado.pdf) · [Transcripción](https://github.com/jcastropizzo/pcp-material/blob/main/trabajos-practicos/tp-01-kv-replicado-erlang.transcripcion.md) · [Resumen de requisitos](https://github.com/jcastropizzo/pcp-material/blob/main/trabajos-practicos/tp-01-kv-replicado-erlang.resumen.md).

**Entrega confirmada: miércoles 11/11/2026 a las 23:59**, según el PDF y la confirmación del alumno del 25/10. Se descarta el 2/11 de la planificación anterior. Este plan usa horario de Buenos Aires. Solo queda por verificar la modalidad/canal de entrega.

Entregar implementación `.erl`, tests propios y documento de diseño de **máximo 5 páginas**. La API es fija: módulo `simple_kv`, exports `start_link/1, stop/1, put/3, put/4, delete/2, get/2`.

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

## Revisión final pendiente

Contrastar con la consigna: API exacta; validación de Count/TTL en invocante; enlaces y terminación de procesos; TTL 0/infinity y sobrescrituras; replicación y convergencia; borrados sin resurrección; capacidad 16 y disponibilidad de 12 claves recientes; ofrecimiento finito; lectura remota sin deadlock; correlación y mensajes inesperados; restricciones de herramientas y estado; concurrencia y bordes. No marcar todo como cumplido por tener 38 tests verdes.

## Decisiones abiertas

Canal de entrega y reparto con compañero; interpretación de las 12 claves recientes ante concurrencia/borrados/vencimiento; retención de metadatos y borrados; interacción entre convergencia y desalojos. Registrar lo resuelto con evidencia al avanzar.

## Cierre de cada sesión

Entregar al planificador un check-in con versión, comandos/salidas, comportamiento, decisiones, bloqueos, ayuda/autonomía, tiempos medidos/estimados y siguiente paso. Confirmar disponibilidad antes de asignar nuevos bloques.
