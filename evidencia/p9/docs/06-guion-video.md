# Guion del video demostrativo (5–8 min)

Grabado sobre el clúster real en GKE. Las esperas largas (creación del
clúster, olas de ArgoCD) se aceleran en edición; **el reloj del registro**
—las marcas UTC de `bootstrap.sh`— queda siempre visible en pantalla, para
que la aceleración no esconda el tiempo real.

| Minuto | Punto demostrado (criterio) | Qué se ve |
|---|---|---|
| `00:00` | Contexto | Las tres debilidades del §3.1 y las tres capas de Terraform (diagrama del bootstrap). |
| `00:40` | Estado remoto con bloqueo (2.2) | `gcloud storage ls gs://…-tfstate/**` (los tres prefijos); `prueba-bloqueo.sh`: el segundo `plan` rechazado con «Error acquiring the state lock»; `git log --all -- '*.tfstate'` vacío. |
| `01:20` | Respaldos programados (2.3) | `velero schedule get` (cron, TTL), `velero backup get` (Completed cada 15 min), `velero backup describe --details` (snapshots de los PVC), el bucket en la consola de GCS. |
| `02:00` | Desastre (escenario) | `prueba-dr.sh`: escritor y sonda en marcha; `desastre.sh` destruye clúster y discos; `gcloud container clusters list` vacío; la sonda empieza a fallar. |
| `02:50` | Bootstrap de día cero (2.1) | `bootstrap.sh` — un comando. GKE creándose (acelerado); ArgoCD aplicando las olas en orden (vista de árbol de `sa-p9-raiz`); el registro marca cada cambio con su hora. |
| `04:00` | Restauración automática (2.3, 2.6) | Logs del Job `sa-p9-restauracion`: bucket accesible → sincronizado → respaldo elegido → `Restore` `Completed`; PostgreSQL arranca sobre el PVC restaurado. |
| `04:40` | Continuidad de los secretos (2.4) | `verificar.sh`: la huella del certificado es la misma en el clúster, en Secret Manager y en el repositorio; 16/16 SealedSecret descifrados. |
| `05:10` | Datos verificados y RTO/RPO (2.6, informe) | Bloque «MEDICIÓN»: RTO medido, marcas perdidas y recuperadas, huella tabla por tabla idéntica salvo lo escrito tras el respaldo. |
| `05:50` | Pérdida de nodo (2.5) | `prueba-nodo.sh`: pantalla dividida, sonda a la izquierda (todo `200`) y `kubectl drain` a la derecha (desalojos, PDB reteniendo réplicas); resumen de disponibilidad. |
| `06:50` | Flujo de la P8 conservado | ArgoCD todo `Synced/Healthy`; un pod con `:latest` rechazado por Kyverno; Rollouts `Healthy`. |
| `07:20` | Cierre | Declarado frente a medido, puntos únicos de fallo y el plan (informe §6). |

> El minutaje definitivo se ajusta tras la edición y se copia a la tabla de
> enlaces del [README](../README.md).
