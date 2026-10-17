# Diagrama del bootstrap: orden de reconstrucción y dependencias

Un solo comando, `P9/scripts/bootstrap.sh`, y de ahí en adelante nada lo
toca una persona. El diagrama distingue tres cosas, porque el criterio 1.3
pide distinguirlas y porque son tres respuestas distintas a «¿qué hago si
esto falla?»:

| Símbolo | Significa |
|---|---|
| 🟦 **automático** | lo hace el sistema sin intervención |
| 🟧 **manual, una sola vez** | configuración inicial; NO forma parte de la recuperación |
| 🟩 **duradero** | sobrevive al desastre: es con lo que se sale de él |
| ⬜ **desechable** | se pierde en el desastre y se reconstruye |

## 1. La reconstrucción, de principio a fin

```mermaid
flowchart TD
    OP(["👤 operador<br/><code>P9/scripts/bootstrap.sh</code><br/>única acción humana"]):::humano

    subgraph S0["① Requisitos — gcloud"]
      F0["facturación del proyecto habilitada?"]:::auto
      F1["bucket de estado<br/><code>gs://…-sa-p9-tfstate</code><br/>se crea si no existe · versionado"]:::duradero
    end

    subgraph S1["② 00-fundacion — terraform apply (normalmente: sin cambios)"]
      B["bucket de respaldos<br/>US · versionado · prevent_destroy"]:::duradero
      K["llave de Sealed Secrets<br/>generada por Terraform → Secret Manager"]:::duradero
      IP["IP pública reservada"]:::duradero
      SA["cuentas de servicio: nodos, Velero"]:::duradero
    end

    subgraph S2["③ IP — liberar la regla de reenvío huérfana, si la hay"]
      L["forwarding rule del clúster muerto → se borra"]:::auto
    end

    subgraph S3["④ 10-cluster — terraform apply · ~10–12 min"]
      C["GKE zonal us-central1-a<br/>Dataplane V2 · Workload Identity"]:::efimero
      NP["pool: 3 × e2-standard-4"]:::efimero
      WI["vínculo Workload Identity<br/>velero/velero → sa-p9-velero"]:::efimero
    end

    subgraph S4["⑤ 20-gitops — terraform apply · ~3 min"]
      KS["Secret <code>sealed-secrets-llave-p9</code><br/>en kube-system (leído de Secret Manager)"]:::efimero
      AR["ArgoCD (helm_release)<br/>+ salud de Application y de BSL"]:::efimero
      RZ["AppProjects + Application raíz<br/><b>sa-p9-raiz</b> (ns argocd)"]:::efimero
    end

    subgraph S5["⑥ ArgoCD — app-of-apps, ola por ola (cada ola espera a que la anterior esté Healthy)"]
      W40["ola -40 · complementos<br/>sealed-secrets · ingress-nginx · argo-rollouts · kyverno · velero"]:::auto
      W30["ola -30 · namespaces, cuotas, límites, RBAC"]:::auto
      W20["ola -20 · 4 ClusterPolicy de Kyverno"]:::auto
      W15["ola -15 · Job de RESTAURACIÓN<br/>PVC+PV desde el último respaldo Completed"]:::auto
      W10["ola -10 · SealedSecret → Secret (stage, prod)"]:::auto
      W5["ola -5 · plantillas de análisis del canary"]:::auto
      W0["ola 0 · plataforma stage + prod<br/>PostgreSQL toma el PVC restaurado"]:::auto
      W10b["ola 10 · Schedules de Velero<br/>primer respaldo en el siguiente tic, ya con datos"]:::auto
    end

    V["⑦ verificación: GET /health → 200 por la IP pública<br/>registro con marcas de tiempo → RTO"]:::auto

    OP --> F0 --> F1 --> S1 --> L --> C --> NP --> WI
    NP --> KS --> AR --> RZ --> W40 --> W30 --> W20 --> W15 --> W10 --> W5 --> W0 --> W10b --> V

    B -. "respaldos del clúster anterior" .-> W15
    K -. "misma llave" .-> KS
    IP -. "loadBalancerIP" .-> W40
    SA -. "identidad" .-> NP
    SA -. "identidad" .-> WI

    classDef humano fill:#ffd8a8,stroke:#e8590c,color:#000
    classDef auto fill:#d0ebff,stroke:#1c7ed6,color:#000
    classDef duradero fill:#d3f9d8,stroke:#2f9e44,color:#000
    classDef efimero fill:#f1f3f5,stroke:#868e96,color:#000
```

## 2. Por qué este orden y no otro

Cada flecha es una dependencia real; romper cualquiera tiene un síntoma
concreto, y casi todos son silenciosos:

| Dependencia | Si se invierte… |
|---|---|
| llave en `kube-system` **antes** que el controlador de Sealed Secrets (⑤ → ola -40) | el controlador genera una llave propia; los 16 SealedSecret del repositorio dejan de abrirse y los pods quedan sin credenciales |
| Velero **Healthy** (bucket `Available`) **antes** de la restauración (-40 → -15) | el Job concluiría «no hay respaldos» solo porque aún no los leyó |
| namespaces **antes** de la restauración (-30 → -15) | los PVC restaurados caerían en namespaces sin cuotas ni etiquetas de Pod Security |
| restauración **antes** de la plataforma (-15 → 0) | el StatefulSet crea un PVC vacío, `initdb` lo inicializa, y Velero ya no restaura encima de un PVC que existe: los datos se pierden por segunda vez |
| políticas **antes** de la plataforma (-20 → 0) | durante unos minutos se admitirían pods sin firma verificada |
| secretos **antes** de la plataforma (-10 → 0) | los pods arrancan en `CreateContainerConfigError` y ArgoCD reintenta |
| plataforma **antes** de los Schedules (0 → 10) | un tic del cron durante la reconstrucción respaldaría los namespaces vacíos y sería «el más reciente» para la siguiente recuperación |

El orden de las olas lo hace cumplir ArgoCD, no la suerte: el script de
salud de `argoproj.io/Application` en `argocd-cm` (`20-gitops/argocd.tf`)
hace que la raíz espere a que cada ola esté `Healthy`. Sin ese script —que
ArgoCD trae apagado desde la versión 1.8—, la raíz aplicaría todas las olas
casi a la vez.

## 3. Lo que es manual, y cuándo

Solo dos cosas, y **ninguna** está en el camino de la recuperación:

```mermaid
flowchart LR
    subgraph UNA["🟧 una sola vez, al crear el proyecto"]
      M1["habilitar facturación en GCP<br/>(consola: no tiene API sin facturación)"]:::humano
      M2["<code>configurar-gitops.sh</code><br/>escribe en Git la IP reservada y el certificado público;<br/>sella los 16 secretos con la llave de Secret Manager"]:::humano
    end
    subgraph SIEMPRE["🟦 cada reconstrucción"]
      A1["<code>bootstrap.sh</code>"]:::auto
    end
    M1 --> M2 --> A1
    classDef humano fill:#ffd8a8,stroke:#e8590c,color:#000
    classDef auto fill:#d0ebff,stroke:#1c7ed6,color:#000
```

Las dos dependen solo de la fundación, que sobrevive al desastre: la IP, la
llave y el certificado son los mismos antes y después de reconstruir. Por eso
`bootstrap.sh` comprueba que el repositorio GitOps ya tenga la IP y, si no,
se detiene en el primer minuto en lugar de dejar un balanceador en
`<pending>` media hora después.

## 4. Qué se pierde y qué no

```mermaid
flowchart LR
    subgraph PIERDE["⬜ se pierde con el clúster"]
      P1[plano de control y nodos]
      P2[discos de los PVC]
      P3[Secret descifrados]
      P4[estado de ArgoCD]
    end
    subgraph RECONSTRUYE["🟦 se reconstruye desde…"]
      R1["Terraform (estado en GCS)"]
      R2["Git (repositorio GitOps)"]
      R3["Velero (bucket + snapshots)"]
      R4["Secret Manager"]
    end
    P1 --> R1
    P4 --> R2
    P2 --> R3
    P3 --> R4
    P3 --> R2
```

Lo único que **no** se recupera son las escrituras posteriores al último
respaldo: esa ventana es el RPO, y se mide (ver el informe).
