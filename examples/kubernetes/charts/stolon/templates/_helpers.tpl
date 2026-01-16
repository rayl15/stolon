{{/*
Expand the name of the chart.
*/}}
{{- define "stolon.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "stolon.fullname" -}}
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
Create chart name and version as used by the chart label.
*/}}
{{- define "stolon.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "stolon.labels" -}}
helm.sh/chart: {{ include "stolon.chart" . }}
{{ include "stolon.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "stolon.selectorLabels" -}}
app.kubernetes.io/name: {{ include "stolon.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
stolon-cluster: {{ .Values.clusterName }}
{{- end }}

{{/*
Keeper selector labels
*/}}
{{- define "stolon.keeper.selectorLabels" -}}
{{ include "stolon.selectorLabels" . }}
app.kubernetes.io/component: keeper
{{- end }}

{{/*
Sentinel selector labels
*/}}
{{- define "stolon.sentinel.selectorLabels" -}}
{{ include "stolon.selectorLabels" . }}
app.kubernetes.io/component: sentinel
{{- end }}

{{/*
Proxy selector labels
*/}}
{{- define "stolon.proxy.selectorLabels" -}}
{{ include "stolon.selectorLabels" . }}
app.kubernetes.io/component: proxy
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "stolon.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "stolon.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Get the namespace
*/}}
{{- define "stolon.namespace" -}}
{{- .Values.namespace | default .Release.Namespace }}
{{- end }}

{{/*
Create the image name
*/}}
{{- define "stolon.image" -}}
{{- $registry := .Values.image.registry }}
{{- $repository := .Values.image.repository }}
{{- $tag := .Values.image.tag | default .Chart.AppVersion }}
{{- if $registry }}
{{- printf "%s/%s:%s" $registry $repository $tag }}
{{- else }}
{{- printf "%s:%s" $repository $tag }}
{{- end }}
{{- end }}

{{/*
Create the postgres-exporter image name
*/}}
{{- define "stolon.pgExporter.image" -}}
{{- $registry := .Values.metrics.pgExporter.image.registry }}
{{- $repository := .Values.metrics.pgExporter.image.repository }}
{{- $tag := .Values.metrics.pgExporter.image.tag }}
{{- if $registry }}
{{- printf "%s/%s:%s" $registry $repository $tag }}
{{- else }}
{{- printf "%s:%s" $repository $tag }}
{{- end }}
{{- end }}

{{/*
Get the secrets name for PostgreSQL credentials
*/}}
{{- define "stolon.secretName" -}}
{{- if .Values.postgresql.superuserPasswordSecret }}
{{- .Values.postgresql.superuserPasswordSecret }}
{{- else }}
{{- printf "%s-secrets" (include "stolon.fullname" .) }}
{{- end }}
{{- end }}

{{/*
Get the pgBackRest secret name
*/}}
{{- define "stolon.pgbackrest.secretName" -}}
{{- if .Values.pgbackrest.secretName }}
{{- .Values.pgbackrest.secretName }}
{{- else }}
{{- printf "%s-pgbackrest" (include "stolon.fullname" .) }}
{{- end }}
{{- end }}

{{/*
Get IP family policy
*/}}
{{- define "stolon.ipFamilyPolicy" -}}
{{- if eq .Values.network.ipFamily "DualStack" -}}
PreferDualStack
{{- else if eq .Values.network.ipFamily "IPv6" -}}
SingleStack
{{- else -}}
SingleStack
{{- end -}}
{{- end }}

{{/*
Get IP families list
*/}}
{{- define "stolon.ipFamilies" -}}
{{- if eq .Values.network.ipFamily "DualStack" -}}
{{ toYaml .Values.network.ipFamilies }}
{{- else if eq .Values.network.ipFamily "IPv6" -}}
- IPv6
{{- else -}}
- IPv4
{{- end -}}
{{- end }}

{{/*
Keeper pod anti-affinity
*/}}
{{- define "stolon.keeper.podAntiAffinity" -}}
{{- if eq .Values.podAntiAffinityPreset "hard" }}
requiredDuringSchedulingIgnoredDuringExecution:
  - labelSelector:
      matchLabels:
        {{- include "stolon.keeper.selectorLabels" . | nindent 8 }}
    topologyKey: kubernetes.io/hostname
{{- else if eq .Values.podAntiAffinityPreset "soft" }}
preferredDuringSchedulingIgnoredDuringExecution:
  - weight: 100
    podAffinityTerm:
      labelSelector:
        matchLabels:
          {{- include "stolon.keeper.selectorLabels" . | nindent 10 }}
      topologyKey: kubernetes.io/hostname
{{- end }}
{{- end }}

{{/*
Sentinel pod anti-affinity
*/}}
{{- define "stolon.sentinel.podAntiAffinity" -}}
{{- if eq .Values.podAntiAffinityPreset "hard" }}
requiredDuringSchedulingIgnoredDuringExecution:
  - labelSelector:
      matchLabels:
        {{- include "stolon.sentinel.selectorLabels" . | nindent 8 }}
    topologyKey: kubernetes.io/hostname
{{- else if eq .Values.podAntiAffinityPreset "soft" }}
preferredDuringSchedulingIgnoredDuringExecution:
  - weight: 100
    podAffinityTerm:
      labelSelector:
        matchLabels:
          {{- include "stolon.sentinel.selectorLabels" . | nindent 10 }}
      topologyKey: kubernetes.io/hostname
{{- end }}
{{- end }}

{{/*
Proxy pod anti-affinity
*/}}
{{- define "stolon.proxy.podAntiAffinity" -}}
{{- if eq .Values.podAntiAffinityPreset "hard" }}
requiredDuringSchedulingIgnoredDuringExecution:
  - labelSelector:
      matchLabels:
        {{- include "stolon.proxy.selectorLabels" . | nindent 8 }}
    topologyKey: kubernetes.io/hostname
{{- else if eq .Values.podAntiAffinityPreset "soft" }}
preferredDuringSchedulingIgnoredDuringExecution:
  - weight: 100
    podAffinityTerm:
      labelSelector:
        matchLabels:
          {{- include "stolon.proxy.selectorLabels" . | nindent 10 }}
      topologyKey: kubernetes.io/hostname
{{- end }}
{{- end }}

{{/*
Node anti-affinity for zone spreading
*/}}
{{- define "stolon.nodeAntiAffinity" -}}
{{- if .Values.nodeAntiAffinityPreset.enabled }}
preferredDuringSchedulingIgnoredDuringExecution:
  - weight: 100
    podAffinityTerm:
      labelSelector:
        matchLabels:
          {{- include "stolon.selectorLabels" . | nindent 10 }}
      topologyKey: {{ .Values.nodeAntiAffinityPreset.topologyKey }}
{{- end }}
{{- end }}

{{/*
Store backend environment variables
*/}}
{{- define "stolon.storeEnvVars" -}}
- name: STORE_BACKEND
  value: {{ .Values.store.backend | quote }}
{{- if eq .Values.store.backend "etcdv3" }}
- name: STORE_ENDPOINTS
  value: {{ .Values.store.endpoints | quote }}
{{- else if eq .Values.store.backend "kubernetes" }}
- name: KUBE_RESOURCE_KIND
  value: {{ .Values.store.kubeResourceKind | quote }}
{{- end }}
{{- end }}

{{/*
Keeper name
*/}}
{{- define "stolon.keeper.fullname" -}}
{{- printf "%s-keeper" (include "stolon.fullname" .) }}
{{- end }}

{{/*
Sentinel name
*/}}
{{- define "stolon.sentinel.fullname" -}}
{{- printf "%s-sentinel" (include "stolon.fullname" .) }}
{{- end }}

{{/*
Proxy name
*/}}
{{- define "stolon.proxy.fullname" -}}
{{- printf "%s-proxy" (include "stolon.fullname" .) }}
{{- end }}

{{/*
Proxy service name
*/}}
{{- define "stolon.proxy.serviceName" -}}
{{- printf "%s-proxy" (include "stolon.fullname" .) }}
{{- end }}

{{/*
Get bind address based on IP family
IPv4: 0.0.0.0
IPv6/DualStack: :: (binds to both IPv4 and IPv6 on dual-stack systems)
*/}}
{{- define "stolon.bindAddress" -}}
{{- if eq .Values.network.ipFamily "IPv4" -}}
0.0.0.0
{{- else -}}
::
{{- end -}}
{{- end }}

{{/*
Get bind address with port for metrics
*/}}
{{- define "stolon.metricsListenAddress" -}}
{{- if eq .Values.network.ipFamily "IPv4" -}}
0.0.0.0:{{ .Values.metrics.port }}
{{- else -}}
[::]:{{ .Values.metrics.port }}
{{- end -}}
{{- end }}
