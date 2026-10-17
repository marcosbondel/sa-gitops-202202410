# Evidencias de la Práctica 9

Cada `.log` lo escribió un script mientras ocurría lo que registra; ninguno
se editó a mano. Formato de cada línea: `<UTC>  +<min:seg>  [etapa]  mensaje`.

## Las pruebas (2026-10-17, en GKE)

| Archivo | Script | Qué demuestra | Resultado |
|---|---|---|---|
| [`prueba-dr-20261017T042003Z.log`](prueba-dr-20261017T042003Z.log) + carpeta | `prueba-dr.sh` | destrucción total y reconstrucción cronometradas (incluye el registro de `desastre.sh` y de `bootstrap.sh`) | **RTO 29 min 04 s · RPO 4 min 23 s** |
| [`prueba-restauracion-20261017T041048Z.log`](prueba-restauracion-20261017T041048Z.log) + carpeta | `prueba-restauracion.sh` | `TRUNCATE` de `ops_db` y `catalog_db` y restauración desde Velero, verificada fila por fila | 10/10 marcas previas de vuelta, idénticas; 6 posteriores perdidas, como se esperaba |
| [`prueba-nodo-tipico-20261017T035749Z.log`](prueba-nodo-tipico-20261017T035749Z.log) + carpeta | `prueba-nodo.sh` | drenaje de un nodo con gateway e ingress | **100 %** de disponibilidad (333/333) |
| [`prueba-nodo-peor-caso-20261017T040256Z.log`](prueba-nodo-peor-caso-20261017T040256Z.log) + carpeta | `prueba-nodo.sh --peor-caso` | drenaje del nodo de PostgreSQL (SPOF declarado) | 26 s sin base; `/health` 93,69 % |
| [`bloqueo-estado-20261017T035731Z.log`](bloqueo-estado-20261017T035731Z.log) | `prueba-bloqueo.sh` | el backend GCS bloquea; cero `.tfstate` en el árbol y en la historia | segundo `plan` rechazado |
| [`reconstruccion-20261017T031005Z.log`](reconstruccion-20261017T031005Z.log) | `bootstrap.sh` | primer arranque completo en GKE | sistema arriba (con las correcciones del informe §5) |

## El corrector del curso (`verificar_p9.sh` v1.0)

| Archivo | Qué es |
|---|---|
| [`corrector-original-20261017T050833Z.txt`](corrector-original-20261017T050833Z.txt) | el script oficial, sin modificar (sha256 `367900de…`): 40/60 y un eliminatorio **falso** por un error del propio script |
| [`corrector-corregido-20261017T050843Z.txt`](corrector-corregido-20261017T050843Z.txt) | el mismo script con UNA corrección (`"${X:-{}}"` → `"${X:-\{\}}"`): **58/60**, sin eliminatorios |

El error: en bash, `"${SCHED:-{}}"` termina en el primer `}` y pega un `}`
sobrante al JSON; `jq` imprime el valor correcto, falla por ese carácter y el
`|| echo 0` añade un `0`: la variable vale `"2\n0"` y la comparación numérica
falla. Afecta a 2.3, 2.4 y 2.6 de cualquier estudiante.

## Intentos previos, conservados por honestidad

| Archivo | Qué pasó |
|---|---|
| `reconstruccion-20261017T021552Z.log` | el token de Terraform venció a los 5 min (401); estado sin subir y candado puesto. Recuperado con `state push` y `force-unlock` (runbook §5) |
| `reconstruccion-20261017T030803Z.log` | la IP quedó *tainted* por ese corte y `prevent_destroy` impidió reemplazarla: se verificó y se quitó la marca |
| `reconstruccion-20261017T030833Z.log` | la fundación ya aplicada; el bootstrap se detuvo a propósito porque el repositorio GitOps aún no tenía la IP |
