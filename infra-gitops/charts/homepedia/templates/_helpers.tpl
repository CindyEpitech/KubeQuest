{{/*
Chart name
*/}}
{{- define "homepedia.name" -}}
{{- .Chart.Name }}
{{- end }}

{{/*
Fullname (release-name + chart-name, capped at 63 chars). This is the frontend
(the user-facing web app), mirroring how myapp's fullname IS the app.
*/}}
{{- define "homepedia.fullname" -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "homepedia.labels" -}}
app.kubernetes.io/name: {{ include "homepedia.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}

{{/*
Frontend selector labels
*/}}
{{- define "homepedia.selectorLabels" -}}
app.kubernetes.io/name: {{ include "homepedia.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: frontend
{{- end }}

{{/*
Postgres service hostname (in-cluster PostGIS)
*/}}
{{- define "homepedia.postgresHost" -}}
{{- printf "%s-postgres" .Release.Name }}
{{- end }}

{{/*
MongoDB service hostname (in-cluster Mongo)
*/}}
{{- define "homepedia.mongoHost" -}}
{{- printf "%s-mongodb" .Release.Name }}
{{- end }}

{{/*
MongoDB connection URI consumed by the frontend (lib/mongo.ts). Built from the
db credentials + the in-cluster mongo service. Lives in the Secret because it
embeds the password.
*/}}
{{- define "homepedia.mongoUri" -}}
{{- printf "mongodb://%s:%s@%s:27017/?authSource=admin" .Values.mongodb.auth.rootUser .Values.mongodb.auth.rootPassword (include "homepedia.mongoHost" .) }}
{{- end }}
