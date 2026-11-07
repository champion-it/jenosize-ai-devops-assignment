{{/*
The pod specification, shared by the Deployment and the Rollout.

Kept in one place so the two cannot drift. A probe or a security control
added to one and forgotten in the other would mean the canary path and
the plain path run different pods, which is the kind of difference that
only surfaces during an incident.
*/}}
{{- define "jenie.apiPodSpec" -}}
serviceAccountName: {{ include "jenie.serviceAccountName" . }}
automountServiceAccountToken: false
terminationGracePeriodSeconds: {{ .Values.api.terminationGracePeriodSeconds }}
securityContext:
  runAsNonRoot: true
  runAsUser: 10001
  fsGroup: 10001
# Spread across nodes so losing one node cannot take out every replica.
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: kubernetes.io/hostname
    whenUnsatisfiable: ScheduleAnyway
    labelSelector:
      matchLabels:
        {{- include "jenie.selectorLabels" . | nindent 8 }}
        app.kubernetes.io/component: api
containers:
  - name: api
    image: {{ include "jenie.apiImage" . }}
    imagePullPolicy: {{ .Values.image.pullPolicy }}
    ports:
      - name: http
        containerPort: {{ .Values.api.port }}
    env:
      {{- include "jenie.env" . | nindent 6 }}
      - name: RATE_LIMIT_PER_MINUTE
        value: {{ .Values.config.rateLimitPerMinute | quote }}
      - name: LLM_PROVIDER
        value: {{ .Values.config.llmProvider | quote }}
      - name: LLM_MODEL
        value: {{ .Values.config.llmModel | quote }}
      - name: TOP_K
        value: {{ .Values.config.topK | quote }}
    # startup gates the other two: a slow first boot must not be read
    # as a liveness failure and restart the pod in a loop.
    startupProbe:
      httpGet: { path: /readyz, port: http }
      periodSeconds: 5
      failureThreshold: 12
    readinessProbe:
      httpGet: { path: /readyz, port: http }
      periodSeconds: 10
      timeoutSeconds: 3
    livenessProbe:
      # /healthz deliberately does not touch the database, so a
      # database blip cannot restart otherwise healthy pods.
      httpGet: { path: /healthz, port: http }
      periodSeconds: 30
      timeoutSeconds: 3
      failureThreshold: 3
    lifecycle:
      preStop:
        # Let the endpoint be removed from Service endpoints before the
        # process starts shutting down, or in-flight requests are sent
        # to a pod that is already draining.
        exec:
          command: ["sleep", "5"]
    resources:
      {{- toYaml .Values.api.resources | nindent 6 }}
    securityContext:
      {{- include "jenie.securityContext" . | nindent 6 }}
    volumeMounts:
      - name: tmp
        mountPath: /tmp
volumes:
  # readOnlyRootFilesystem is on, so anything that writes needs an
  # explicit, bounded place to do it.
  - name: tmp
    emptyDir:
      sizeLimit: 64Mi
{{- end -}}
