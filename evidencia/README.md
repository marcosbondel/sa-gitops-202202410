# Evidencia pública

Espejo de `P8/docs/evidencias/` del repositorio de código.

Existe porque **el repositorio de código es privado**, y el enunciado (§4.1)
exige que los enlaces de la tabla de entrega sean accesibles sin
autenticación. Los archivos se copian con
`P8/scripts/03-publicar-gitops.sh`.

Cada archivo lleva en su cabecera la fecha y el comando que lo produjo, para
que cualquiera pueda repetirlo y comparar.

| Archivo | Qué demuestra |
|---|---|
| `01-terraform.txt` | El plan no propone cambios: el clúster coincide con el código. |
| `02-terraform-apply.txt` | Un ciclo `plan` + `apply` real. |
| `03-recursos-de-terraform.txt` | Qué posee Terraform, y qué **no** pueden hacer sus cuentas. |
| `04-despliegue-rechazado.txt` | Las tres políticas de Kyverno rechazando. |
| `05-calibracion-linea-base.txt` | La medición de la que salen los umbrales. |
| `06-promocion-canary-exitosa.txt` | Un canary que recorre los 4 pasos. |
| `07-fallo-inducido-y-reversion.txt` | **La reversión automática**, cronometrada. |
| `08-argocd.txt` | Las 8 aplicaciones `Synced` y `Healthy`. |
| `09-politicas.txt` | Las políticas, aplicadas por ArgoCD y no a mano. |
| `10-secretos.txt` | Lo versionado es criptograma, no credenciales. |
| `11-sin-despliegue-directo.txt` | El pipeline no puede escribir en el clúster. |
| `12-pr-bloqueado-por-cve.txt` | **Un Pull Request detenido** por CVE-2019-10744. |
| `13-cadena-de-suministro.txt` | Trivy, SBOM y firmas verificadas con Cosign. |
| `14-ciclo-completo.txt` | **Etiqueta → PR → merge → ArgoCD → canary**, de punta a punta. |
