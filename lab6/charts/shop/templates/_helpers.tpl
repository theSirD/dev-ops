{{- define "shop.labels" -}}
app.kubernetes.io/name: shop
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "shop.selectorLabels" -}}
app.kubernetes.io/name: shop
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
