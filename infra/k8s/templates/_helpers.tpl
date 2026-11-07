{{- define "jenie.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "jenie.fullname" -}}
{{- printf "%s-%s" (include "jenie.name" .) .Values.environment | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "jenie.labels" -}}
app.kubernetes.io/name: {{ include "jenie.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: jenie-helpdesk-ai
environment: {{ .Values.environment }}
{{- end -}}

{{- define "jenie.selectorLabels" -}}
app.kubernetes.io/name: {{ include "jenie.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "jenie.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- include "jenie.fullname" . -}}
{{- else -}}
default
{{- end -}}
{{- end -}}

{{- define "jenie.apiImage" -}}
{{- $tag := .Values.image.api.tag | default .Chart.AppVersion -}}
{{- printf "%s/%s:%s" .Values.image.registry .Values.image.api.repository $tag -}}
{{- end -}}

{{- define "jenie.workerImage" -}}
{{- $tag := .Values.image.worker.tag | default .Chart.AppVersion -}}
{{- printf "%s/%s:%s" .Values.image.registry .Values.image.worker.repository $tag -}}
{{- end -}}

{{/*
Environment shared by the API and the indexer. DATABASE_URL is deliberately
absent: it comes from a Secret reference, never from a templated value, so a
rendered manifest never contains the credential.
*/}}
{{- define "jenie.env" -}}
- name: ENVIRONMENT
  value: {{ .Values.environment | quote }}
- name: LOG_LEVEL
  value: {{ .Values.config.logLevel | quote }}
- name: EMBEDDING_PROVIDER
  value: {{ .Values.config.embeddingProvider | quote }}
- name: EMBEDDING_DIM
  value: {{ .Values.config.embeddingDim | quote }}
- name: DATA_PATH
  value: {{ .Values.config.dataPath | quote }}
{{- if .Values.config.otelEndpoint }}
- name: OTEL_EXPORTER_OTLP_ENDPOINT
  value: {{ .Values.config.otelEndpoint | quote }}
{{- end }}
- name: DATABASE_URL
  valueFrom:
    secretKeyRef:
      name: {{ .Values.database.existingSecret }}
      key: {{ .Values.database.secretKey }}
{{- end -}}

{{/*
Hardened by default. Every one of these is a control a reviewer will look
for, and defaulting them here means a new workload cannot forget them.
*/}}
{{- define "jenie.securityContext" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
runAsNonRoot: true
runAsUser: 10001
capabilities:
  drop: ["ALL"]
seccompProfile:
  type: RuntimeDefault
{{- end -}}
