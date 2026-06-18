{{- define "weather-ml.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "weather-ml.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "weather-ml.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "weather-ml.labels" -}}
helm.sh/chart: {{ include "weather-ml.chart" . }}
{{ include "weather-ml.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "weather-ml.selectorLabels" -}}
app.kubernetes.io/name: {{ include "weather-ml.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "weather-ml.apiImage" -}}
{{- printf "%s/%s:%s" .Values.image.registry .Values.api.image.repository .Values.api.image.tag }}
{{- end }}

{{- define "weather-ml.mlImage" -}}
{{- printf "%s/%s:%s" .Values.image.registry .Values.ml.image.repository .Values.ml.image.tag }}
{{- end }}

{{/* Resolves to an existing claim name or the chart-managed PVC */}}
{{- define "weather-ml.modelsPvcName" -}}
{{- if .Values.persistence.existingClaim }}
{{- .Values.persistence.existingClaim }}
{{- else }}
{{- printf "%s-models" (include "weather-ml.fullname" .) }}
{{- end }}
{{- end }}
