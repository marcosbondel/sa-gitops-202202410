{{/* ==========================================================================
     _helpers.tpl — Lo que los tres AnalysisTemplate comparten.
     ========================================================================== */}}

{{/*
Etiquetas comunes.
*/}}
{{- define "analisis.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: sa-platform
sa.usac.edu.gt/practica: p8
{{- end -}}

{{/*
Contexto de seguridad del pod de prueba.

Los Jobs de análisis corren en el MISMO namespace que la plataforma, así que
pasan por las mismas políticas de admisión: Pod Security Admission en modo
`baseline` y las tres ClusterPolicy de Kyverno. Un pod de prueba que corriera
como root sería rechazado exactamente igual que un microservicio.

Es a propósito. Un control de admisión que exime a las herramientas de prueba
deja abierta la vía más cómoda para saltárselo: basta con llamar «prueba» a lo
que se quiera colar.
*/}}
{{- define "analisis.podSecurityContext" -}}
runAsNonRoot: true
runAsUser: 65532
runAsGroup: 65532
fsGroup: 65532
seccompProfile:
  type: RuntimeDefault
{{- end -}}

{{- define "analisis.containerSecurityContext" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
runAsNonRoot: true
capabilities:
  drop:
    - ALL
{{- end -}}

{{/*
Los dos volúmenes que necesita cualquier pod de prueba.

  · `pruebas`  — el ConfigMap con los scripts, en solo lectura.
  · `temporal` — un emptyDir en /tmp. Es obligatorio por
    `readOnlyRootFilesystem: true`: sin él, el `mktemp` de los scripts de shell
    falla con «Read-only file system» y k6 no puede escribir su resumen.

`defaultMode: 0555` en el ConfigMap para que los scripts sean ejecutables. Sin
eso habría que invocarlos como `sh /pruebas/humo.sh`, que funciona, pero
esconde que el script declara su propio intérprete.
*/}}
{{- define "analisis.volumenes" -}}
- name: pruebas
  configMap:
    name: sa-p8-pruebas
    defaultMode: 0555
- name: temporal
  emptyDir:
    sizeLimit: 32Mi
{{- end -}}

{{- define "analisis.montajes" -}}
- name: pruebas
  mountPath: /pruebas
  readOnly: true
- name: temporal
  mountPath: /tmp
{{- end -}}

{{/*
Los dos argumentos que el Rollout inyecta en cada plantilla.

Se declaran en los tres AnalysisTemplate porque `strategy.canary.analysis.args`
del Rollout los pasa a todos por igual. Si una plantilla no los declarara,
Argo Rollouts fallaría con «args.<nombre> was not resolved», que es un error
claro pero que aparece a mitad del rollout y no al aplicarlo.
*/}}
{{- define "analisis.args" -}}
- name: servicio-canary
- name: namespace
{{- end -}}
