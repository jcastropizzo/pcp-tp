# PCP — Almacén key-value replicado

Implementación Erlang para la [consigna V5](consigna/kv_replicado.pdf), en una VM BEAM. El [informe de diseño](output/pdf/informe_tp.pdf) explica el protocolo, los mensajes y sus supuestos; su fuente editable es [informe_tp.md](informe_tp.md).

**Entrega:** 11/11/2026 a las 23:59 mediante push al repositorio asignado por la cátedra. Este repositorio es privado de trabajo y no constituye la entrega.

## Estado y pendientes

- [x] API, replicación, TTL, borrados, capacidad, ofertas y lecturas implementados.
- [x] Informe de diseño de cinco páginas y tests propios incluidos.
- [x] Compilación estricta y 102 tests aprobados; incluye operaciones concurrentes por API y pruebas internas con intercalados controlados.
- [ ] Confirmar que ambos integrantes tienen acceso al repositorio asignado y que sus cuentas fueron informadas a docentes.
- [ ] Llevar código, tests, configuración e informe al repositorio de la cátedra; compilar y ejecutar allí los tests.
- [ ] Hacer push antes del vencimiento y verificar los archivos en el remoto de la cátedra.

Los tests verifican escenarios concretos, no todos los intercalados posibles. El informe justifica el orden de eventos y el progreso bajo los supuestos del TP; no es una demostración formal. La interpretación de la cota de capacidad respecto de valores transitorios en mensajes queda sujeta a la consigna.

## Checklist de requisitos V5

### Interfaz y replicación (§3–4.5)

- [x] `start_link/2`, `stop/1`, `put/3`, `put/4`, `delete/2` y `get/2`; claves y valores pueden ser términos Erlang.
- [x] Réplicas enlazadas al invocante; `stop/1` espera su terminación.
- [x] Escrituras y borrados propagados asincrónicamente, sin esperar aplicación en los pares.
- [x] Versiones crecientes para resolver conflictos; lápidas para evitar que una escritura antigua restaure un borrado.
- [x] La ausencia por desalojo se distingue de un borrado; una copia de igual versión puede recuperarse.
- [x] El coordinador ordena escrituras y ofertas y distribuye una decisión común de capacidad. No conserva valores de usuario en su estado.

La consistencia eventual se observa en las respuestas una vez propagados los cambios. La igualdad de mapas es una estrategia de esta implementación, no una exigencia general de la propiedad. Las operaciones pueden ver estados transitorios diferentes mientras se propagan los mensajes.

### TTL (§4.6)

- [x] `infinity` no vence y `0` vence inmediatamente; un TTL inválido produce `function_clause` en el invocante.
- [x] Las copias mantienen el vencimiento original. `get` vuelve a comprobarlo antes de responder y nunca devuelve un valor vencido.
- [x] Vencer no genera una lápida ni implica borrar físicamente la entrada.

### Capacidad y desalojo (§4.7)

- [x] Cada réplica almacena como máximo α valores; α debe ser entero mayor o igual a 3.
- [x] Una sobrescritura de una clave existente no ocupa otra plaza.
- [x] Con capacidad llena, el selector considera las entradas residentes y la entrante. Protege `Q = ceil(3α/4)` versiones mayores; entre las demás prioriza una vencida y, si no hay, la versión menor. La entrante puede ser descartada.
- [x] Una entrada protegida permanece físicamente aunque haya vencido; `get` no la devuelve. El redondeo y la conservación física son decisiones de diseño.
- [x] Antes de descartar un valor vigente, cada réplica lo ofrece a sus pares. La oferta se ordena mediante el coordinador y puede usar una vacante o reemplazar un vencido no protegido; no desaloja vigentes ni genera nuevas ofertas.

La consigna exige que «el 75 % escrito más recientemente (en el nodo local) siempre siga disponible». El selector implementa la protección sobre residentes más entrante; no reconstruye valores ya desalojados a partir de sus metadatos. Una oferta da oportunidad de conservar una copia, pero no lo garantiza: si todas las réplicas descartan una entrada elegible, puede perderse; liberar espacio después no recupera una copia perdida.

### Lecturas y concurrencia (§4.8–5)

- [x] Si una clave es desconocida o fue desalojada localmente, se consulta a los pares y se comparan versiones.
- [x] Las consultas usan referencias para asociar respuestas, descartar duplicados y seguir atendiendo otros pedidos mientras esperan.
- [x] Tests de consultas simultáneas, lecturas cruzadas, respuestas atrasadas, réplica pausada y conflictos entre escritores. Los tests por API incluyen `put` y `delete` concurrentes y lecturas con escrituras simultáneas.
- [x] El informe explica por qué las consultas no generan espera circular bajo los supuestos del TP.

### Restricciones y supuestos (§6–7)

- [x] Estado persistente en argumentos de los ciclos de recepción; sin behaviours OTP, ETS, DETS, Mnesia, `persistent_term` ni diccionario del proceso.
- [x] Compilación con advertencias tratadas como errores.
- [x] Una VM, procesos sin fallas y una llamada final a `stop/1` con todas las réplicas. No se promete tolerancia a fallas ni latencia acotada.

## Arquitectura

| Módulo | Responsabilidad |
| --- | --- |
| `simple_kv` | API, inicio y cierre, reducción de resultados de lectura en el cliente. |
| `simple_kv_replica` | Ciclo de mensajes de cada réplica y coordinación de sus operaciones. |
| `simple_kv_coordinador` | Orden común de escrituras, ofertas y barreras de lectura; decisión de capacidad. |
| `simple_kv_ordenada` | Aplicación de decisiones del coordinador y ofertas al descartar. |
| `simple_kv_consultas` | Inicio y seguimiento de consultas a pares y entrega de candidatos. |
| `simple_kv_almacen` | Valores, metadatos y resolución por versión. |
| `simple_kv_capacidad` | Selección protegida, desalojo y aceptación de ofertas. |
| `simple_kv_replicacion` | Versiones, envío a pares y elección de candidatos. |
| `simple_kv_ttl` | Cálculo y comprobación del vencimiento. |

El coordinador elige una sola víctima por operación y envía la decisión a todas las réplicas. Cada una la aplica en el mismo orden sin recalcularla con su reloj; la réplica de origen responde al cliente al aplicarla localmente. Los valores viajan en mensajes, y los metadatos no conservan su contenido.

## Compilar y probar

Se necesitan Erlang/OTP y rebar3:

```sh
rebar3 compile
rebar3 eunit
```

**Última verificación, 11/11/2026:** compilación aprobada, **102/102 tests EUnit aprobados** y `erlc +warn_all -Werror` aprobado. Las pruebas combinan API pública con tests internos que controlan órdenes de mensajes. No distribuir `.beam` ni `_build/`: son productos generados.

Para la entrega se necesitan `src/*.erl`, `test/*.erl`, la configuración de rebar3 y `output/pdf/informe_tp.pdf`. Conservar `informe_tp.md` como fuente editable.
