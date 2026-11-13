# PCP · Base de datos key-value replicada en Erlang

[Consigna V5](consigna/kv_replicado.pdf) · [Informe de diseño](output/pdf/informe_tp.pdf) · [Fuente del informe](informe_tp.md)

**Entrega** el 11/11/2026 a las 23:59 mediante push al repositorio asignado por la cátedra, con ambos integrantes registrados. El coloquio figura para el 18/11, a acordar con cada grupo.

## Requisitos y estado

| Consigna | Estado | Evidencia |
| --- | --- | --- |
| §§2–3, 4.1 · API y arranque | **Implementado y verificado** | `simple_kv` exporta `start_link/2`, `stop/1`, `put/3`, `put/4`, `delete/2` y `get/2`. Valida `Count` y admite α configurable desde 3. Hay pruebas de enlaces, parámetros inválidos y términos compuestos. [API](src/simple_kv.erl) · [Tests](test/simple_kv_tests.erl) |
| §§3, 7 · Cierre | **Implementado y verificado** | `stop/1` monitorea y espera la terminación de cada réplica. El test demora una réplica más de un segundo y exige `ok` con todos los pids terminados. [Test](test/simple_kv_tests.erl#L95) |
| §§4.2–4.5, 5.3 · Replicación asincrónica, conflictos y borrados | **Implementado y verificado** | Envío directo a todos los pares y orden total de versiones en una BEAM. Los tests cubren escrituras concurrentes, órdenes opuestos, un `put` anterior al borrado y un borrado anterior a la escritura. [Versiones](src/simple_kv_replicacion.erl) · [Tests](test/simple_kv_replicacion_tests.erl) |
| §4.6 · TTL | **Implementado y verificado** | Se valida en el invocante y se propaga el vencimiento original. Se controla al devolver el resultado, también si vence durante una consulta. [Reloj](src/simple_kv_ttl.erl) · [TTL](test/simple_kv_ttl_tests.erl) · [Consultas](test/simple_kv_consultas_tests.erl) |
| §4.7 · Capacidad y protección del 75 % | **Implementado y verificado bajo la interpretación documentada** | El mapa tiene como máximo α plazas. Se protege `ceil(3 × α / 4)` de las últimas escrituras conocidas por clave, incluidas las remotas. Un vencido protegido conserva su plaza hasta salir del grupo y un borrado libera la plaza. Entre los elegibles se toma primero un vencido y luego el más antiguo si todos siguen vigentes. [Capacidad](src/simple_kv_capacidad.erl) · [Frontera, TTL y borrado](test/simple_kv_capacidad_tests.erl) |
| §4.7 · Ofertas y terminación | **Implementado y verificado** | Se ofrece cada víctima vigente. El receptor puede usar una plaza libre, la de la misma clave o la de un vencido elegible. Al procesar una oferta no se emiten otras. [Implementación](src/simple_kv_capacidad.erl) · [Tests](test/simple_kv_desalojo_tests.erl) |
| §§4.3, 4.8 · Lecturas y convergencia observable | **Implementado y verificado en los casos de prueba** | Un `get` sin copia ni borrado local consulta a los pares y usa la mayor versión. Con un par demorado se probó que ambos responden el valor correcto aunque solo uno lo conserve. El informe justifica la convergencia tras la propagación. [Lecturas](src/simple_kv_replica.erl) · [Tests](test/simple_kv_consultas_tests.erl) |
| §§5.1–5.2 · Correlación y ausencia de deadlock | **Implementado y verificado para el protocolo válido** | Referencias por pedido y consulta, una respuesta por par y descarte de mensajes inesperados. Las réplicas contestan consultas mientras otras están pendientes. [Tests](test/simple_kv_consultas_tests.erl) |
| §6 · Restricciones y compilación | **Implementado y verificado** | Estado en argumentos del ciclo, sin dependencias de behaviours ni almacenamiento externo. El nombre de `src/simple_kv_ttl.erl` coincide con el del módulo. |
| §8 · Tests propios e informe de hasta cinco páginas | **Implementado y verificado** | La suite incluye escenarios por API y pruebas controladas del protocolo. El PDF tiene cuatro páginas e incluye la tabla de mensajes, los argumentos de corrección y ejemplos de lectura y desalojo. |

## Alcance de las decisiones

- **Recencia.** Se ordena por versión de escritura conocida en cada réplica. Una escritura borrada puede seguir contando en el ranking histórico, con la plaza liberada. El alcance y el redondeo son decisiones de diseño donde la V5 deja margen de interpretación.
- **Lecturas pendientes.** El tope α se aplica a las plazas de almacenamiento. `Pendientes` retiene un candidato transitorio por lectura y lo elimina al responder. Si se contaran también esos candidatos del protocolo, podría haber más de α valores referenciados mientras llegan respuestas.
- **Convergencia.** Se compara el resultado de `get/2` tras propagar los cambios. Una réplica sin copia puede consultar a otra. Si todos descartaron una entrada, la liberación posterior de una plaza no repone una copia que ya se perdió.

## Verificación

```sh
rebar3 compile
rebar3 eunit
```

**Resultado observado en una copia limpia de la versión de cierre:** 83/83 tests EUnit y compilación sin advertencias.

La compilación directa se verifica con `erlc +warn_all -Werror -o <directorio-temporal> src/*.erl test/*.erl`. Se asume una sola BEAM, procesos vivos y un único `stop/1` al final con todos los pids devueltos por `start_link/2`.
