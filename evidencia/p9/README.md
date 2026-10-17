# Práctica 9 — Continuidad operativa y recuperación ante desastres

La plataforma de la [Práctica 8](../P8/readme.md) se desplegaba de forma
controlada y segura, pero nunca había perdido nada. Tenía tres puntos de no
retorno: datos en volúmenes que nadie respaldaba, el estado de Terraform en
una laptop y la llave de los secretos solo dentro del clúster.

Aquí la plataforma corre en **GKE**, y se puede **destruir entera y volver a
levantar con un solo comando**. Los datos vuelven del último respaldo, los
secretos se siguen abriendo y el flujo GitOps de la P8 sigue funcionando.
Todo está medido con el cronómetro corriendo.

**Carné:** 202202410 · **Sección:** B

---

## Tabla de enlaces (§4.1 del enunciado)

> El repositorio de código es **privado**. Toda la evidencia y la
> documentación están **espejadas en el repositorio GitOps, que es
> público**, en [`evidencia/p9/`](https://github.com/marcosbondel/sa-gitops-202202410/tree/main/evidencia/p9);
> los enlaces de esta tabla apuntan allí y se abren sin autenticación.

| Ítem | Enlace o dato |
|---|---|
| **Repositorio GitOps** | https://github.com/marcosbondel/sa-gitops-202202410 |
| **Aplicación raíz en ArgoCD** | **`sa-p9-raiz`** · namespace **`argocd`** · proyecto `sa-p9-base` · apunta a [`apps/`](https://github.com/marcosbondel/sa-gitops-202202410/tree/main/apps) (15 Application en 8 olas) |
| **Punto de entrada del bootstrap** | **`P9/scripts/bootstrap.sh`** · [copia pública](https://github.com/marcosbondel/sa-gitops-202202410/blob/main/evidencia/p9/scripts/bootstrap.sh) |
| **Backend remoto de Terraform** | **GCS** (`backend "gcs"`, bloqueo nativo con objeto `default.tflock`) · bucket `gs://sociedadanonima-507519-sa-p9-tfstate`, versionado y sin acceso público · un prefijo por capa: `fundacion/`, `cluster/`, `gitops/` · prueba del bloqueo (segundo `plan` rechazado, cero `.tfstate` en la historia de Git): [`bloqueo-estado-20261017T035731Z.log`](https://github.com/marcosbondel/sa-gitops-202202410/blob/main/evidencia/p9/docs/evidencias/bloqueo-estado-20261017T035731Z.log) |
| **Schedule de Velero** | **`sa-p9-cada-15m`** (`*/15 * * * *`, TTL 720 h, volúmenes por snapshot) y **`sa-p9-llave`** (llave de Sealed Secrets) · destino: `gs://sociedadanonima-507519-sa-p9-respaldos` (multi-región US) + snapshots de disco en `us` · [definición](https://github.com/marcosbondel/sa-gitops-202202410/tree/main/respaldos/programacion) |
| **Reconstrucción cronometrada** | [`prueba-dr-20261017T042003Z.log`](https://github.com/marcosbondel/sa-gitops-202202410/blob/main/evidencia/p9/docs/evidencias/prueba-dr-20261017T042003Z.log) — destrucción 04:34:57 UTC → servicio de vuelta 05:04:25 · datos crudos (sonda, marcas, huellas) en [`prueba-dr-20261017T042003Z/`](https://github.com/marcosbondel/sa-gitops-202202410/tree/main/evidencia/p9/docs/evidencias/prueba-dr-20261017T042003Z) |
| **Restauración de datos** | [`prueba-restauracion-20261017T041048Z.log`](https://github.com/marcosbondel/sa-gitops-202202410/blob/main/evidencia/p9/docs/evidencias/prueba-restauracion-20261017T041048Z.log) — `TRUNCATE` de `ops_db` y `catalog_db`, restaurado desde Velero: 10/10 marcas previas al respaldo de vuelta con contenido idéntico, md5 idéntico tabla por tabla · y en la prueba de DR, 57/57 |
| **Prueba de pérdida de nodo** | [`prueba-nodo-tipico-20261017T035749Z.log`](https://github.com/marcosbondel/sa-gitops-202202410/blob/main/evidencia/p9/docs/evidencias/prueba-nodo-tipico-20261017T035749Z.log) — 22 pods desalojados, **100 %** de disponibilidad (333/333 peticiones con 200) · peor caso, el nodo de PostgreSQL: [`prueba-nodo-peor-caso-20261017T040256Z.log`](https://github.com/marcosbondel/sa-gitops-202202410/blob/main/evidencia/p9/docs/evidencias/prueba-nodo-peor-caso-20261017T040256Z.log) (26 s sin base) |
| **RTO y RPO declarados** | **Objetivo: RTO 40 min · RPO 15 min** ([justificación](https://github.com/marcosbondel/sa-gitops-202202410/blob/main/evidencia/p9/docs/01-objetivos-rto-rpo.md)) · **Medido: RTO 29 min 04 s · RPO 4 min 23 s** — ambos cumplen ([informe](https://github.com/marcosbondel/sa-gitops-202202410/blob/main/evidencia/p9/docs/04-informe-prueba-dr.md)) |
| **Video demostrativo** | ⏳ URL · minutaje en [`docs/06-guion-video.md`](docs/06-guion-video.md) |

---

## Recuperar el sistema

```bash
P9/scripts/bootstrap.sh
```

Es **el único comando**, igual para el primer arranque que para recuperarse
de la pérdida total del clúster. Paso a paso, con verificaciones y qué hacer
si algo falla: [**runbook**](docs/03-runbook-recuperacion.md).

```
bootstrap.sh
  ├─ 00-fundacion   (sobrevive al desastre)  bucket de respaldos · llave en Secret Manager · IP · identidades
  ├─ 10-cluster     GKE · 3 × e2-standard-4
  └─ 20-gitops      llave → kube-system · ArgoCD · sa-p9-raiz
        └─ app-of-apps, ola por ola:
           -40 complementos (Velero, Kyverno, Rollouts, ingress, Sealed Secrets)
           -30 namespaces · -20 políticas
           -15 RESTAURACIÓN de los volúmenes desde el último respaldo
           -10 secretos · -5 análisis · 0 plataforma · 10 Schedules
```

[Diagrama completo, con lo automático y lo manual](docs/02-diagrama-bootstrap.md).

### Encender y apagar por sesión (costo)

```bash
P9/scripts/encender.sh   # bootstrap.sh + verificar.sh  (~35 min)
P9/scripts/apagar.sh     # respaldo final + destruir clúster y discos; queda la fundación (~$0.30/día)
```

### Las pruebas

```bash
P9/scripts/prueba-dr.sh --confirmar sa-p9      # destruir y reconstruir, midiendo RTO y RPO
P9/scripts/prueba-restauracion.sh              # borrar datos reales y recuperarlos, fila por fila
P9/scripts/prueba-nodo.sh                      # drenar un nodo con el servicio respondiendo
P9/scripts/prueba-bloqueo.sh                   # el estado remoto bloquea
P9/scripts/verificar.sh                        # ¿está recuperado de verdad?
```

Cada una deja un registro con marcas de tiempo UTC en
[`docs/evidencias/`](docs/evidencias/).

---

## Documentación

| | |
|---|---|
| [`01-objetivos-rto-rpo.md`](docs/01-objetivos-rto-rpo.md) | RTO y RPO comprometidos, **antes** de las pruebas, con su justificación y cómo se miden. |
| [`02-diagrama-bootstrap.md`](docs/02-diagrama-bootstrap.md) | Orden de reconstrucción, dependencias, qué es automático y qué manual. |
| [`03-runbook-recuperacion.md`](docs/03-runbook-recuperacion.md) | Procedimiento ejecutable por un tercero, con verificación en cada paso. |
| [`04-informe-prueba-dr.md`](docs/04-informe-prueba-dr.md) | Los seis campos de la §4.2, con tiempos medidos. |
| [`05-preguntas-teoricas.md`](docs/05-preguntas-teoricas.md) | Cómo se comporta este sistema ante cada pérdida, y sus límites. |
| [`06-guion-video.md`](docs/06-guion-video.md) | Guion y minutaje del video. |
| [`evidencias/`](docs/evidencias/) | Registros de cada prueba, con el comando que los produjo. |

---

## Decisiones, en una línea cada una

- **Tres estados de Terraform** (`00-fundacion`, `10-cluster`, `20-gitops`):
  la prueba destruye las dos últimas; la primera tiene `prevent_destroy` y es
  con lo que se sale del desastre. [Por qué](terraform/00-fundacion/main.tf).
- **La llave de Sealed Secrets nace en Terraform**, vive en Secret Manager y
  entra al clúster **antes** que el controlador; el respaldo de la llave
  tiene una segunda copia en Velero (`sa-p9-llave`).
  [Por qué](terraform/00-fundacion/secretos.tf).
- **Velero con snapshots de disco**, no Kopia: consistentes ante caídas para
  PostgreSQL y restaurables sin pod, antes de que la plataforma exista.
- **La restauración es una ola del app-of-apps**, no un paso del script: el
  Job decide solo si es un desastre o un primer arranque, y falla a propósito
  si hay respaldos pero ninguno sirve.
- **Los complementos pasan de Terraform (P8) a ArgoCD**: Terraform instala
  ArgoCD y nada más dentro del clúster.
- **IP pública reservada en la fundación**: las URL `*.nip.io` son las
  mismas antes y después del desastre.
- **Cuenta y proyecto explícitos** en `scripts/config.sh`: la máquina tiene
  varias cuentas de gcloud y la activa no es la de este proyecto.

## Flujo de la Práctica 8, conservado

GitOps (mismo repositorio, mismas Application `sa-p8-*`), entrega
progresiva (Argo Rollouts + análisis) y políticas de admisión (4
ClusterPolicy de Kyverno, incluida la verificación de firma de Cosign)
siguen operando tras cada reconstrucción; `scripts/verificar.sh` lo
comprueba —un pod con `:latest` es rechazado— y lo deja en el registro.

## Verificación con el corrector del curso

```bash
P9/scripts/preparar-calificacion.sh     # deja gcloud/kubectl listos y ejecuta verificar_p9.sh con p9.conf
```

`scripts/verificar_p9.sh` es el script del curso, sin modificar.
