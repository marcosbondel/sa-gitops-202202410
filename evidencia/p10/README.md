# Práctica 10 — Observabilidad y operación: del síntoma a la causa

Hasta la P9 la plataforma se desplegaba, se protegía y se recuperaba sola,
pero seguía siendo una caja negra: nadie podía decir qué servicio hacía lenta
una compra, el canary decidía con pruebas que escribió el propio estudiante, y
no había forma de saber si el sistema cumplía lo que promete.

Ahora cada petición deja **tres señales correlacionadas por un mismo
`trace_id`** —métricas en Prometheus, trazas en Tempo, registros JSON en
Loki—; el canary del gateway **decide con Prometheus** sobre el tráfico real
de la versión candidata; y dos **SLO** con su presupuesto de error deciden
cuándo un fallo amerita despertar a alguien. Todo desplegado por el flujo
GitOps de la P8, en GKE.

**Carné:** 202202410 · **Sección:** B

---

## Tabla de enlaces (§4.1)

> El repositorio de código es **privado**. Esta carpeta `P10/` está
> **espejada en el repositorio GitOps, que es público**, en
> [`evidencia/p10/`](https://github.com/marcosbondel/sa-gitops-202202410/tree/main/evidencia/p10):
> los enlaces apuntan allí y se abren sin autenticación.

| Ítem | Enlace o dato |
|---|---|
| **Repositorio de código** | https://github.com/marcosbondel/sa-gitops-202202410/tree/main/evidencia/p10 (copia pública de `P10/`; original privado: `git@github.com:marcosbondel/Practicas-SA-B-202202410.git`, carpeta `P10/`) |
| **Repositorio GitOps** | https://github.com/marcosbondel/sa-gitops-202202410 |
| **Servicios instrumentados** | **`api-gateway`** (Node), **`order-service`** (Python), **`catalog-service`** (Node) · namespace **`sa-p8-prod`** (y `sa-p8-stage`) · código: [`servicios/`](https://github.com/marcosbondel/sa-gitops-202202410/tree/main/evidencia/p10/servicios) |
| **AnalysisTemplate por métricas** | **`sa-p10-metricas`** · [`charts/sa-p10-analisis/templates/analisis-metricas.yaml`](https://github.com/marcosbondel/sa-gitops-202202410/blob/main/charts/sa-p10-analisis/templates/analisis-metricas.yaml) · umbrales: [stage](https://github.com/marcosbondel/sa-gitops-202202410/blob/main/charts/sa-p10-analisis/values.yaml), [prod](https://github.com/marcosbondel/sa-gitops-202202410/blob/main/envs/prod/analisis.yaml) |
| **Consultas del análisis** | `S = namespace="{{args.namespace}}", service="{{args.servicio}}", rollouts_pod_template_hash="{{args.hash-canary}}"` (hash del ReplicaSet nuevo, `podTemplateHashValue: Latest`)<br>**tráfico** `sum(increase(http_server_request_duration_seconds_count{S}[2m])) or on() vector(0)` ≥ 10 (prod 20)<br>**errores** `((sum(rate(http_server_request_duration_seconds_count{S, http_response_status_code=~"5.."}[2m])) or on() vector(0)) / sum(rate(http_server_request_duration_seconds_count{S}[2m]))) or on() vector(0)` ≤ 0,05 (prod 0,02)<br>**latencia** `histogram_quantile(0.95, sum by (le) (rate(http_server_request_duration_seconds_bucket{S}[2m]))) or on() vector(0)` ≤ 0,5 s (prod 0,4 s) |
| **SLO declarados** | **Compras que se completan: 99,5 % · 30 días** · **Catálogo bien y en < 300 ms: 99 % · 30 días** · [justificación](https://github.com/marcosbondel/sa-gitops-202202410/blob/main/evidencia/p10/docs/01-slo.md) |
| **Reglas de alerta** | PrometheusRule **`slo-plataforma`** (ns `observabilidad`) · [`observabilidad/config/slo/reglas-slo.yaml`](https://github.com/marcosbondel/sa-gitops-202202410/blob/main/observabilidad/config/slo/reglas-slo.yaml) · 28 reglas de registro, 4 alertas por quema de presupuesto, cada una con su [runbook](https://github.com/marcosbondel/sa-gitops-202202410/tree/main/evidencia/p10/docs/runbooks) |
| **Tablero** | [`tablero/tablero-operacion.json`](https://github.com/marcosbondel/sa-gitops-202202410/blob/main/evidencia/p10/tablero/tablero-operacion.json) (exportado de Grafana) · [captura en operación, durante el incidente B](https://github.com/marcosbondel/sa-gitops-202202410/blob/main/evidencia/p10/tablero/captura-tablero-incidente.png) |
| **Reversión por métricas** | AnalysisRun **`sa-platform-api-gateway-7d7ffb5988-3-1`** (`Failed`: `tasa-errores` 15,3 % y 30,7 %) · Rollout **`sa-platform-api-gateway`** · ns `sa-p8-stage` · [registro](https://github.com/marcosbondel/sa-gitops-202202410/blob/main/evidencia/p10/docs/evidencias/canary-fallo-20261017T125912Z.log) · [AnalysisRun](https://github.com/marcosbondel/sa-gitops-202202410/blob/main/evidencia/p10/docs/evidencias/canary-fallo-20261017T125912Z/analysisrun-sa-platform-api-gateway-7d7ffb5988-3-1.yaml) · detección 3 min 07 s, recuperación 3 min 09 s, sin intervención |
| **Recorrido síntoma a causa** | [`incidente-checkout-20261017T130858Z.log`](https://github.com/marcosbondel/sa-gitops-202202410/blob/main/evidencia/p10/docs/evidencias/incidente-checkout-20261017T130858Z.log) · **alerta → registro del error: 4 s** (13:12:27 → 13:12:31 UTC, alerta → métricas → traza → registro) · detección 2 min 49 s · recuperación 3 min 57 s |
| **Video demostrativo** | ⏳ URL · minutaje por punto en [`docs/05-guion-video.md`](docs/05-guion-video.md) |

---

## Qué hay aquí

```
P10/
├── servicios/              los tres servicios, instrumentados (copias de P5; la P5 no se toca)
│   ├── api-gateway/src/telemetria/      iniciar.ts · log.ts · metricas.ts
│   ├── catalog-service/src/telemetria/  ídem + GraphQL y PostgreSQL
│   └── order-service/app/telemetria.py  ídem en Python + métricas de negocio
├── fallo-inducido/         el defecto del canary (api-gateway.patch)
├── tablero/                JSON exportado de Grafana y captura
├── docs/
│   ├── 01-slo.md                   los dos SLO y por qué esos números
│   ├── 02-diagrama-telemetria.md   el recorrido de cada señal, hasta el tablero y la alerta
│   ├── 03-informe-operacion.md     los seis campos de la §4.2, con tiempos medidos
│   ├── 04-preguntas-teoricas.md    cómo se comporta esta instrumentación y dónde no alcanza
│   ├── 05-guion-video.md           guion y minutaje
│   ├── 06-defectos-del-corrector.md  para el auxiliar: los defectos de verificar_p10.sh, reproducidos
│   ├── runbooks/                   uno por alerta
│   └── evidencias/                 registros con marcas UTC de cada demostración
└── scripts/
    ├── demo-canary.sh          fusiona el PR defectuoso y mide detección y reversión
    ├── incidente.sh            provoca el incidente de producción y mide todo
    ├── recorrido.sh            alerta → métricas → traza → registro, cronometrado
    ├── exportar-tablero.sh     JSON de Grafana + captura
    ├── preparar-calificacion.sh  deja gcloud/kubectl listos y corre el corrector
    ├── verificar_p10.sh        el corrector del curso, sin modificar
    └── verificar_p10_corregido.sh  copia con solo sus dos defectos corregidos (referencia)
```

En el repositorio GitOps:

```
apps/50…57-*.yaml          proyecto de ArgoCD y las 8 Application del stack (olas 1–5)
observabilidad/config/     PodMonitor · SLO y alertas · orígenes de Grafana · tablero
observabilidad/secretos/   credenciales de Grafana (SealedSecret)
charts/sa-p10-analisis/    el AnalysisTemplate por métricas
charts/sa-platform/        puerto de métricas, variables OTel y NetworkPolicy de telemetría
simulador/                 clientes simulados (k6), el tráfico que miden SLO y canary
```

## Decisiones, en una línea cada una

- **Métricas raspadas, trazas y registros por el Collector.** Las métricas
  gobiernan el canary: no pueden depender del Collector, y raspadas llegan con
  la etiqueta del pod `rollouts-pod-template-hash`, que separa la versión
  candidata de la estable.
- **Un solo histograma con el mismo nombre y cortes en Node y Python**, con
  cubos en 0,3 s (umbral del SLO) y 0,5 s (umbral del canary): el SLI es una
  cuenta, no una interpolación.
- **Registros por stdout, no por OTLP**: `kubectl logs` sigue sirviendo con
  el stack caído; el Collector (DaemonSet) los lee del nodo y pasa
  `trace_id` al campo de traza del registro.
- **Sin las ~150 alertas por defecto de kube-prometheus-stack**: solo cuatro,
  por quema de presupuesto, con runbook.
- **El stack en las olas 1–5**, después de la plataforma (ola 0): tras un
  desastre el cliente recupera el servicio antes que la observabilidad; el RTO
  de la P9 no cambia.
- **Un simulador de clientes** (k6) porque no hay usuarios reales: el análisis
  no sabe que existe y funcionaría igual con clientes de verdad.

## Flujo de las prácticas anteriores, conservado

- **Cadena de suministro (P8).** La primera entrega instrumentada, `p8-v1.3.0`,
  fue **bloqueada por Trivy**: CVE críticas nuevas en `proxy-addr` (gateway,
  catálogo) y `PyJWT` (auth-service). Se corrigió y se publicó la 1.3.1, firmada
  y verificada ([evidencia](docs/evidencias/cadena-suministro-cve-bloqueo-1.3.0.txt)).
- **GitOps y entrega progresiva (P8).** Las versiones llegan por Pull Request
  al repositorio GitOps; la 1.3.1 pasó el canary por métricas en stage y en
  producción (tres AnalysisRun exitosos en cada uno,
  [stage](docs/evidencias/canary-1.3.1-stage-exitoso/mediciones.txt),
  [prod](docs/evidencias/canary-1.3.1-prod-exitoso/mediciones.txt)).
- **Políticas de admisión (P8)** siguen activas en `sa-p8-*`: las imágenes
  nuevas pasaron la verificación de firma de Kyverno al crear cada pod.
- **Recuperación (P9).** Todo el stack es GitOps: `P9/scripts/bootstrap.sh`
  lo reconstruye desde cero junto con la plataforma.

## Cómo se ejecuta

```bash
P9/scripts/encender.sh                    # clúster + plataforma + observabilidad (~35 min)
kubectl -n observabilidad port-forward svc/kube-prometheus-stack-grafana 3000:80   # http://localhost:3000
P10/scripts/demo-canary.sh                # tras: git tag p8-vX.Y.Z-fallo && git push origin p8-vX.Y.Z-fallo
P10/scripts/incidente.sh                  # incidente de producción + recorrido + recuperación
P10/scripts/preparar-calificacion.sh      # corrector del curso
P9/scripts/apagar.sh                      # al terminar
```

## El corrector

`scripts/verificar_p10.sh` es el del curso, **sin modificar** (sha256
`0f423f0112af7767…`). Ejecutado contra el clúster vivo el 2026-10-17 a las
15:15 UTC con `preparar-calificacion.sh`, desde un entorno limpio:

| | 2.1 | 2.2 | 2.3 | 2.4 | 2.5 | Total | Eliminatorios |
|---|---|---|---|---|---|---|---|
| [Original](docs/evidencias/corrector-original-20261017T151550Z.txt) | 11 | 11 | 2 | 10 | 8 | **42 / 60** | «análisis sin Prometheus» (falso) |
| [Copia corregida](docs/evidencias/corrector-corregido-20261017T151550Z.txt) | 14 | 16 | 12 | 10 | 8 | **60 / 60** | ninguno |

El original oscila entre 42 y 45 según gane o pierda la carrera de la
comprobación del Collector (defecto 2). Los puntos de diferencia son dos
defectos del corrector, no de la entrega:

1. **`"${ATJSON:-{}}"` y `"${PRJSON:-{}}"`** —el mismo defecto que tenía el de
   la P9— dejan una `}` pegada al JSON cuando la variable no está vacía; `jq`
   falla y todas las comprobaciones de 2.2 y 2.3 que pasan por esas variables
   salen en cero, con un eliminatorio falso. Las consultas, los
   AnalysisTemplate y las 28 reglas de registro y 4 alertas existen: el propio
   corrector las lista («Consultas declaradas: 12», «Reglas de registro: 28»).
2. **`… | grep -qi …` con `set -o pipefail`**: `grep` termina en el primer
   acierto, el comando que escribe recibe SIGPIPE y `pipefail` convierte el
   acierto en fallo. Afecta a la comprobación del Collector (una carrera: pasa
   o no según cuándo escriba `kubectl`; GKE trae además su propio DaemonSet
   `gmp-system/collector`) y a la de los orígenes de Grafana. Esta última se
   evitó del lado de la entrega: el ConfigMap de orígenes se llama
   `visualizacion-origenes` para ser el último del listado (ver su
   encabezado).

Del lado de la entrega se ajustaron dos cosas legítimas que el corrector
interpretaba mal: el canary ya no termina en un `setWeight: 100` redundante
(`jq -e` miraba solo el último paso) y las reglas de registro declaran
`annotations: {}` (la comprobación de runbooks hacía `with_entries` sobre
`null`).

Detalle y reproducción mínima para el auxiliar:
[`docs/06-defectos-del-corrector.md`](docs/06-defectos-del-corrector.md).

`preparar-calificacion.sh` deja gcloud y kubectl listos en esta máquina y
ejecuta el original y, como referencia,
[`scripts/verificar_p10_corregido.sh`](scripts/verificar_p10_corregido.sh)
—la copia con solo esas dos correcciones, que escribe su propio reporte—.
