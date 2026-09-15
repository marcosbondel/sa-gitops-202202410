# sa-gitops-202202410 — Repositorio de manifiestos

Este repositorio es **la única fuente de verdad** del estado del clúster de la
Práctica 8 de Software Avanzado (sección B, carné 202202410).

Nada llega al clúster si no está aquí. Ningún pipeline tiene credenciales de
Kubernetes; ArgoCD lee este repositorio y aplica lo que encuentra.

- **Repositorio de código:** `marcosbondel/Practicas-SA-B-202202410`, carpeta `P8/`
- **Aplicación raíz en ArgoCD:** `sa-p8-raiz` · namespace `argocd`
- **Ambientes:** `sa-p8-stage` y `sa-p8-prod`

---

## Cómo está organizado

```
apps/              Las Applications de ArgoCD. Patrón «app of apps»:
                   la Application raíz (que crea Terraform) apunta aquí
                   y cada archivo de esta carpeta es una hija.

charts/            Los charts, PUBLICADOS desde el repositorio de código.
  sa-platform/       La plataforma: un subchart por microservicio.
  sa-p8-analisis/    Las tres puertas de calidad del canary.

envs/              Los valores por ambiente. Es lo único que el Pull Request
  comunes.yaml       automático del pipeline modifica.
  stage/
  prod/

policies/          Las tres políticas de admisión de Kyverno.

sealed-secrets/    Criptograma. Ver la advertencia de abajo.
  clave-publica.pem
  stage/
  prod/

evidencia/         Copia pública de los reportes que el pipeline produce:
                   Trivy, SBOM, verificación de firma con Cosign y el
                   reporte de la prueba de carga.
```

## El orden en que ArgoCD lo aplica

Las anotaciones `argocd.argoproj.io/sync-wave` fijan el orden, y cada salto
resuelve un problema concreto:

| Onda | Qué | Por qué antes que lo siguiente |
|---|---|---|
| **-20** | Políticas de Kyverno | Las políticas de admisión no se aplican retroactivamente. Un pod que entra antes de que la política exista se queda corriendo y nadie lo mira nunca más. |
| **-10** | Secretos sellados | El controlador tarda segundos en convertir cada `SealedSecret` en `Secret`. Los pods que los montan fallarían su primer arranque. |
| **-5** | Plantillas de análisis | Un `Rollout` sin sus `AnalysisTemplate` no espera: aborta con `not found`, y parecería que falló la versión candidata. |
| **0** | La plataforma | |

## ⚠ Sobre `sealed-secrets/`

**Lo que hay ahí no son credenciales: es criptograma.**

Está cifrado con la clave pública del clúster, y solo la clave privada —que el
controlador de Sealed Secrets genera al arrancar y que nunca sale del clúster—
puede descifrarlo. Por eso este repositorio puede ser público.

Un `SealedSecret` además va atado a su namespace: el controlador se niega a
descifrar uno que aparezca en otro sitio. Copiar `stage/` a `prod/` no funciona,
y es a propósito.

```bash
# Comprobarlo: lo que se versiona es esto.
grep -m1 -A2 encryptedData sealed-secrets/stage/sa-platform-db-credentials.yaml
```

## Qué modifica el flujo automático, y qué no

| Ruta | Quién la escribe |
|---|---|
| `envs/*/values.yaml` | **El pipeline**, mediante un Pull Request que solo cambia la etiqueta de la imagen. |
| `charts/**` | `P8/scripts/03-publicar-gitops.sh`, desde el repositorio de código. |
| `apps/**`, `policies/**` | A mano, con revisión. |
| `sealed-secrets/**` | `P8/scripts/02-sellar-secretos.sh`. |

Lo que **nadie** puede escribir desde aquí está en el `AppProject` `sa-p8`:
`ResourceQuota`, `LimitRange`, `ClusterRole` y `ClusterRoleBinding` están en su
lista negra. Son propiedad de Terraform, y el flujo automático no puede
subirse a sí mismo el techo.

## Reproducirlo

Todo lo necesario está en el repositorio de código, en `P8/`:

```bash
P8/scripts/00-crear-cluster.sh       # kind, vacío
P8/scripts/01-terraform.sh           # namespaces, cuotas, RBAC, complementos
P8/scripts/02-sellar-secretos.sh     # credenciales cifradas hacia aquí
P8/scripts/03-publicar-gitops.sh --sembrar-valores --empujar
```

A partir del cuarto comando, ArgoCD hace el resto.
