{{/* Value of app.kubernetes.io/part-of. */}}
{{- define "app.partOf" -}}
{{- default .Release.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Selector labels. Call with (dict "root" $ "name" $name). */}}
{{- define "app.selectorLabels" -}}
app.kubernetes.io/name: {{ .name }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
{{- end -}}

{{/* Common labels. Call with (dict "root" $ "name" $name "component" $component). */}}
{{- define "app.labels" -}}
{{ include "app.selectorLabels" . }}
app.kubernetes.io/component: {{ .name }}
app.kubernetes.io/part-of: {{ include "app.partOf" .root }}
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .root.Chart.Name .root.Chart.Version }}
{{- with .component.image.tag }}
app.kubernetes.io/version: {{ toString . | trunc 63 | trimSuffix "-" | quote }}
{{- end }}
{{- end -}}

{{/* A component's value for `key`, falling back to the chart-wide default. */}}
{{- define "app.setting" -}}
{{- $c := .component -}}
{{- if hasKey $c .key -}}
{{- toYaml (get $c .key) -}}
{{- else -}}
{{- toYaml (get .root.Values .key) -}}
{{- end -}}
{{- end -}}

{{/* Image reference, preferring the digest when set. */}}
{{- define "app.image" -}}
{{- $image := .image -}}
{{- if not $image.repository -}}
{{- fail (printf "components.%s.image.repository is required" .name) -}}
{{- end -}}
{{- if $image.digest -}}
{{- printf "%s@%s" $image.repository $image.digest -}}
{{- else if $image.tag -}}
{{- printf "%s:%s" $image.repository $image.tag -}}
{{- else -}}
{{- fail (printf "components.%s.image needs a tag or digest" .name) -}}
{{- end -}}
{{- end -}}
