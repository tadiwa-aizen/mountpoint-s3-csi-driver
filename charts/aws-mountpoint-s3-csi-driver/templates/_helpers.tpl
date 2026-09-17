{{/* vim: set filetype=mustache: */}}
{{/*
Expand the name of the chart.
*/}}
{{- define "aws-mountpoint-s3-csi-driver.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "csiDriverImageName" -}}
{{ include "renderImageName" (dict "image" .Values.image "eksImage" "/eks/aws-s3-csi-driver" "isEKSAddon" .Values.isEKSAddon ) }}
{{- end -}}

{{- define "nodeDriverRegistrarImageName" -}}
{{ include "renderImageName" (dict "image" .Values.sidecars.nodeDriverRegistrar.image "eksImage" "/eks/csi-node-driver-registrar" "isEKSAddon" .Values.isEKSAddon ) }}
{{- end -}}

{{- define "livenessProbeImageName" -}}
{{ include "renderImageName" (dict "image" .Values.sidecars.livenessProbe.image "eksImage" "/eks/livenessprobe" "isEKSAddon" .Values.isEKSAddon ) }}
{{- end -}}

{{- define "renderImageName" -}}
{{ printf "%s%s:%s" (default "" .image.containerRegistry) (ternary .image.repository .eksImage (empty .isEKSAddon)) .image.tag }}
{{- end -}}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "aws-mountpoint-s3-csi-driver.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "aws-mountpoint-s3-csi-driver.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Common labels
*/}}
{{- define "aws-mountpoint-s3-csi-driver.labels" -}}
{{ include "aws-mountpoint-s3-csi-driver.selectorLabels" . }}
{{- if ne .Release.Name "kustomize" }}
{{- if empty .Values.isEKSAddon }}
helm.sh/chart: {{ include "aws-mountpoint-s3-csi-driver.chart" . }}
{{- end }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/component: csi-driver
app.kubernetes.io/managed-by: {{ ternary .Release.Service "EKS" (empty .Values.isEKSAddon) }}
{{- end }}
{{- if .Values.customLabels }}
{{ toYaml .Values.customLabels }}
{{- end }}
{{- end -}}

{{/*
Common selector labels
*/}}
{{- define "aws-mountpoint-s3-csi-driver.selectorLabels" -}}
app.kubernetes.io/name: {{ include "aws-mountpoint-s3-csi-driver.name" . }}
{{- if ne .Release.Name "kustomize" }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
{{- end -}}

{{/*
Convert the `--extra-tags` command line arg from a map.
*/}}
{{- define "aws-mountpoint-s3-csi-driver.extra-volume-tags" -}}
{{- $result := dict "pairs" (list) -}}
{{- range $key, $value := .Values.controller.extraVolumeTags -}}
{{- $noop := printf "%s=%v" $key $value | append $result.pairs | set $result "pairs" -}}
{{- end -}}
{{- if gt (len $result.pairs) 0 -}}
{{- printf "- \"--extra-tags=%s\"" (join "," $result.pairs) -}}
{{- end -}}
{{- end -}}

{{/*
Determine if running on OpenShift (incl. ROSA)
*/}}
{{- define "aws-mountpoint-s3-csi-driver.isOpenShift" -}}
{{- $isOpenShift := .Values.isOpenShift -}}
{{- if eq $isOpenShift nil -}}
{{- $isOpenShift = .Capabilities.APIVersions.Has "security.openshift.io/v1/SecurityContextConstraints" -}}
{{- end -}}
{{- $isOpenShift -}}
{{- end -}}

{{/*
Heterogeneous daemonset mounters — helpers.
*/}}

{{/* DNS-safe DaemonSet name suffix from a nodeSelectorValue. */}}
{{- define "s3.mounterNameSuffix" -}}
{{- $v := .value | default "" -}}
{{- $v | replace "." "-" | replace ":" "-" | lower | trunc 40 | trimSuffix "-" -}}
{{- end -}}

{{/* Validate the daemonsetMounters list shape (daemonset mode only). */}}
{{- define "s3.validateMounters" -}}
{{- if eq .Values.experimental.mounterMode "daemonset" -}}
{{- if lt (len .Values.daemonsetMounters) 1 -}}
{{- fail "daemonsetMounters must have at least one entry in daemonset mode" -}}
{{- end -}}
{{- range $m := .Values.daemonsetMounters -}}
{{- if lt (int $m.maxVolumesPerNode) 0 -}}
{{- fail "daemonsetMounters[].maxVolumesPerNode must be >= 0" -}}
{{- end -}}
{{- if and (gt (len $.Values.daemonsetMounters) 1) (empty $m.nodeSelectorValue) -}}
{{- fail "daemonsetMounters[].nodeSelectorValue is required when more than one entry is defined" -}}
{{- end -}}
{{- end -}}
{{- /* ponytail: the OR-affinity generator only supports a single-term floor / per-class affinity; a full DNF cross-product isn't implemented. Reject multi-term (else OR'd terms silently become AND). Upgrade path: distribute floorTerms x classes x classAffinityTerms in s3.nodeOrAffinity. */ -}}
{{- $classes := 0 -}}
{{- range $m := .Values.daemonsetMounters -}}{{- if not (empty $m.nodeSelectorValue) -}}{{- $classes = add1 $classes -}}{{- end -}}{{- end -}}
{{- if gt $classes 0 -}}
{{- with .Values.node.affinity -}}{{- with .nodeAffinity -}}{{- with .requiredDuringSchedulingIgnoredDuringExecution -}}
{{- if gt (len .nodeSelectorTerms) 1 -}}{{- fail "node.affinity with multiple nodeSelectorTerms is not supported alongside heterogeneous daemonsetMounters (OR'd terms would be silently AND'd); use a single nodeSelectorTerm" -}}{{- end -}}
{{- end -}}{{- end -}}{{- end -}}
{{- range $m := .Values.daemonsetMounters -}}
{{- with $m.affinity -}}{{- with .nodeAffinity -}}{{- with .requiredDuringSchedulingIgnoredDuringExecution -}}
{{- if gt (len .nodeSelectorTerms) 1 -}}{{- fail "daemonsetMounters[].affinity with multiple nodeSelectorTerms is not supported (OR'd terms would be silently AND'd); use a single nodeSelectorTerm" -}}{{- end -}}
{{- end -}}{{- end -}}{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/* JSON list of the node.affinity floor matchExpressions (empty list if none). */}}
{{- define "s3.floorExprsJSON" -}}
{{- $exprs := list -}}
{{- with .Values.node.affinity -}}
{{- with .nodeAffinity -}}
{{- with .requiredDuringSchedulingIgnoredDuringExecution -}}
{{- range $term := .nodeSelectorTerms -}}
{{- range $e := $term.matchExpressions -}}
{{- $exprs = append $exprs $e -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- $exprs | toJson -}}
{{- end -}}

{{/* CSI node pod nodeAffinity: one OR'd term per mounter class (floor AND class-label AND per-class affinity). Emits nothing when no class has a nodeSelectorValue. */}}
{{- define "s3.nodeOrAffinity" -}}
{{- $key := .Values.daemonsetMounterLabelKey -}}
{{- $floor := include "s3.floorExprsJSON" . | fromJsonArray -}}
{{- $classes := list -}}
{{- range $m := .Values.daemonsetMounters -}}
{{- if not (empty $m.nodeSelectorValue) -}}
{{- $classes = append $classes $m -}}
{{- end -}}
{{- end -}}
{{- if gt (len $classes) 0 -}}
nodeAffinity:
  requiredDuringSchedulingIgnoredDuringExecution:
    nodeSelectorTerms:
{{- range $m := $classes }}
      - matchExpressions:
{{- range $e := $floor }}
          - {{ toJson $e }}
{{- end }}
          - key: {{ $key }}
            operator: In
            values:
              - {{ $m.nodeSelectorValue | quote }}
{{- with $m.affinity }}{{- with .nodeAffinity }}{{- with .requiredDuringSchedulingIgnoredDuringExecution }}
{{- range $t := .nodeSelectorTerms }}
{{- range $e := $t.matchExpressions }}
          - {{ toJson $e }}
{{- end }}
{{- end }}
{{- end }}{{- end }}{{- end }}
{{- end }}
{{- end -}}
{{- end -}}

{{/* Single mounter class merged affinity (floor AND per-class affinity). Class-label is on nodeSelector, not repeated here. Emits nothing when both empty. */}}
{{- define "s3.mounterAffinity" -}}
{{- $root := .root -}}
{{- $mounter := .mounter -}}
{{- $exprs := include "s3.floorExprsJSON" $root | fromJsonArray -}}
{{- with $mounter.affinity }}{{- with .nodeAffinity }}{{- with .requiredDuringSchedulingIgnoredDuringExecution }}
{{- range $t := .nodeSelectorTerms }}
{{- range $e := $t.matchExpressions }}
{{- $exprs = append $exprs $e }}
{{- end }}
{{- end }}
{{- end }}{{- end }}{{- end }}
{{- if gt (len $exprs) 0 -}}
nodeAffinity:
  requiredDuringSchedulingIgnoredDuringExecution:
    nodeSelectorTerms:
      - matchExpressions:
{{- range $e := $exprs }}
          - {{ toJson $e }}
{{- end }}
{{- end -}}
{{- end -}}

{{/* JSON map { nodeSelectorValue: maxVolumesPerNode } for entries with a nodeSelectorValue. */}}
{{- define "s3.maxVolumesByLabelJSON" -}}
{{- $map := dict -}}
{{- range $m := .Values.daemonsetMounters -}}
{{- if not (empty $m.nodeSelectorValue) -}}
{{- $_ := set $map $m.nodeSelectorValue (int $m.maxVolumesPerNode) -}}
{{- end -}}
{{- end -}}
{{- $map | toJson -}}
{{- end -}}
