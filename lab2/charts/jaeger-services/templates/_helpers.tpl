{{- define "jaeger-services.name" -}}
{{- .Chart.Name -}}
{{- end -}}

{{- define "jaeger-services.labels" -}}
app.kubernetes.io/name: {{ include "jaeger-services.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}
