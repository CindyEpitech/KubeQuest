# KubeQuest — Phase 4: Application Helm Chart
> Helm | docker-compose migration | Bitnami PostgreSQL

---

## Overview

Convert the existing docker-compose application into a production-ready Helm chart.
Apply all Kubernetes best practices: resource limits, secrets, replicas, anti-affinity, PVC, and backups.

---

## Chart Structure

```
charts/
└── myapp/
    ├── Chart.yaml
    ├── values.yaml
    └── templates/
        ├── deployment.yaml
        ├── service.yaml
        ├── ingress.yaml
        ├── hpa.yaml
        ├── configmap.yaml
        ├── secret.yaml
        ├── pvc.yaml
        ├── cronjob-backup.yaml
        └── _helpers.tpl
```

---

## Chart.yaml

```yaml
apiVersion: v2
name: myapp
description: KubeQuest application chart
type: application
version: 0.1.0
appVersion: "1.0.0"

dependencies:
  - name: postgresql
    version: "13.x.x"
    repository: https://charts.bitnami.com/bitnami
```

---

## values.yaml

```yaml
# Application
replicaCount: 2

image:
  repository: your-registry/myapp
  tag: "1.0.0"
  pullPolicy: IfNotPresent

# Service
service:
  type: ClusterIP
  port: 80
  targetPort: 3000

# Ingress
ingress:
  enabled: true
  className: nginx
  host: app.kubequest.local
  path: /

# Resource limits (mandatory best practice)
resources:
  requests:
    cpu: "100m"
    memory: "128Mi"
  limits:
    cpu: "500m"
    memory: "512Mi"

# HPA — auto scaling
autoscaling:
  enabled: true
  minReplicas: 2
  maxReplicas: 6
  targetCPUUtilizationPercentage: 70

# App environment config
config:
  appEnv: production
  logLevel: info

# Secrets (values injected at deploy time, not stored here)
secret:
  dbPassword: ""
  appSecret: ""

# PostgreSQL (Bitnami subchart)
postgresql:
  enabled: true
  auth:
    username: myapp
    database: myapp
    existingSecret: myapp-db-secret
  primary:
    persistence:
      enabled: true
      size: 5Gi
    resources:
      requests:
        cpu: "100m"
        memory: "256Mi"
      limits:
        cpu: "500m"
        memory: "512Mi"
```

---

## templates/_helpers.tpl

```yaml
{{/*
Expand the name of the chart.
*/}}
{{- define "myapp.name" -}}
{{- .Chart.Name }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "myapp.labels" -}}
app.kubernetes.io/name: {{ include "myapp.name" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "myapp.selectorLabels" -}}
app.kubernetes.io/name: {{ include "myapp.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
```

---

## templates/secret.yaml

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: myapp-secret
  labels:
    {{- include "myapp.labels" . | nindent 4 }}
type: Opaque
data:
  db-password: {{ .Values.secret.dbPassword | b64enc }}
  app-secret: {{ .Values.secret.appSecret | b64enc }}
---
apiVersion: v1
kind: Secret
metadata:
  name: myapp-db-secret
  labels:
    {{- include "myapp.labels" . | nindent 4 }}
type: Opaque
data:
  password: {{ .Values.secret.dbPassword | b64enc }}
```

---

## templates/configmap.yaml

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: myapp-config
  labels:
    {{- include "myapp.labels" . | nindent 4 }}
data:
  APP_ENV: {{ .Values.config.appEnv }}
  LOG_LEVEL: {{ .Values.config.logLevel }}
  DB_HOST: {{ .Release.Name }}-postgresql
  DB_PORT: "5432"
  DB_NAME: myapp
  DB_USER: myapp
```

---

## templates/deployment.yaml

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "myapp.name" . }}
  labels:
    {{- include "myapp.labels" . | nindent 4 }}
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels:
      {{- include "myapp.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      labels:
        {{- include "myapp.selectorLabels" . | nindent 8 }}
    spec:
      # Pod anti-affinity — spread replicas across nodes
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                labelSelector:
                  matchExpressions:
                    - key: app.kubernetes.io/name
                      operator: In
                      values:
                        - {{ include "myapp.name" . }}
                topologyKey: kubernetes.io/hostname

      containers:
        - name: myapp
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          ports:
            - containerPort: {{ .Values.service.targetPort }}

          # Environment from ConfigMap
          envFrom:
            - configMapRef:
                name: myapp-config

          # Sensitive env from Secret
          env:
            - name: DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: myapp-secret
                  key: db-password
            - name: APP_SECRET
              valueFrom:
                secretKeyRef:
                  name: myapp-secret
                  key: app-secret

          # Resource limits (required by OPA policy)
          resources:
            {{- toYaml .Values.resources | nindent 12 }}

          # Readiness probe — zero-downtime deploys
          readinessProbe:
            httpGet:
              path: /health
              port: {{ .Values.service.targetPort }}
            initialDelaySeconds: 10
            periodSeconds: 5

          # Liveness probe — restart on failure
          livenessProbe:
            httpGet:
              path: /health
              port: {{ .Values.service.targetPort }}
            initialDelaySeconds: 30
            periodSeconds: 10
```

---

## templates/service.yaml

```yaml
apiVersion: v1
kind: Service
metadata:
  name: {{ include "myapp.name" . }}
  labels:
    {{- include "myapp.labels" . | nindent 4 }}
spec:
  type: {{ .Values.service.type }}
  ports:
    - port: {{ .Values.service.port }}
      targetPort: {{ .Values.service.targetPort }}
      protocol: TCP
  selector:
    {{- include "myapp.selectorLabels" . | nindent 4 }}
```

---

## templates/ingress.yaml

```yaml
{{- if .Values.ingress.enabled }}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ include "myapp.name" . }}
  labels:
    {{- include "myapp.labels" . | nindent 4 }}
spec:
  ingressClassName: {{ .Values.ingress.className }}
  rules:
    - host: {{ .Values.ingress.host }}
      http:
        paths:
          - path: {{ .Values.ingress.path }}
            pathType: Prefix
            backend:
              service:
                name: {{ include "myapp.name" . }}
                port:
                  number: {{ .Values.service.port }}
{{- end }}
```

---

## templates/hpa.yaml

```yaml
{{- if .Values.autoscaling.enabled }}
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: {{ include "myapp.name" . }}
  labels:
    {{- include "myapp.labels" . | nindent 4 }}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: {{ include "myapp.name" . }}
  minReplicas: {{ .Values.autoscaling.minReplicas }}
  maxReplicas: {{ .Values.autoscaling.maxReplicas }}
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: {{ .Values.autoscaling.targetCPUUtilizationPercentage }}
{{- end }}
```

---

## templates/cronjob-backup.yaml

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: {{ include "myapp.name" . }}-db-backup
  labels:
    {{- include "myapp.labels" . | nindent 4 }}
spec:
  schedule: "0 2 * * *"   # Every day at 2am
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: OnFailure
          containers:
            - name: db-backup
              image: bitnami/postgresql:latest
              command:
                - /bin/sh
                - -c
                - |
                  pg_dump -h $DB_HOST -U $DB_USER $DB_NAME > /backup/backup-$(date +%Y%m%d).sql
              env:
                - name: DB_HOST
                  valueFrom:
                    configMapKeyRef:
                      name: myapp-config
                      key: DB_HOST
                - name: DB_USER
                  valueFrom:
                    configMapKeyRef:
                      name: myapp-config
                      key: DB_USER
                - name: DB_NAME
                  valueFrom:
                    configMapKeyRef:
                      name: myapp-config
                      key: DB_NAME
                - name: PGPASSWORD
                  valueFrom:
                    secretKeyRef:
                      name: myapp-secret
                      key: db-password
              resources:
                requests:
                  cpu: "50m"
                  memory: "64Mi"
                limits:
                  cpu: "200m"
                  memory: "128Mi"
              volumeMounts:
                - name: backup-storage
                  mountPath: /backup
          volumes:
            - name: backup-storage
              persistentVolumeClaim:
                claimName: myapp-backup-pvc
```

---

## Install Dependencies (Bitnami PostgreSQL)

```bash
# Add Bitnami repo
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update

# Download dependencies
cd charts/myapp
helm dependency update
```

---

## Deploy the Chart

```bash
# Create namespace
kubectl create namespace myapp

# Create secrets first (never put real values in values.yaml)
kubectl create secret generic myapp-secret \
  --from-literal=db-password=supersecret \
  --from-literal=app-secret=anothersecret \
  -n myapp

# Install the chart
helm install myapp ./charts/myapp \
  --namespace myapp \
  --set secret.dbPassword=supersecret \
  --set secret.appSecret=anothersecret
```

---

## Verify

```bash
kubectl get all -n myapp
kubectl get ingress -n myapp
kubectl get pvc -n myapp

# Check app logs
kubectl logs -n myapp deployment/myapp

# Check HPA
kubectl get hpa -n myapp
```

---

## Upgrade

```bash
helm upgrade myapp ./charts/myapp \
  --namespace myapp \
  --set image.tag=1.0.1
```

---

## Lint and Test

```bash
# Lint the chart
helm lint ./charts/myapp

# Dry run to preview manifests
helm install myapp ./charts/myapp --dry-run --debug -n myapp

# Template render only
helm template myapp ./charts/myapp
```

---

## Troubleshooting

| Issue | Fix |
|-------|-----|
| Pod not starting | `kubectl describe pod -n myapp <pod>` |
| DB connection refused | Check secret and configmap values |
| HPA not scaling | Ensure metrics-server is installed: `kubectl top pods` |
| PVC stuck Pending | Check storage class: `kubectl get storageclass` |

---

## Next Step

Once the chart deploys cleanly, proceed to:
**[Phase 5 — Application GitOps](./PHASE_5_APP_GITOPS.md)**