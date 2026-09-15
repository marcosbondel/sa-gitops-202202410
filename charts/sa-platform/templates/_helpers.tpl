{{/* ==========================================================================
     _helpers.tpl — La biblioteca de plantillas del chart
     ==========================================================================

     Este archivo es la razón de que los cinco subcharts sean casi idénticos y
     de que ninguno contenga un Deployment escrito a mano.

     ## Por qué vive en el chart padre y no en un library chart

     Helm resuelve los nombres de plantilla en un espacio **global** que abarca
     el chart padre y todos sus subcharts. Un `define` escrito aquí es visible
     desde `charts/order-service/templates/`, sin declarar nada.

     La alternativa ortodoxa —un library chart en `charts/sa-common`— exigiría
     que cada uno de los cinco subcharts lo declarara como dependencia y
     acabaría con cinco copias del mismo .tgz dentro del paquete. Para un chart
     que nunca se publica por piezas, es ceremonia sin beneficio. Si mañana los
     subcharts se publicaran por separado, ese sería el momento de extraerlo.

     ## Qué NO se hace aquí

     No se toman decisiones. Estas plantillas leen `.Values` y renderizan; qué
     valores tiene cada servicio se decide en su propio `values.yaml`. Mezclar
     ambas cosas —un `if eq .Chart.Name "order-service"` aquí dentro— haría que
     agregar un servicio obligara a editar este archivo, que es exactamente el
     acoplamiento que el chart padre existe para evitar.
     ========================================================================== */}}


{{/* --------------------------------------------------------------------------
     Nombres
     -------------------------------------------------------------------------- */}}

{{/*
Nombre corto del componente. Dentro de un subchart, `.Chart.Name` ya es el
nombre del componente ("order-service"); en el chart padre es "sa-platform".
*/}}
{{- define "sa-platform.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Nombre completo del recurso: <release>-<componente>.

Se trunca a 63 caracteres porque es el límite de una etiqueta de DNS, y los
nombres de Service se convierten en nombres DNS dentro del clúster. Superarlo
no da un error claro: da un Service que nadie resuelve.

Si el nombre del release ya contiene el del chart no se repite, para evitar
`sa-platform-sa-platform`.
*/}}
{{- define "sa-platform.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/* Identificador chart-versión, para la etiqueta helm.sh/chart. */}}
{{- define "sa-platform.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Namespace de destino.

Se resuelve desde `.Values.global.namespace` con `.Release.Namespace` como
respaldo, y **todos** los recursos lo declaran explícitamente. Podría omitirse
—Helm inyecta el namespace del release— pero entonces `helm template` sin
`-n` produciría manifiestos sin namespace, y esos manifiestos son justo los que
uno pega en una revisión o guarda como evidencia.
*/}}
{{- define "sa-platform.namespace" -}}
{{- default .Release.Namespace .Values.global.namespace -}}
{{- end -}}


{{/* --------------------------------------------------------------------------
     Etiquetas
     -------------------------------------------------------------------------- */}}

{{/*
Etiquetas comunes de todo recurso del chart.

Se usan las `app.kubernetes.io/*` recomendadas por Kubernetes y no unas
propias: `kubectl` y las herramientas del ecosistema las entienden, así que
`kubectl get pods -l app.kubernetes.io/part-of=sa-platform` devuelve la
plataforma entera sin que nadie tenga que aprenderse un convenio local.
*/}}
{{- define "sa-platform.labels" -}}
helm.sh/chart: {{ include "sa-platform.chart" . }}
{{ include "sa-platform.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: sa-platform
{{- end -}}

{{/*
Etiquetas de selección.

Son un subconjunto deliberadamente pequeño y **estable**. El `selector` de un
Deployment es inmutable: si aquí entrara `app.kubernetes.io/version`, el primer
`helm upgrade` con una imagen nueva fallaría con "field is immutable" y el
release quedaría a medio aplicar. Es un error que solo aparece en el segundo
despliegue, cuando ya nadie recuerda haber tocado las etiquetas.
*/}}
{{- define "sa-platform.selectorLabels" -}}
app.kubernetes.io/name: {{ include "sa-platform.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}


{{/* --------------------------------------------------------------------------
     Imagen
     -------------------------------------------------------------------------- */}}

{{/*
Referencia completa de la imagen.

`.Values.image.tag` se deja vacío por defecto y cae a `.Chart.AppVersion`: así
la versión de la aplicación se declara en un solo lugar (Chart.yaml) y no en
cinco values distintos que se desincronizan.

`required` sobre el repositorio, porque un Deployment sin imagen no falla al
instalar: falla minutos después con ImagePullBackOff, y el mensaje no dice qué
values faltaba.
*/}}
{{- define "sa-platform.image" -}}
{{- $registry := .Values.image.registry | default .Values.global.imageRegistry -}}
{{- $repository := required (printf "Falta image.repository para %s" (include "sa-platform.name" .)) .Values.image.repository -}}
{{- $tag := .Values.image.tag | default .Chart.AppVersion -}}
{{- if $registry -}}
{{- printf "%s/%s:%s" $registry $repository $tag -}}
{{- else -}}
{{- printf "%s:%s" $repository $tag -}}
{{- end -}}
{{- end -}}


{{/* --------------------------------------------------------------------------
     Seguridad
     -------------------------------------------------------------------------- */}}

{{/*
Contexto de seguridad del pod.

`runAsNonRoot: true` es la línea que hace que Kubernetes se **niegue a
arrancar** el contenedor si su imagen corre como root, en lugar de dejarlo
correr y confiar en que alguien lo revisó. Es una comprobación en tiempo de
admisión, no una recomendación.

`fsGroup` importa cuando hay volúmenes: sin él, un emptyDir montado pertenece a
root y el proceso no root no puede escribir en /tmp.

`seccompProfile: RuntimeDefault` restringe las llamadas al sistema que el
contenedor puede hacer al conjunto que Docker/containerd considera seguro. Es
gratis en rendimiento y cierra familias enteras de escapes del contenedor.
*/}}
{{- define "sa-platform.podSecurityContext" -}}
runAsNonRoot: true
runAsUser: {{ .Values.securityContext.runAsUser | default 10001 }}
runAsGroup: {{ .Values.securityContext.runAsGroup | default 10001 }}
fsGroup: {{ .Values.securityContext.fsGroup | default 10001 }}
seccompProfile:
  type: RuntimeDefault
{{- end -}}

{{/*
Contexto de seguridad del contenedor.

  · `readOnlyRootFilesystem` — el proceso no puede escribir en su propia imagen.
    Un atacante que logre ejecución de código no puede dejar un binario ni
    modificar el que corre. Exige que todo lo escribible sea un volumen
    declarado, y por eso cada pod monta /tmp como emptyDir.

  · `allowPrivilegeEscalation: false` — bloquea setuid. Sin esto, `runAsNonRoot`
    es más débil de lo que parece: un binario setuid dentro del contenedor
    podría recuperar privilegios.

  · `drop: [ALL]` — se quitan **todas** las capabilities de Linux y no se
    devuelve ninguna. Ninguno de estos servicios abre puertos por debajo de
    1024 ni toca la red a bajo nivel, así que no necesita ninguna.
*/}}
{{- define "sa-platform.containerSecurityContext" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
runAsNonRoot: true
runAsUser: {{ .Values.securityContext.runAsUser | default 10001 }}
capabilities:
  drop:
    - ALL
{{- end -}}


{{/* --------------------------------------------------------------------------
     Configuración: ConfigMap y su checksum
     -------------------------------------------------------------------------- */}}

{{/*
Contenido del ConfigMap del componente, como pares clave-valor.

Está en su propia plantilla —y no dentro del ConfigMap— para poder usarlo dos
veces: una para renderizar el objeto y otra para calcular su checksum. Si el
contenido se escribiera dos veces, el checksum podría dejar de corresponder al
ConfigMap sin que nadie lo note.

`range` recorre el mapa `.Values.config` ordenado por clave (Helm ordena las
claves de un `range` sobre mapas), lo cual importa: si el orden variara, el
checksum cambiaría en cada render y los pods se reiniciarían sin motivo.

Todos los valores se pasan por `quote`. Sin eso, un valor como `8000` o `true`
se renderiza como número o booleano y Kubernetes rechaza el ConfigMap: los
valores de `data` deben ser cadenas.
*/}}
{{- define "sa-platform.configmapData" -}}
{{- range $key, $value := .Values.config }}
{{ $key }}: {{ $value | quote }}
{{- end }}
{{- $global := $.Values.global }}
{{- /*
     Referencias a otros Services del release.

     Se declaran como {nombre, puerto} y la URL se compone aquí, con el nombre
     del release por delante. Escribirlas completas en values.yaml —
     "http://sa-platform-auth-service:8000"— habría atado el chart a un nombre
     de release concreto en cinco archivos distintos, y el fallo resultante
     (pods sanos que no resuelven a sus vecinos) es de los que cuesta rastrear.
   */}}
{{- range $key, $ref := $.Values.serviceRefs }}
{{ $key }}: {{ printf "http://%s-%s:%v" $.Release.Name $ref.name $ref.port | quote }}
{{- end }}
LOG_LEVEL: {{ $global.logLevel | default "INFO" | quote }}
APP_ENV: {{ $global.env | default "development" | quote }}
APP_VERSION: {{ $.Chart.AppVersion | quote }}
{{- if $.Values.usesDatabase }}
POSTGRES_HOST: {{ include "sa-platform.postgresqlHost" $ | quote }}
POSTGRES_PORT: {{ $global.postgresql.port | quote }}
POSTGRES_DB: {{ required "Falta postgresDatabase" $.Values.postgresDatabase | quote }}
POSTGRES_USER: {{ required "Falta postgresUser" $.Values.postgresUser | quote }}
{{- end }}
{{- if $.Values.usesBroker }}
RABBITMQ_HOST: {{ include "sa-platform.rabbitmqHost" $ | quote }}
RABBITMQ_PORT: {{ $global.rabbitmq.port | quote }}
RABBITMQ_VHOST: {{ $global.rabbitmq.vhost | default "/" | quote }}
RABBITMQ_USER: {{ $global.rabbitmq.username | quote }}
RABBITMQ_EXCHANGE: {{ $global.rabbitmq.exchange | quote }}
{{- end }}
{{- end -}}

{{/*
Anotaciones que fuerzan el reinicio de los pods cuando cambia la configuración.

Sin esto, `helm upgrade --set config.LOG_LEVEL=DEBUG` actualiza el ConfigMap y
**no pasa nada**: el Deployment no cambió, así que Kubernetes no crea pods
nuevos, y los que corren siguen con los valores que leyeron al arrancar. El
síntoma es desconcertante —"cambié la configuración y el servicio la ignora"—
y la causa es que las variables de entorno se resuelven una sola vez, al crear
el contenedor.

Meter el hash del contenido en una anotación del **pod template** hace que el
template cambie cuando cambia la configuración, y eso sí dispara un
RollingUpdate. Con `maxUnavailable: 0`, además, sin cortar el servicio.

El Secret recibe el mismo tratamiento, por el mismo motivo: rotar una
contraseña sin reiniciar deja a los pods usando la anterior.
*/}}
{{- define "sa-platform.configChecksum" -}}
checksum/config: {{ include "sa-platform.configmapData" . | sha256sum }}
{{- if .Values.secretSuffix }}
{{- /*
   El contenido del Secret NO se puede hashear desde aquí: vive en el chart
   padre y una plantilla no puede leer los objetos que otra genera. Se hashea
   en su lugar `global.secretsRevision`, un contador que se incrementa a mano
   al rotar una credencial.

   Es menos automático que el checksum del ConfigMap y hay que decirlo: si
   alguien cambia una contraseña en el values sin tocar la revisión, los pods
   seguirán usando la anterior hasta el próximo reinicio. La alternativa
   —hashear los valores de `secrets`— pondría un derivado de las contraseñas en
   una anotación visible con `kubectl describe pod`, que es peor: un hash es
   material para un ataque de diccionario, y las anotaciones no están
   protegidas por el RBAC de Secrets.
*/}}
checksum/secret: {{ printf "%s-%s" .Values.secretSuffix (.Values.global.secretsRevision | default "0") | sha256sum }}
{{- end }}
{{- end -}}


{{/* --------------------------------------------------------------------------
     Sondas
     -------------------------------------------------------------------------- */}}

{{/*
Las tres sondas de un contenedor.

Soporta dos formas, elegidas con `.Values.probes.kind`:

  · `http` — para los servicios que atienden HTTP. Cada sonda apunta a una ruta
    distinta, y esa separación es el punto: la liveness NO consulta la base de
    datos y la readiness SÍ. Si ambas apuntaran a lo mismo, una base caída
    reiniciaría todos los pods en cascada en lugar de sacarlos del balanceador
    y dejarlos volver solos.

  · `exec` — para el worker del broker, que no atiende HTTP. Comprueba la
    frescura de un archivo que el proceso toca periódicamente, lo que detecta
    un event loop colgado y no solo un proceso muerto: un consumidor bloqueado
    sigue "vivo" para el kernel y deja de drenar la cola.

Los valores no se codifican aquí. Cada servicio declara los suyos en su
values.yaml, porque un servicio que arranca en 2 segundos y otro que tarda 30
no pueden compartir umbrales.
*/}}
{{- define "sa-platform.probes" -}}
{{- $p := .Values.probes -}}
{{- if eq ($p.kind | default "http") "http" }}
startupProbe:
  httpGet:
    path: {{ $p.startup.path | default "/health/startup" }}
    port: http
  periodSeconds: {{ $p.startup.periodSeconds | default 5 }}
  timeoutSeconds: {{ $p.startup.timeoutSeconds | default 3 }}
  failureThreshold: {{ $p.startup.failureThreshold | default 30 }}
livenessProbe:
  httpGet:
    path: {{ $p.liveness.path | default "/health" }}
    port: http
  periodSeconds: {{ $p.liveness.periodSeconds | default 15 }}
  timeoutSeconds: {{ $p.liveness.timeoutSeconds | default 3 }}
  failureThreshold: {{ $p.liveness.failureThreshold | default 3 }}
readinessProbe:
  httpGet:
    path: {{ $p.readiness.path | default "/health/ready" }}
    port: http
  periodSeconds: {{ $p.readiness.periodSeconds | default 10 }}
  timeoutSeconds: {{ $p.readiness.timeoutSeconds | default 3 }}
  failureThreshold: {{ $p.readiness.failureThreshold | default 3 }}
  successThreshold: 1
{{- else }}
startupProbe:
  exec:
    command: ["/bin/sh", "-c", {{ $p.startup.command | quote }}]
  periodSeconds: {{ $p.startup.periodSeconds | default 5 }}
  timeoutSeconds: {{ $p.startup.timeoutSeconds | default 3 }}
  failureThreshold: {{ $p.startup.failureThreshold | default 30 }}
livenessProbe:
  exec:
    command: ["/bin/sh", "-c", {{ $p.liveness.command | quote }}]
  periodSeconds: {{ $p.liveness.periodSeconds | default 20 }}
  timeoutSeconds: {{ $p.liveness.timeoutSeconds | default 5 }}
  failureThreshold: {{ $p.liveness.failureThreshold | default 3 }}
readinessProbe:
  exec:
    command: ["/bin/sh", "-c", {{ $p.readiness.command | quote }}]
  periodSeconds: {{ $p.readiness.periodSeconds | default 10 }}
  timeoutSeconds: {{ $p.readiness.timeoutSeconds | default 5 }}
  failureThreshold: {{ $p.readiness.failureThreshold | default 3 }}
{{- end }}
{{- end -}}


{{/* --------------------------------------------------------------------------
     ServiceAccount
     -------------------------------------------------------------------------- */}}

{{- define "sa-platform.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "sa-platform.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}


{{/* --------------------------------------------------------------------------
     Direcciones de las dependencias y de los demás servicios
     -------------------------------------------------------------------------- */}}

{{/*
Host del Service de PostgreSQL.

Se **calcula** a partir del nombre del release en lugar de escribirse en
values.yaml. La diferencia importa: el subchart de Bitnami nombra su Service
`<release>-postgresql`, así que un valor literal solo sería correcto para un
release concreto. Instalar el mismo chart con otro nombre dejaría a los cinco
servicios buscando un host que no existe —y arrancarían igual, porque el error
solo aparece en la primera conexión—.

`.Values.global.postgresql.host` sigue existiendo como sobreescritura, para el
caso de apuntar a una base externa (un RDS, por ejemplo). Vacío por defecto
significa "usa la del release".
*/}}
{{- define "sa-platform.postgresqlHost" -}}
{{- .Values.global.postgresql.host | default (printf "%s-postgresql" .Release.Name) -}}
{{- end -}}

{{/* Host del Service de RabbitMQ, por el mismo razonamiento. */}}
{{- define "sa-platform.rabbitmqHost" -}}
{{- .Values.global.rabbitmq.host | default (printf "%s-rabbitmq" .Release.Name) -}}
{{- end -}}
