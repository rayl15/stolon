{{/*
Expand the name of the chart.
*/}}
{{- define "etcd-ha.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "etcd-ha.fullname" -}}
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
{{- define "etcd-ha.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "etcd-ha.labels" -}}
helm.sh/chart: {{ include "etcd-ha.chart" . }}
{{ include "etcd-ha.selectorLabels" . }}
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
{{- define "etcd-ha.selectorLabels" -}}
app.kubernetes.io/name: {{ include "etcd-ha.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: etcd
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "etcd-ha.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "etcd-ha.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Get the namespace
*/}}
{{- define "etcd-ha.namespace" -}}
{{- .Values.namespace | default .Release.Namespace }}
{{- end }}

{{/*
Create the image name
*/}}
{{- define "etcd-ha.image" -}}
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
Get listen address based on IP family
*/}}
{{- define "etcd-ha.listenAddress" -}}
{{- if or (eq .Values.network.ipFamily "IPv6") (eq .Values.network.ipFamily "DualStack") -}}
[::]
{{- else -}}
0.0.0.0
{{- end -}}
{{- end }}

{{/*
Get IP family policy
*/}}
{{- define "etcd-ha.ipFamilyPolicy" -}}
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
{{- define "etcd-ha.ipFamilies" -}}
{{- if eq .Values.network.ipFamily "DualStack" -}}
{{ toYaml .Values.network.ipFamilies }}
{{- else if eq .Values.network.ipFamily "IPv6" -}}
- IPv6
{{- else -}}
- IPv4
{{- end -}}
{{- end }}

{{/*
Generate initial cluster string
*/}}
{{- define "etcd-ha.initialCluster" -}}
{{- $fullname := include "etcd-ha.fullname" . }}
{{- $namespace := include "etcd-ha.namespace" . }}
{{- $peerPort := .Values.network.peerPort | int }}
{{- $members := list }}
{{- range $i := until (.Values.replicaCount | int) }}
{{- $member := printf "%s-%d=http://%s-%d.%s.%s.svc.cluster.local:%d" $fullname $i $fullname $i $fullname $namespace $peerPort }}
{{- $members = append $members $member }}
{{- end }}
{{- join "," $members }}
{{- end }}

{{/*
Generate endpoints string for health checks
*/}}
{{- define "etcd-ha.endpoints" -}}
{{- $fullname := include "etcd-ha.fullname" . }}
{{- $namespace := include "etcd-ha.namespace" . }}
{{- $clientPort := .Values.network.clientPort | int }}
{{- $endpoints := list }}
{{- range $i := until (.Values.replicaCount | int) }}
{{- $endpoint := printf "http://%s-%d.%s.%s.svc.cluster.local:%d" $fullname $i $fullname $namespace $clientPort }}
{{- $endpoints = append $endpoints $endpoint }}
{{- end }}
{{- join "," $endpoints }}
{{- end }}

{{/*
Pod anti-affinity
*/}}
{{- define "etcd-ha.podAntiAffinity" -}}
{{- if eq .Values.podAntiAffinityPreset "hard" }}
requiredDuringSchedulingIgnoredDuringExecution:
  - labelSelector:
      matchLabels:
        {{- include "etcd-ha.selectorLabels" . | nindent 8 }}
    topologyKey: kubernetes.io/hostname
{{- else if eq .Values.podAntiAffinityPreset "soft" }}
preferredDuringSchedulingIgnoredDuringExecution:
  - weight: 100
    podAffinityTerm:
      labelSelector:
        matchLabels:
          {{- include "etcd-ha.selectorLabels" . | nindent 10 }}
      topologyKey: kubernetes.io/hostname
{{- end }}
{{- end }}

{{/*
Node anti-affinity for zone spreading
*/}}
{{- define "etcd-ha.nodeAntiAffinity" -}}
{{- if .Values.nodeAntiAffinityPreset.enabled }}
preferredDuringSchedulingIgnoredDuringExecution:
  - weight: 100
    podAffinityTerm:
      labelSelector:
        matchLabels:
          {{- include "etcd-ha.selectorLabels" . | nindent 10 }}
      topologyKey: {{ .Values.nodeAntiAffinityPreset.topologyKey }}
{{- end }}
{{- end }}
