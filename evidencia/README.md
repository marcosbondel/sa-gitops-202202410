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
| `02-terraform-apply.txt` | Un ciclo `plan` + `apply` real: ingress-nginx pasa a Terraform. |
| `03-recursos-de-terraform.txt` | Qué posee Terraform, y qué **no** pueden hacer sus cuentas. |
| `04-despliegue-rechazado.txt` | Las **cuatro** políticas de Kyverno rechazando, la de firma de Cosign incluida. |
| `05-calibracion-linea-base.txt` | La medición de la que salen los umbrales. |
| `06-promocion-canary-exitosa.txt` | La 1.2.0 promovida en stage y en prod: **una puerta de análisis tras cada escalón**. |
| `07-fallo-inducido-y-reversion.txt` | **La reversión automática** de `1.2.1-fallo`, cronometrada. |
| `08-argocd.txt` | Las 8 aplicaciones `Synced` y `Healthy`. |
| `09-politicas.txt` | Las políticas, aplicadas por ArgoCD y no a mano. |
| `10-secretos.txt` | Lo versionado es criptograma, no credenciales. |
| `11-sin-despliegue-directo.txt` | Ningún workflow del repositorio puede escribir en el clúster. |
| `12-pr-bloqueado-por-cve.txt` | **Un Pull Request detenido** por CVE-2019-10744. |
| `13-cadena-de-suministro.txt` | Trivy y SBOM por arquitectura, firmas verificadas con Cosign sin credenciales, y el clúster verificándolas al admitir. |
| `14-ciclo-completo.txt` | **Etiqueta → PR → merge → ArgoCD → canary → prod**, de punta a punta. |
| `15-incidentes-reales.txt` | Dos fallos no provocados que el canary también contuvo. |
