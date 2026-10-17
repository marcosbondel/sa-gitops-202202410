# Defectos de `verificar_p10.sh` v1.0 — para el auxiliar

**Script:** `verificar_p10.sh` v1.0, sha256
`0f423f0112af77678177bc461dd035b065783e0136bffa3a5b35143ef30616f3`, sin
modificar, en `P10/scripts/`.
**Copia corregida:** `P10/scripts/verificar_p10_corregido.sh`, con solo las
correcciones de abajo (sus 35 líneas de diferencia son esas y un comentario).

| Ejecución sobre el mismo clúster | 2.1 | 2.2 | 2.3 | 2.4 | 2.5 | Total | Eliminatorios |
|---|---|---|---|---|---|---|---|
| Original | 11 – 14 | 11 | 2 | 10 | 8 | **42 – 45 / 60** | `analisis-sin-prometheus` |
| Copia corregida | 14 | 16 | 12 | 10 | 8 | **60 / 60** | ninguno |

El original da 42 o 45 según la carrera del defecto 2 (Collector).
Reportes de la última ejecución (2026-10-17 15:15 UTC):
[original](evidencias/corrector-original-20261017T151550Z.txt) ·
[corregida](evidencias/corrector-corregido-20261017T151550Z.txt).

## 1 · `"${X:-{}}"` añade una `}` al JSON (−15 puntos y un eliminatorio falso)

Líneas 179–190 (`ATJSON`) y 226–244 (`PRJSON`). Bash cierra la expansión en
la primera `}`, así que la segunda queda como texto literal y se pega al JSON
cuando la variable **no** está vacía —que es justo el caso en que hay algo que
calificar—:

```bash
$ X='{"items":[1]}'; echo "${X:-{}}"
{"items":[1]}}
$ echo "${X:-{}}" | jq -e .items >/dev/null; echo $?
5                       # jq: parse error: Unmatched '}'
$ echo "${X:-"{}"}" | jq -e .items >/dev/null; echo $?
0
```

Efecto: con `set -o pipefail`, toda comprobación de 2.2 y 2.3 que pasa por
`jq -e` o por un conteo falla aunque los recursos existan. El propio reporte
lo delata: imprime «Consultas declaradas: 12» y «Reglas de registro: 28» y, a
renglón seguido, «El análisis NO consulta Prometheus» y «Sin reglas de
registro». Los conteos salen como `28\n0` (el número, y luego el `echo 0` del
`|| echo 0` tras el error de jq), y `[ "28\n0" -ge 1 ]` da «integer
expected».

Corrección: `"${ATJSON:-"{}"}"` y `"${PRJSON:-"{}"}"`.

## 2 · `grep -q` con `set -o pipefail` (comprobaciones que fallan con acierto)

Líneas 160 (Collector) y 264 (orígenes de Grafana). `grep -q` termina en el
primer acierto; si el comando que escribe en la tubería todavía tiene datos,
recibe SIGPIPE, sale con 141, y `pipefail` convierte el acierto en fallo.

- **Collector**: `kubectl get deploy,daemonset,statefulset -A -o name` escribe
  por tipo de recurso. En GKE existe además el DaemonSet
  `gmp-system/collector` (Managed Prometheus), que coincide antes que el de la
  entrega. Medido en este clúster: **4 aciertos de 10** con el mismo estado.
- **Orígenes de Grafana**: `echo "${DS:-}"` escribe ~80 KB de YAML; si los
  `type: prometheus/loki/tempo` están al principio, falla **siempre**. (La
  entrega lo esquiva poniendo su ConfigMap al final del listado:
  `visualizacion-origenes`.)

Corrección: `| grep -i … >/dev/null` (grep lee toda la entrada).

## 3 · Dos comprobaciones que dependen de detalles irrelevantes

No son errores de bash, pero conviene saberlo; la entrega se ajustó a ambas:

- **«La promoción depende del análisis»** usa `jq -e '.spec.strategy.canary.steps[]?.analysis'`,
  que decide por el **último** valor: un Rollout cuyo último paso es
  `setWeight: 100` (muy común) falla aunque todos los escalones tengan
  análisis.
- **«Las alertas enlazan a un runbook»** aplica `with_entries` a las
  anotaciones de **todas** las reglas; en una regla de registro son `null` y
  jq aborta. Cualquier entrega con reglas de registro —que el propio corrector
  exige— falla, salvo que declare `annotations: {}`.

## 4 · bash 3.2

El script usa `mapfile` (bash ≥ 4). En macOS `/usr/bin/env bash` puede
resolver al bash 3.2 del sistema; con él las consultas del análisis no se
leen. Se ejecuta con el bash de Homebrew (`/opt/homebrew/bin`).
