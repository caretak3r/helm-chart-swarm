{{/*
Expand the name of the chart.
*/}}
{{- define "sample-product.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "sample-product.fullname" -}}
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

{{/*
Common labels shared across all resources.
*/}}
{{- define "sample-product.labels" -}}
helm.sh/chart: {{ include "sample-product.name" . }}-{{ .Chart.Version | replace "+" "_" }}
app.kubernetes.io/name: {{ include "sample-product.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels for each component.
- skywatcher: app: <release-name> (backward compatible)
- scope: app: <release-name>-scope
- darkroom: app: <release-name>-darkroom
*/}}
{{- define "sample-product.selectorLabels" -}}
app: {{ .Release.Name }}
{{- end }}

{{- define "sample-product.scopeSelectorLabels" -}}
app: {{ .Release.Name }}-scope
{{- end }}

{{- define "sample-product.darkroomSelectorLabels" -}}
app: {{ .Release.Name }}-darkroom
{{- end }}

{{/*
Component-specific labels (combine common + selector + optional compliance + optional component).
*/}}
{{- define "sample-product.skywatcherPodLabels" -}}
{{ include "sample-product.labels" . }}
app.kubernetes.io/component: skywatcher
{{ include "sample-product.selectorLabels" . }}
{{- with .Values.policy.complianceLabels }}
{{- range $k, $v := . }}
{{ $k }}: {{ $v | quote }}
{{- end }}
{{- end }}
{{- end }}

{{- define "sample-product.scopePodLabels" -}}
{{ include "sample-product.labels" . }}
app.kubernetes.io/component: scope
{{ include "sample-product.scopeSelectorLabels" . }}
{{- with .Values.policy.complianceLabels }}
{{- range $k, $v := . }}
{{ $k }}: {{ $v | quote }}
{{- end }}
{{- end }}
{{- end }}

{{- define "sample-product.darkroomPodLabels" -}}
{{ include "sample-product.labels" . }}
app.kubernetes.io/component: darkroom
{{ include "sample-product.darkroomSelectorLabels" . }}
{{- with .Values.policy.complianceLabels }}
{{- range $k, $v := . }}
{{ $k }}: {{ $v | quote }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Mesh injection annotations for the pod template.
*/}}
{{- define "sample-product.meshAnnotations" -}}
{{- if .Values.mesh.inject }}
sidecar.istio.io/inject: "true"
{{- end }}
{{- end }}
