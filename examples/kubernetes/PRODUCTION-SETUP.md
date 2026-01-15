# Stolon Production Setup Guide

Complete step-by-step guide for deploying Stolon with pgBackRest backup on Kubernetes for 500GB+ PostgreSQL databases.

## Prerequisites

- Kubernetes cluster (1.19+)
- kubectl configured
- S3-compatible storage (AWS S3, GCS, Azure Blob, MinIO)
- Storage class with fast SSD for database volumes

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        Kubernetes Cluster                        │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐          │
│  │   Sentinel   │  │   Sentinel   │  │   Sentinel   │          │
│  │   (leader    │  │              │  │              │          │
│  │   election)  │  │              │  │              │          │
│  └──────────────┘  └──────────────┘  └──────────────┘          │
│         │                 │                 │                   │
│         └─────────────────┼─────────────────┘                   │
│                           │                                      │
│                           ▼                                      │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐          │
│  │   Keeper-0   │  │   Keeper-1   │  │   Keeper-2   │          │
│  │   (Primary)  │◄─┤  (Standby)   │  │  (Standby)   │          │
│  │              │  │              │  │              │          │
│  │  pgBackRest  │  │  pgBackRest  │  │  pgBackRest  │          │
│  └──────┬───────┘  └──────────────┘  └──────────────┘          │
│         │                                                        │
│         │ WAL Archive + Backups                                  │
│         ▼                                                        │
│  ┌──────────────────────────────────────────────────┐           │
│  │              S3 / GCS / Azure Blob               │           │
│  │         (Backup Repository + WAL Archive)         │           │
│  └──────────────────────────────────────────────────┘           │
│                                                                  │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐          │
│  │    Proxy     │  │    Proxy     │  │    Proxy     │          │
│  └──────────────┘  └──────────────┘  └──────────────┘          │
│         │                 │                 │                   │
│         └─────────────────┼─────────────────┘                   │
│                           │                                      │
│                           ▼                                      │
│                   ┌──────────────┐                              │
│                   │   Service    │                              │
│                   │  (LoadBal)   │                              │
│                   └──────────────┘                              │
│                           │                                      │
└───────────────────────────┼─────────────────────────────────────┘
                            │
                            ▼
                      Applications
```

## Step 1: Create Namespace and Secrets

```bash
# Create namespace
kubectl create namespace stolon

# Create PostgreSQL superuser password secret
kubectl -n stolon create secret generic stolon \
  --from-literal=password='YOUR_SECURE_PASSWORD_HERE'

# (Optional) Create Docker registry secret if using private registry
kubectl -n stolon create secret docker-registry dockerhub-secret \
  --docker-server=docker.io \
  --docker-username=YOUR_USERNAME \
  --docker-password=YOUR_TOKEN
```

## Step 2: Create pgBackRest Configuration

```yaml
# pgbackrest-secrets.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: pgbackrest-config
  namespace: stolon
data:
  pgbackrest.conf: |
    [global]
    # S3 Configuration (adjust for your provider)
    repo1-type=s3
    repo1-s3-endpoint=s3.amazonaws.com
    repo1-s3-bucket=YOUR-BACKUP-BUCKET
    repo1-s3-region=us-east-1
    repo1-path=/stolon-backups

    # Retention: 4 full backups (~1 month), 7 incrementals
    repo1-retention-full=4
    repo1-retention-diff=7

    # Compression (reduces 500GB to ~150GB)
    compress-type=zst
    compress-level=3

    # Parallel processing (adjust based on CPU cores)
    process-max=4

    # Logging
    log-level-console=info
    log-level-file=detail
    log-path=/tmp/pgbackrest

    [stolon]
    pg1-path=/stolon-data/postgres
    pg1-socket-path=/tmp
    pg1-user=stolon
---
apiVersion: v1
kind: Secret
metadata:
  name: pgbackrest-secrets
  namespace: stolon
type: Opaque
stringData:
  PGBACKREST_REPO1_S3_KEY: "YOUR_AWS_ACCESS_KEY"
  PGBACKREST_REPO1_S3_KEY_SECRET: "YOUR_AWS_SECRET_KEY"
  PGPASSWORD: "YOUR_SECURE_PASSWORD_HERE"
```

Apply the configuration:
```bash
kubectl apply -f pgbackrest-secrets.yaml
```

## Step 3: Deploy Sentinel (3 replicas for HA)

```yaml
# sentinel.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: stolon-sentinel
  namespace: stolon
spec:
  replicas: 3
  selector:
    matchLabels:
      component: stolon-sentinel
      stolon-cluster: kube-stolon
  template:
    metadata:
      labels:
        component: stolon-sentinel
        stolon-cluster: kube-stolon
    spec:
      containers:
        - name: stolon-sentinel
          image: sourcefuse/stolon:v0.18.0-pg18-backup
          command:
            - stolon-sentinel
          env:
            - name: STSENTINEL_CLUSTER_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.labels['stolon-cluster']
            - name: STSENTINEL_STORE_BACKEND
              value: kubernetes
            - name: STSENTINEL_KUBE_RESOURCE_KIND
              value: configmap
```

## Step 4: Deploy Keeper StatefulSet

```yaml
# keeper.yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: stolon-keeper
  namespace: stolon
spec:
  serviceName: stolon-keeper
  replicas: 3
  selector:
    matchLabels:
      component: stolon-keeper
      stolon-cluster: kube-stolon
  template:
    metadata:
      labels:
        component: stolon-keeper
        stolon-cluster: kube-stolon
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8080"
    spec:
      terminationGracePeriodSeconds: 10
      containers:
        - name: stolon-keeper
          image: sourcefuse/stolon:v0.18.0-pg18-backup
          imagePullPolicy: Always
          command:
            - /bin/bash
            - -ec
            - |
              # Generate keeper uid from pod index
              IFS='-' read -ra ADDR <<< "$(hostname)"
              export STKEEPER_UID="keeper${ADDR[-1]}"
              export POD_IP=$(hostname -i)
              export STKEEPER_PG_LISTEN_ADDRESS=$POD_IP
              export STOLON_DATA=/stolon-data

              # Fix permissions
              chown stolon:stolon $STOLON_DATA
              mkdir -p /tmp/pgbackrest
              chown stolon:stolon /tmp/pgbackrest

              exec gosu stolon stolon-keeper --data-dir $STOLON_DATA
          env:
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: STKEEPER_CLUSTER_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.labels['stolon-cluster']
            - name: STKEEPER_STORE_BACKEND
              value: kubernetes
            - name: STKEEPER_KUBE_RESOURCE_KIND
              value: configmap
            - name: STKEEPER_PG_REPL_USERNAME
              value: repluser
            - name: STKEEPER_PG_REPL_PASSWORD
              value: replpassword  # Change in production!
            - name: STKEEPER_PG_SU_USERNAME
              value: stolon
            - name: STKEEPER_PG_SU_PASSWORDFILE
              value: /etc/secrets/stolon/password
            - name: STKEEPER_METRICS_LISTEN_ADDRESS
              value: "0.0.0.0:8080"
          envFrom:
            - secretRef:
                name: pgbackrest-secrets
          ports:
            - containerPort: 5432
            - containerPort: 8080
          resources:
            requests:
              memory: "4Gi"
              cpu: "2"
            limits:
              memory: "8Gi"
              cpu: "4"
          volumeMounts:
            - name: data
              mountPath: /stolon-data
            - name: stolon
              mountPath: /etc/secrets/stolon
            - name: pgbackrest-config
              mountPath: /etc/pgbackrest/pgbackrest.conf
              subPath: pgbackrest.conf
      volumes:
        - name: stolon
          secret:
            secretName: stolon
        - name: pgbackrest-config
          configMap:
            name: pgbackrest-config
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: fast-ssd  # Use your fast storage class
        resources:
          requests:
            storage: 600Gi  # 500GB data + 20% headroom
```

## Step 5: Deploy Proxy and Service

```yaml
# proxy.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: stolon-proxy
  namespace: stolon
spec:
  replicas: 3
  selector:
    matchLabels:
      component: stolon-proxy
      stolon-cluster: kube-stolon
  template:
    metadata:
      labels:
        component: stolon-proxy
        stolon-cluster: kube-stolon
    spec:
      containers:
        - name: stolon-proxy
          image: sourcefuse/stolon:v0.18.0-pg18-backup
          command:
            - stolon-proxy
          env:
            - name: STPROXY_CLUSTER_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.labels['stolon-cluster']
            - name: STPROXY_STORE_BACKEND
              value: kubernetes
            - name: STPROXY_KUBE_RESOURCE_KIND
              value: configmap
            - name: STPROXY_LISTEN_ADDRESS
              value: "0.0.0.0"
          ports:
            - containerPort: 5432
---
apiVersion: v1
kind: Service
metadata:
  name: stolon-proxy
  namespace: stolon
spec:
  type: ClusterIP  # Or LoadBalancer for external access
  ports:
    - port: 5432
      targetPort: 5432
  selector:
    component: stolon-proxy
    stolon-cluster: kube-stolon
```

## Step 6: Apply All Manifests and Initialize

```bash
# Apply all manifests
kubectl apply -f sentinel.yaml
kubectl apply -f keeper.yaml
kubectl apply -f proxy.yaml

# Wait for keepers to be ready
kubectl -n stolon wait --for=condition=ready pod -l component=stolon-keeper --timeout=300s

# Initialize the cluster
kubectl -n stolon exec stolon-keeper-0 -- stolonctl \
  --cluster-name=kube-stolon \
  --store-backend=kubernetes \
  --kube-resource-kind=configmap \
  init

# Verify cluster status
kubectl -n stolon exec stolon-keeper-0 -- stolonctl \
  --cluster-name=kube-stolon \
  --store-backend=kubernetes \
  --kube-resource-kind=configmap \
  status
```

## Step 7: Enable WAL Archiving

```bash
kubectl -n stolon exec stolon-keeper-0 -- stolonctl \
  --cluster-name=kube-stolon \
  --store-backend=kubernetes \
  --kube-resource-kind=configmap \
  update --patch '{
    "pgParameters": {
      "archive_mode": "on",
      "archive_command": "pgbackrest --stanza=stolon archive-push %p",
      "archive_timeout": "60",
      "max_wal_size": "4GB",
      "min_wal_size": "1GB",
      "wal_level": "replica",
      "max_wal_senders": "10",
      "wal_keep_size": "1GB"
    }
  }'
```

## Step 8: Initialize pgBackRest

```bash
# Initialize pgBackRest stanza
kubectl -n stolon exec stolon-keeper-0 -- bash -c "
  mkdir -p /tmp/pgbackrest
  chown stolon:stolon /tmp/pgbackrest
  gosu stolon pgbackrest --stanza=stolon stanza-create
"

# Take initial full backup
kubectl -n stolon exec stolon-keeper-0 -- bash -c "
  gosu stolon pgbackrest --stanza=stolon backup --type=full
"

# Verify backup
kubectl -n stolon exec stolon-keeper-0 -- bash -c "
  gosu stolon pgbackrest --stanza=stolon info
"
```

## Step 9: Restore Data from Old Cluster

### Option A: Using pgBackRest (if old cluster had pgBackRest)

```bash
# Restore from existing pgBackRest repository
kubectl -n stolon exec stolon-keeper-0 -- bash -c "
  gosu stolon pgbackrest --stanza=stolon restore --delta
"
```

### Option B: Using pg_dump/pg_restore

```bash
# 1. Dump from old cluster (run from machine with access to old cluster)
pg_dump -h OLD_HOST -U postgres -Fc -Z0 -j4 mydb > mydb.dump

# 2. Copy dump to new keeper
kubectl cp mydb.dump stolon/stolon-keeper-0:/tmp/mydb.dump

# 3. Restore to new cluster
kubectl -n stolon exec stolon-keeper-0 -- bash -c "
  gosu stolon pg_restore -h /tmp -U stolon -d postgres --create -j4 /tmp/mydb.dump
"

# 4. Clean up
kubectl -n stolon exec stolon-keeper-0 -- rm /tmp/mydb.dump
```

### Option C: Using pg_basebackup (fastest for large databases)

```bash
# This requires stopping stolon-keeper temporarily
# 1. Scale down keeper
kubectl -n stolon scale statefulset stolon-keeper --replicas=0

# 2. Run pg_basebackup in a job
kubectl -n stolon run pg-restore --rm -it --restart=Never \
  --image=sourcefuse/stolon:v0.18.0-pg18-backup \
  --overrides='{
    "spec": {
      "containers": [{
        "name": "pg-restore",
        "image": "sourcefuse/stolon:v0.18.0-pg18-backup",
        "command": ["pg_basebackup", "-h", "OLD_PRIMARY_HOST", "-U", "repluser", "-D", "/stolon-data/postgres", "-P", "-Xs"],
        "volumeMounts": [{"name": "data", "mountPath": "/stolon-data"}]
      }],
      "volumes": [{"name": "data", "persistentVolumeClaim": {"claimName": "data-stolon-keeper-0"}}]
    }
  }'

# 3. Scale up keeper
kubectl -n stolon scale statefulset stolon-keeper --replicas=3
```

## Step 10: Deploy Automated Backup CronJobs

```yaml
# backup-cronjobs.yaml
---
# Daily incremental backup at 2 AM
apiVersion: batch/v1
kind: CronJob
metadata:
  name: pgbackrest-backup-incr
  namespace: stolon
spec:
  schedule: "0 2 * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: OnFailure
          containers:
            - name: backup
              image: sourcefuse/stolon:v0.18.0-pg18-backup
              command: ["bash", "-c"]
              args:
                - |
                  set -e
                  echo "Starting incremental backup at $(date)"
                  pgbackrest --stanza=stolon backup --type=incr
                  echo "Backup completed at $(date)"
                  pgbackrest --stanza=stolon info
              envFrom:
                - secretRef:
                    name: pgbackrest-secrets
              volumeMounts:
                - name: pgbackrest-config
                  mountPath: /etc/pgbackrest/pgbackrest.conf
                  subPath: pgbackrest.conf
          volumes:
            - name: pgbackrest-config
              configMap:
                name: pgbackrest-config
---
# Weekly full backup on Sunday at 1 AM
apiVersion: batch/v1
kind: CronJob
metadata:
  name: pgbackrest-backup-full
  namespace: stolon
spec:
  schedule: "0 1 * * 0"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: OnFailure
          containers:
            - name: backup
              image: sourcefuse/stolon:v0.18.0-pg18-backup
              command: ["bash", "-c"]
              args:
                - |
                  set -e
                  echo "Starting full backup at $(date)"
                  pgbackrest --stanza=stolon backup --type=full
                  echo "Full backup completed at $(date)"
                  pgbackrest --stanza=stolon info
              envFrom:
                - secretRef:
                    name: pgbackrest-secrets
              volumeMounts:
                - name: pgbackrest-config
                  mountPath: /etc/pgbackrest/pgbackrest.conf
                  subPath: pgbackrest.conf
          volumes:
            - name: pgbackrest-config
              configMap:
                name: pgbackrest-config
```

Apply:
```bash
kubectl apply -f backup-cronjobs.yaml
```

## Step 11: Verify Everything

```bash
# Check cluster status
kubectl -n stolon exec stolon-keeper-0 -- stolonctl \
  --cluster-name=kube-stolon \
  --store-backend=kubernetes \
  --kube-resource-kind=configmap \
  status

# Check backup status
kubectl -n stolon exec stolon-keeper-0 -- bash -c "gosu stolon pgbackrest --stanza=stolon info"

# Test database connection
kubectl -n stolon exec stolon-keeper-0 -- bash -c "
  gosu stolon psql -h /tmp -U stolon postgres -c 'SELECT version();'
"

# Check database size
kubectl -n stolon exec stolon-keeper-0 -- bash -c "
  gosu stolon psql -h /tmp -U stolon postgres -c 'SELECT pg_size_pretty(pg_database_size(current_database()));'
"
```

## Storage Cost Estimates (500GB Database)

| Component | Size | Monthly Cost (S3 Standard) |
|-----------|------|---------------------------|
| 4 Full backups | ~600GB | ~$14 |
| 7 Incrementals | ~100GB | ~$2 |
| WAL archives (7 days) | ~150GB | ~$3 |
| **Total** | ~850GB | **~$19/month** |

## Quick Reference Commands

```bash
# Manual full backup
kubectl -n stolon exec stolon-keeper-0 -- bash -c "gosu stolon pgbackrest --stanza=stolon backup --type=full"

# Manual incremental backup
kubectl -n stolon exec stolon-keeper-0 -- bash -c "gosu stolon pgbackrest --stanza=stolon backup --type=incr"

# Check backup status
kubectl -n stolon exec stolon-keeper-0 -- bash -c "gosu stolon pgbackrest --stanza=stolon info"

# Point-in-time restore
kubectl -n stolon exec stolon-keeper-0 -- bash -c "gosu stolon pgbackrest --stanza=stolon restore --target='2024-01-15 10:00:00' --target-action=promote"

# Restore latest
kubectl -n stolon exec stolon-keeper-0 -- bash -c "gosu stolon pgbackrest --stanza=stolon restore"

# Check cluster status
kubectl -n stolon exec stolon-keeper-0 -- stolonctl --cluster-name=kube-stolon --store-backend=kubernetes --kube-resource-kind=configmap status

# Failover to specific keeper
kubectl -n stolon exec stolon-keeper-0 -- stolonctl --cluster-name=kube-stolon --store-backend=kubernetes --kube-resource-kind=configmap failkeeper keeper1
```

## Monitoring

The keeper pods expose Prometheus metrics on port 8080:

```yaml
# servicemonitor.yaml (if using Prometheus Operator)
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: stolon-keeper
  namespace: stolon
spec:
  selector:
    matchLabels:
      component: stolon-keeper
  endpoints:
    - port: metrics
      interval: 30s
```

Key metrics to monitor:
- `stolon_cluster_status` - Cluster health
- `stolon_keeper_is_master` - Which keeper is primary
- `pg_stat_replication_lag_bytes` - Replication lag
