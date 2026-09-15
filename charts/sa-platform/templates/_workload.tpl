{{/* ==========================================================================
     _workload.tpl — La plantilla que genera un componente completo.
     ==========================================================================

     Un `include "sa-platform.workload" .` desde el subchart produce los ocho
     objetos que necesita un microservicio:

         ConfigMap · ServiceAccount · Role · RoleBinding
         Deployment · Service · HorizontalPodAutoscaler · PodDisruptionBudget

     Por eso `charts/order-service/templates/main.yaml` tiene una línea. Los
     cinco componentes comparten estructura y difieren solo en valores, que es
     exactamente el caso para el que existe el motor de plantillas: escribir
     cinco Deployments casi iguales y llamarlos "plantillas" porque tienen un
     `{{ .Values.image.tag }}` dentro sería un manifiesto disfrazado.

     ## Cómo saber si la abstracción es correcta

     La prueba es si agregar un componente exige tocar este archivo. No lo
     exige: los cinco subcharts actuales, con formas distintas —uno sin base de
     datos, dos sin broker, uno con sondas exec en lugar de HTTP— salen de
     aquí sin una sola condición sobre su nombre. El día que un componente
     necesite algo que este archivo no contempla, la respuesta es agregar un
     valor con `default`, no un `if eq .Chart.Name`.
     ========================================================================== */}}

{{- define "sa-platform.workload" -}}
{{- $ns := include "sa-platform.namespace" . -}}
{{- $fullname := include "sa-platform.fullname" . -}}
{{- $labels := include "sa-platform.labels" . -}}
{{- $selector := include "sa-platform.selectorLabels" . -}}

{{/* ---------------------------------------------------------------------
     ConfigMap — toda la configuración NO sensible del componente.

     Se genera antes que el Deployment porque su contenido alimenta el
     checksum que va en las anotaciones del pod. Ver `sa-platform.configChecksum`.
     --------------------------------------------------------------------- */}}
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ $fullname }}
  namespace: {{ $ns }}
  labels:
    {{- $labels | nindent 4 }}
data:
  {{- include "sa-platform.configmapData" . | nindent 2 }}

---
{{/* ---------------------------------------------------------------------
     ServiceAccount, Role y RoleBinding.

     La práctica prohíbe usar el ServiceAccount `default`, y con razón: es el
     que comparten todos los pods que no declaran uno, así que cualquier
     permiso que se le conceda alguna vez se le concede a todo el namespace de
     golpe.

     El Role no tiene reglas, y es la respuesta correcta: ninguno de estos
     servicios consulta la API de Kubernetes. Hablan con PostgreSQL, con
     RabbitMQ y entre ellos por HTTP. El mínimo privilegio de quien no necesita
     nada es exactamente ninguno; conceder algo "por si acaso" sería lo
     contrario del principio.

     Lo que sí aporta el ServiceAccount dedicado es identidad —los eventos del
     clúster distinguen quién hizo qué— y, sobre todo, la capacidad de
     conceder un permiso a un solo servicio el día que lo necesite, en lugar de
     a todos a la vez.

     `automountServiceAccountToken: false` cierra el círculo: el token ni
     siquiera llega al contenedor. Un Role vacío ya no autoriza nada, pero un
     token montado sigue siendo una credencial dentro de un pod, y la
     credencial que no está es la que no se roba.
     --------------------------------------------------------------------- */}}
{{- if .Values.serviceAccount.create }}
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ include "sa-platform.serviceAccountName" . }}
  namespace: {{ $ns }}
  labels:
    {{- $labels | nindent 4 }}
automountServiceAccountToken: false

---
{{- end }}
{{- if .Values.rbac.create }}
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: {{ $fullname }}
  namespace: {{ $ns }}
  labels:
    {{- $labels | nindent 4 }}
{{- with .Values.rbac.rules }}
rules:
  {{- toYaml . | nindent 2 }}
{{- else }}
# Sin reglas: este servicio no consulta la API de Kubernetes. Ver la cabecera
# de _workload.tpl.
rules: []
{{- end }}

---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: {{ $fullname }}
  namespace: {{ $ns }}
  labels:
    {{- $labels | nindent 4 }}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: {{ $fullname }}
subjects:
  - kind: ServiceAccount
    name: {{ include "sa-platform.serviceAccountName" . }}
    namespace: {{ $ns }}

---
{{- end }}
{{/* ---------------------------------------------------------------------
     La carga de trabajo: Deployment o Rollout

     ## Por qué el mismo bloque produce dos tipos distintos

     Un `Rollout` de Argo Rollouts es, campo por campo, un `Deployment` con
     otro `apiVersion`, otro `kind` y otra `strategy`. Todo lo que hay debajo
     de `template:` —el pod, sus sondas, su contexto de seguridad, sus
     volúmenes, sus variables— es idéntico, y así lo definió el proyecto a
     propósito para que migrar no obligara a reescribir nada.

     Aprovecharlo aquí tiene una consecuencia que importa para esta práctica:
     el pod que se prueba en el canary es EXACTAMENTE el mismo objeto que
     corría antes. Si el Rollout viviera en una plantilla aparte, las dos
     copias divergirían —una sonda ajustada en un sitio y no en el otro— y la
     entrega progresiva estaría validando algo distinto de lo que se promueve.

     La Práctica 8 activa esto solo para `api-gateway`. El valor está apagado
     por defecto, así que el render de las Prácticas 6 y 7 no cambia ni un
     byte: se puede comprobar con
     `helm template ... | sha256sum` antes y después de este cambio.
     --------------------------------------------------------------------- */}}
{{- if .Values.rollout.enabled }}
apiVersion: argoproj.io/v1alpha1
kind: Rollout
{{- else }}
apiVersion: apps/v1
kind: Deployment
{{- end }}
metadata:
  name: {{ $fullname }}
  namespace: {{ $ns }}
  labels:
    {{- $labels | nindent 4 }}
    app.kubernetes.io/component: {{ .Values.component | default "backend" }}
spec:
  {{- if not .Values.autoscaling.enabled }}
  # Solo se fija `replicas` cuando NO hay HPA.
  #
  # Con el HPA activo, dejar este campo provoca una pelea: Helm lo pone en 2 en
  # cada `upgrade` y el HPA lo vuelve a subir a 5 segundos después. El síntoma
  # es un servicio que se reduce a 2 réplicas en mitad de la prueba de carga
  # cada vez que alguien despliega, y la causa no es evidente mirando ninguno
  # de los dos por separado.
  replicas: {{ .Values.replicaCount }}
  {{- end }}

  revisionHistoryLimit: 3

  {{- if .Values.rollout.enabled }}
  {{/* ---------------------------------------------------------------------
       La estrategia canary.

       ## Qué significa cada paso

       `setWeight: N` manda el N % del tráfico a la versión nueva. `pause`
       detiene el avance hasta que algo lo reanude: un tiempo, o el resultado
       de un análisis.

       ## Por qué el análisis va en `analysis.templates` y no dentro de los pasos

       Hay dos formas de condicionar un canary a un análisis. Una es intercalar
       pasos `analysis:` entre los `setWeight`, que ejecuta el análisis UNA vez
       en ese punto y sigue si pasa. La otra —la de aquí— es declarar un
       análisis **de fondo** que arranca con el rollout y corre durante toda la
       promoción.

       Se eligió la de fondo porque detecta antes. Con análisis por pasos, un
       defecto que aparece treinta segundos después de promover al 30 % no se
       nota hasta el siguiente punto de control; con análisis de fondo, la
       medición que falla aborta el rollout en el momento, esté donde esté.

       Los `pause` con duración son los que hacen que el análisis de fondo
       tenga tiempo de medir: sin ellos, los cuatro `setWeight` se ejecutarían
       en segundos y el canary llegaría al 100 % antes de la primera muestra.
       --------------------------------------------------------------------- */}}
  strategy:
    canary:
      # Los dos Services entre los que se reparte el tráfico. El estable es el
      # que ya existía y al que apunta el Ingress; el canary lo genera este
      # mismo chart más abajo.
      stableService: {{ $fullname }}
      canaryService: {{ $fullname }}-canary

      {{- with .Values.rollout.trafficRouting }}
      {{- if .nginx }}
      # Reparto por tráfico REAL y no por número de réplicas.
      #
      # Sin `trafficRouting`, `setWeight: 10` significa «que el 10 % de los
      # pods sean nuevos», y con 4 réplicas eso es 0 o 1 pod: el porcentaje
      # real depende de cuántas réplicas haya en ese instante. Con el
      # enrutamiento de nginx, Argo Rollouts crea un Ingress `-canary` con la
      # anotación `canary-weight` y el 10 % es un 10 % medido en peticiones.
      #
      # Importa para el informe de incidente, que pide el «porcentaje de
      # tráfico afectado» (§4.2 del enunciado): con este modo es un dato, y
      # sin él sería una estimación.
      trafficRouting:
        nginx:
          stableIngress: {{ .nginx.stableIngress }}
      {{- end }}
      {{- end }}

      {{- with .Values.rollout.analysis }}
      {{- if .enabled }}
      # El análisis de fondo. Arranca con el rollout y no para hasta que el
      # rollout termina o él mismo falla.
      analysis:
        templates:
          {{- range .templates }}
          - templateName: {{ . }}
          {{- end }}
        args:
          # El nombre del Service canary, para que la plantilla de análisis
          # sepa contra QUIÉN probar. Sin esto, las pruebas golpearían al
          # Service estable y medirían la versión vieja: el análisis pasaría
          # siempre y el canary promovería cualquier cosa.
          - name: servicio-canary
            value: {{ $fullname }}-canary
          - name: namespace
            value: {{ $ns }}
      {{- end }}
      {{- end }}

      steps:
        {{- range .Values.rollout.steps }}
        {{- toYaml (list .) | nindent 8 }}
        {{- end }}
  {{- else }}
  strategy:
    type: RollingUpdate
    rollingUpdate:
      # `maxUnavailable: 0` es lo que hace que la actualización no tenga caída.
      #
      # Significa: no retires un pod viejo hasta que uno nuevo esté **Ready**.
      # Con el valor por defecto (25 %), Kubernetes apagaría una parte de las
      # réplicas antes de tener reemplazos listos, y durante esos segundos la
      # capacidad restante atendería toda la carga —o, con 2 réplicas,
      # quedaría 1 sola—. Es el origen de los errores intermitentes durante los
      # despliegues.
      #
      # `maxSurge: 1` acota el costo: durante el cambio hay como mucho un pod
      # extra, no un juego completo duplicado, que es lo que la ResourceQuota
      # del namespace no toleraría con cinco componentes actualizándose.
      #
      # La condición para que esto funcione de verdad es la readiness probe: si
      # marcara "listo" antes de tiempo, el pod nuevo recibiría tráfico sin
      # poder atenderlo y `maxUnavailable: 0` no serviría de nada.
      maxUnavailable: 0
      maxSurge: 1
  {{- end }}

  selector:
    matchLabels:
      {{- $selector | nindent 6 }}

  template:
    metadata:
      annotations:
        {{- include "sa-platform.configChecksum" . | nindent 8 }}
      labels:
        {{- $labels | nindent 8 }}
        app.kubernetes.io/component: {{ .Values.component | default "backend" }}
    spec:
      serviceAccountName: {{ include "sa-platform.serviceAccountName" . }}
      automountServiceAccountToken: false

      # Cuánto espera Kubernetes entre SIGTERM y SIGKILL. Los servicios cierran
      # su pool de PostgreSQL y su conexión al broker en ese margen; sin él,
      # cada reducción del HPA dejaría conexiones colgadas.
      terminationGracePeriodSeconds: {{ .Values.terminationGracePeriodSeconds | default 30 }}

      securityContext:
        {{- include "sa-platform.podSecurityContext" . | nindent 8 }}

      {{- if .Values.affinity.antiAffinity }}
      affinity:
        podAntiAffinity:
          # `preferred` y no `required`: en un clúster de un solo nodo, exigir
          # que las réplicas estén en nodos distintos dejaría todas menos una
          # en Pending para siempre. Con `preferred`, el planificador las
          # separa cuando puede y no bloquea cuando no puede —que es lo que
          # se quiere tanto en el clúster local como en uno real que se quedó
          # con un solo nodo disponible—.
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                topologyKey: kubernetes.io/hostname
                labelSelector:
                  matchLabels:
                    {{- $selector | nindent 20 }}
      {{- end }}

      containers:
        - name: {{ include "sa-platform.name" . }}
          image: {{ include "sa-platform.image" . | quote }}
          imagePullPolicy: {{ .Values.image.pullPolicy | default .Values.global.imagePullPolicy }}

          {{- with .Values.command }}
          command:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- with .Values.args }}
          args:
            {{- toYaml . | nindent 12 }}
          {{- end }}

          {{- if .Values.containerPort }}
          ports:
            # El puerto se llama `http` y las sondas lo referencian por nombre.
            # Cambiar el número en values no obliga entonces a cambiarlo en
            # tres sitios más.
            - name: http
              containerPort: {{ .Values.containerPort }}
              protocol: TCP
          {{- end }}

          securityContext:
            {{- include "sa-platform.containerSecurityContext" . | nindent 12 }}

          envFrom:
            - configMapRef:
                name: {{ $fullname }}
            {{- if .Values.secretSuffix }}
            - secretRef:
                name: sa-platform-{{ .Values.secretSuffix }}
            {{- end }}

          env:
            # La API descendente: el pod se entera de su propio nombre. Aparece
            # en los logs y es lo que permite saber qué réplica atendió una
            # petición cuando hay cinco.
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            {{- with .Values.extraEnv }}
            {{- toYaml . | nindent 12 }}
            {{- end }}

          {{- if .Values.probes.enabled }}
          {{- include "sa-platform.probes" . | nindent 10 }}
          {{- end }}

          # --- Hook preStop: la espera que evita los 503 al desplegar --------
          #
          # ## El problema, que se midió antes de resolverlo
          #
          # Con `maxUnavailable: 0` uno espera cero errores durante un
          # `helm upgrade`. La primera medición dio otra cosa: sondeando el
          # camino real de una petición de usuario cada pocos milisegundos
          # durante un upgrade y un rollback, **2 de 506 peticiones fueron 503**.
          #
          # La causa no es el RollingUpdate sino una carrera que Kubernetes
          # tiene por diseño. Cuando un pod entra en Terminating ocurren dos
          # cosas **en paralelo**, sin ningún orden garantizado entre ellas:
          #
          #   1. El kubelet le manda SIGTERM al contenedor.
          #   2. El controlador de endpoints lo saca del Service, y esa
          #      eliminación tiene que propagarse a kube-proxy en cada nodo y
          #      al Ingress Controller.
          #
          # Si (1) gana la carrera —y suele ganarla, porque (2) atraviesa el
          # apiserver y varios componentes— el proceso deja de aceptar
          # conexiones mientras su dirección sigue en la lista de destinos.
          # Las peticiones que llegan en esa ventana reciben un "connection
          # refused", que el gateway traduce a 503.
          #
          # ## La solución
          #
          # Un `preStop` que simplemente espera. El contenedor sigue atendiendo
          # con normalidad durante esos segundos —el SIGTERM no se envía hasta
          # que el hook termina— mientras la eliminación del endpoint se
          # propaga. Cuando por fin llega el SIGTERM, ya no hay nadie
          # mandándole tráfico.
          #
          # No es un parche: es el patrón recomendado, y la razón de que exista
          # `preStop`. Lo que sí es importante es que
          # `terminationGracePeriodSeconds` ({{ .Values.terminationGracePeriodSeconds | default 30 }} s) sea mayor que esta
          # espera más el tiempo de apagado ordenado; si no, el kubelet mandaría
          # SIGKILL a mitad del cierre.
          lifecycle:
            preStop:
              exec:
                command:
                  - /bin/sh
                  - -c
                  - "sleep {{ .Values.preStopSleepSeconds | default 5 }}"


          resources:
            {{- toYaml .Values.resources | nindent 12 }}

          volumeMounts:
            # `readOnlyRootFilesystem` deja el contenedor entero de solo
            # lectura, así que todo lo escribible tiene que declararse. Estos
            # servicios solo necesitan /tmp: archivos temporales de Python y,
            # en el worker, los marcadores que observan sus sondas.
            - name: tmp
              mountPath: /tmp
            {{- with .Values.extraVolumeMounts }}
            {{- toYaml . | nindent 12 }}
            {{- end }}

      volumes:
        - name: tmp
          emptyDir:
            # Con límite: un emptyDir sin acotar puede llenar el disco del nodo
            # y afectar a todo lo que corra en él, no solo a este pod.
            sizeLimit: {{ .Values.tmpSizeLimit | default "64Mi" }}
        {{- with .Values.extraVolumes }}
        {{- toYaml . | nindent 8 }}
        {{- end }}

{{- if .Values.service.enabled }}
---
{{/* ---------------------------------------------------------------------
     Service — ClusterIP por defecto, LoadBalancer donde la nube lo exige.

     En la Práctica 5 este bloque tenía `type: ClusterIP` escrito a fuego, con
     un comentario que lo defendía: ni NodePort ni LoadBalancer, porque la
     única entrada era el Ingress y terminaba en el gateway. El argumento sigue
     en pie para los cuatro microservicios, y por eso el valor por defecto no
     cambia. Lo que cambió es el enunciado: la Práctica 6 pide exponer el punto
     de entrada desde internet con una dirección pública, y en un clúster
     administrado eso es un Service de tipo LoadBalancer. El proveedor observa
     el objeto, aprovisiona una regla de reenvío con IP pública y la escribe de
     vuelta en `status.loadBalancer.ingress`.

     Lo que NO se relajó: `api-gateway` sigue siendo el único componente que
     declara un tipo distinto de ClusterIP, y la NetworkPolicy que abre su
     puerto 8080 sigue siendo la única entrada del namespace desde fuera. Un
     LoadBalancer sobre `order-service` saltaría el gateway igual que lo habría
     hecho un NodePort en la P5 —sin autenticación, sin límite de peticiones,
     sin correlación— y por eso ningún values lo configura.

     `externalTrafficPolicy` se deja parametrizable porque decide algo visible
     desde la aplicación: con `Cluster` (el valor por defecto de Kubernetes) el
     nodo que recibe el paquete lo reenvía a cualquier pod y hace SNAT, así que
     los logs registran la IP del nodo; con `Local` se conserva la IP real del
     cliente, pero el tráfico solo alcanza pods del nodo que lo recibió y un
     nodo sin réplicas falla el health check. Se usa `Cluster`: con 2 nodos y
     el HPA en 2 réplicas, `Local` dejaría fuera de balanceo a medio clúster.

     `loadBalancerIP` está marcado como deprecado desde Kubernetes 1.24 y sin
     sustituto portable: cada proveedor definió su propia anotación. GKE sigue
     honrándolo, y es lo que permite fijar la IP estática reservada de antemano
     en lugar de descubrir una efímera después de instalar.
     --------------------------------------------------------------------- */}}
apiVersion: v1
kind: Service
metadata:
  name: {{ $fullname }}
  namespace: {{ $ns }}
  labels:
    {{- $labels | nindent 4 }}
    app.kubernetes.io/component: {{ .Values.component | default "backend" }}
spec:
  type: {{ .Values.service.type | default "ClusterIP" }}
  {{- if eq (.Values.service.type | default "ClusterIP") "LoadBalancer" }}
  externalTrafficPolicy: {{ .Values.service.externalTrafficPolicy | default "Cluster" }}
  {{- with .Values.service.loadBalancerIP }}
  loadBalancerIP: {{ . | quote }}
  {{- end }}
  {{- end }}
  ports:
    - name: http
      port: {{ .Values.service.port }}
      targetPort: http
      protocol: TCP
  selector:
    {{- $selector | nindent 4 }}

{{- if .Values.rollout.enabled }}
---
{{/* ---------------------------------------------------------------------
     El Service canary.

     Es gemelo del estable y existe por una razón que no se ve en el YAML:
     Argo Rollouts INYECTA en el selector de cada uno la etiqueta
     `rollouts-pod-template-hash` correspondiente —la del ReplicaSet nuevo en
     este, la del viejo en el estable—. Por eso aquí el selector se escribe
     igual en los dos: el controlador lo especializa en caliente.

     Sin este Service, el canary no tendría una dirección propia y las pruebas
     de análisis no podrían golpear SOLO a la versión nueva. Medirían la mezcla
     de las dos versiones, y con un 10 % de tráfico defectuoso la media
     seguiría dentro del umbral: el análisis aprobaría una versión rota.

     Deliberadamente SIN `type: LoadBalancer` aunque el estable lo tenga: el
     canary no se expone a internet, solo se alcanza desde dentro del clúster
     —que es desde donde corre el análisis—.
     --------------------------------------------------------------------- */}}
apiVersion: v1
kind: Service
metadata:
  name: {{ $fullname }}-canary
  namespace: {{ $ns }}
  labels:
    {{- $labels | nindent 4 }}
    app.kubernetes.io/component: {{ .Values.component | default "backend" }}
    sa.usac.edu.gt/rol: canary
spec:
  type: ClusterIP
  ports:
    - name: http
      port: {{ .Values.service.port }}
      targetPort: http
      protocol: TCP
  selector:
    {{- $selector | nindent 4 }}
{{- end }}
{{- end }}

{{- if .Values.autoscaling.enabled }}
---
{{/* ---------------------------------------------------------------------
     HorizontalPodAutoscaler

     ## Por qué el HPA necesita que el contenedor declare `requests`

     El HPA no mide CPU en valores absolutos: mide el **porcentaje respecto a
     `resources.requests.cpu`**. Un contenedor sin requests no tiene
     denominador, el HPA reporta `<unknown>/70%` y no escala nunca. Es la causa
     más frecuente de un HPA que parece bien configurado y no hace nada; por
     eso el LimitRange del namespace pone requests por defecto y estos values
     los declaran explícitamente.

     ## Por qué 70 % y no 90 %

     El umbral tiene que dejar margen para lo que tarda escalar: metrics-server
     agrega cada 15 segundos, el HPA evalúa cada 15, y el pod nuevo tarda en
     arrancar y pasar su readiness. Con el umbral al 90 %, cuando el HPA
     reacciona los pods existentes ya están saturados y el servicio se degrada
     durante ese medio minuto. Al 70 % queda holgura para absorber la subida
     mientras llegan las réplicas.
     --------------------------------------------------------------------- */}}
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: {{ $fullname }}
  namespace: {{ $ns }}
  labels:
    {{- $labels | nindent 4 }}
spec:
  scaleTargetRef:
    {{- if .Values.rollout.enabled }}
    # El HPA tiene que apuntar al Rollout, no a un Deployment.
    #
    # Un Rollout no crea ningún Deployment: gestiona ReplicaSets él mismo. Un
    # HPA que apunte a `apps/v1 Deployment` con este nombre busca un objeto que
    # no existe, reporta `<unknown>` como métrica y no escala jamás —el mismo
    # síntoma que un contenedor sin `requests`, y con una causa completamente
    # distinta—.
    #
    # Argo Rollouts implementa el subrecurso `/scale`, así que el HPA lo
    # maneja exactamente igual que a un Deployment una vez apunta bien.
    apiVersion: argoproj.io/v1alpha1
    kind: Rollout
    {{- else }}
    apiVersion: apps/v1
    kind: Deployment
    {{- end }}
    name: {{ $fullname }}
  minReplicas: {{ .Values.autoscaling.minReplicas }}
  maxReplicas: {{ .Values.autoscaling.maxReplicas }}
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: {{ .Values.autoscaling.targetCPUUtilizationPercentage }}
    {{- if .Values.autoscaling.targetMemoryUtilizationPercentage }}
    - type: Resource
      resource:
        name: memory
        target:
          type: Utilization
          averageUtilization: {{ .Values.autoscaling.targetMemoryUtilizationPercentage }}
    {{- end }}
  behavior:
    scaleUp:
      # Reaccionar rápido a la subida: la carga ya está ahí y cada segundo de
      # espera son peticiones lentas o perdidas.
      stabilizationWindowSeconds: 0
      policies:
        - type: Percent
          value: 100
          periodSeconds: 15
    scaleDown:
      # Bajar despacio. Cinco minutos de ventana evitan el "flapping": un
      # tráfico con picos cortos haría subir y bajar réplicas continuamente, y
      # cada ciclo cuesta un arranque completo con su startup probe. Es también
      # lo que hace que el descenso sea observable en la evidencia en lugar de
      # ocurrir en un parpadeo.
      stabilizationWindowSeconds: 300
      policies:
        - type: Pods
          value: 1
          periodSeconds: 60
{{- end }}

{{- if .Values.podDisruptionBudget.enabled }}
---
{{/* ---------------------------------------------------------------------
     PodDisruptionBudget

     Protege contra las interrupciones **voluntarias**: drenar un nodo para
     mantenimiento, una actualización del clúster, un `kubectl drain`. No
     protege contra un nodo que se cae —eso es involuntario y nadie pide
     permiso—.

     Sin PDB, `kubectl drain` desaloja todos los pods de un nodo a la vez y un
     servicio con sus dos réplicas en ese nodo desaparece. Con `minAvailable:
     1`, el desalojo se hace de uno en uno y espera a que el reemplazo esté
     listo.

     `minAvailable` y no `maxUnavailable` a propósito: con el HPA moviendo el
     número de réplicas entre 2 y 5, un porcentaje se traduce en un número
     distinto según el momento. `minAvailable: 1` significa lo mismo siempre.
     --------------------------------------------------------------------- */}}
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: {{ $fullname }}
  namespace: {{ $ns }}
  labels:
    {{- $labels | nindent 4 }}
spec:
  minAvailable: {{ .Values.podDisruptionBudget.minAvailable }}
  selector:
    matchLabels:
      {{- $selector | nindent 6 }}
{{- end }}
{{- end -}}
