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

## Disaster Recovery & Restore Procedures

This section covers how to restore your database from pgBackRest backups in various disaster scenarios.

### Important: Common Pitfalls to Avoid

| Pitfall | Consequence | Prevention |
|---------|-------------|------------|
| Running restore while keepers are running | PVC Multi-Attach error | Always scale keepers to 0 first |
| Using wrong env var names | S3 authentication failure | Use `PGBACKREST_REPO1_S3_KEY` not `AWS_ACCESS_KEY_ID` |
| Removing recovery.signal too early | Invalid checkpoint / data corruption | Let PostgreSQL complete WAL recovery first |
| Wrong listen_addresses after restore | PostgreSQL fails to start | Fix postgresql.conf before starting |
| Choosing bad PITR target time | Database in inconsistent state | Pick time when DB was idle/consistent |

### Restore Scenario 1: Full Cluster Restore (Complete Data Loss)

Use this when you need to restore the entire cluster from backup.

```bash
# Step 1: Scale down all keepers
kubectl -n stolon scale statefulset stolon-keeper --replicas=0
kubectl -n stolon wait --for=delete pod -l component=stolon-keeper --timeout=120s

# Step 2: Create restore pod
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: pgbackrest-restore
  namespace: stolon
spec:
  restartPolicy: Never
  containers:
    - name: restore
      image: sourcefuse/stolon:v0.18.0-pg18-backup
      command:
        - /bin/bash
        - -c
        - |
          set -e
          echo "=== pgBackRest Full Restore ==="

          # Clean data directory
          rm -rf /stolon-data/postgres/*

          # Set up required directories with correct permissions
          mkdir -p /tmp/pgbackrest /var/spool/pgbackrest
          chown -R stolon:stolon /tmp/pgbackrest /var/spool/pgbackrest /stolon-data

          # List available backups
          echo "Available backups:"
          gosu stolon pgbackrest --stanza=stolon info

          # Restore from latest backup
          echo "Restoring from latest backup..."
          gosu stolon pgbackrest --stanza=stolon restore

          # Fix listen_addresses for recovery (will be reset by stolon later)
          sed -i "s/listen_addresses = .*/listen_addresses = 'localhost'/" /stolon-data/postgres/postgresql.conf

          # Start PostgreSQL to complete WAL recovery
          echo "Starting PostgreSQL for WAL recovery..."
          gosu stolon pg_ctl -D /stolon-data/postgres start -w -t 300 -o "-c listen_addresses=localhost"

          # Wait for recovery to complete
          echo "Waiting for recovery to complete..."
          until gosu stolon psql -h localhost -U stolon postgres -c "SELECT 1" 2>/dev/null; do
            sleep 2
          done

          # Verify databases
          echo "=== Restored Databases ==="
          gosu stolon psql -h localhost -U stolon postgres -c "SELECT datname, pg_size_pretty(pg_database_size(datname)) as size FROM pg_database WHERE datname NOT IN ('template0', 'template1');"

          # Clean shutdown
          gosu stolon pg_ctl -D /stolon-data/postgres stop -m fast

          # Remove recovery signals for stolon
          rm -f /stolon-data/postgres/recovery.signal /stolon-data/postgres/standby.signal
          rm -f /stolon-data/postgres/postmaster.pid

          echo "=== Restore Complete ==="
      envFrom:
        - secretRef:
            name: pgbackrest-secrets
      volumeMounts:
        - name: data
          mountPath: /stolon-data
        - name: pgbackrest-config
          mountPath: /etc/pgbackrest/pgbackrest.conf
          subPath: pgbackrest.conf
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: data-stolon-keeper-0
    - name: pgbackrest-config
      configMap:
        name: pgbackrest-config
EOF

# Step 3: Wait for restore to complete
kubectl -n stolon wait --for=condition=Ready pod/pgbackrest-restore --timeout=60s
kubectl -n stolon logs -f pgbackrest-restore

# Step 4: Clean up restore pod
kubectl -n stolon delete pod pgbackrest-restore

# Step 5: Scale keepers back up
kubectl -n stolon scale statefulset stolon-keeper --replicas=3
kubectl -n stolon wait --for=condition=ready pod -l component=stolon-keeper --timeout=300s

# Step 6: Verify cluster
kubectl -n stolon exec stolon-keeper-0 -- stolonctl \
  --cluster-name=kube-stolon \
  --store-backend=kubernetes \
  --kube-resource-kind=configmap \
  status
```

### Restore Scenario 2: Point-in-Time Recovery (PITR)

Use this to restore to a specific point in time (e.g., just before accidental data deletion).

```bash
# Step 1: Scale down keepers
kubectl -n stolon scale statefulset stolon-keeper --replicas=0
kubectl -n stolon wait --for=delete pod -l component=stolon-keeper --timeout=120s

# Step 2: Create PITR restore pod
# Replace TARGET_TIME with your desired recovery point (e.g., "2024-01-15 10:30:00")
TARGET_TIME="2024-01-15 10:30:00"

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: pgbackrest-pitr
  namespace: stolon
spec:
  restartPolicy: Never
  containers:
    - name: restore
      image: sourcefuse/stolon:v0.18.0-pg18-backup
      command:
        - /bin/bash
        - -c
        - |
          set -e
          echo "=== Point-in-Time Recovery to ${TARGET_TIME} ==="

          rm -rf /stolon-data/postgres/*
          mkdir -p /tmp/pgbackrest /var/spool/pgbackrest
          chown -R stolon:stolon /tmp/pgbackrest /var/spool/pgbackrest /stolon-data

          # Restore with PITR target
          gosu stolon pgbackrest --stanza=stolon restore \
            --type=time \
            --target="${TARGET_TIME}" \
            --target-action=promote

          # Fix listen_addresses
          sed -i "s/listen_addresses = .*/listen_addresses = 'localhost'/" /stolon-data/postgres/postgresql.conf

          # Complete recovery
          gosu stolon pg_ctl -D /stolon-data/postgres start -w -t 300 -o "-c listen_addresses=localhost"

          until gosu stolon psql -h localhost -U stolon postgres -c "SELECT 1" 2>/dev/null; do
            sleep 2
          done

          echo "=== Recovery completed to ${TARGET_TIME} ==="
          gosu stolon psql -h localhost -U stolon postgres -c "SELECT datname FROM pg_database WHERE datname NOT IN ('template0', 'template1');"

          gosu stolon pg_ctl -D /stolon-data/postgres stop -m fast
          rm -f /stolon-data/postgres/recovery.signal /stolon-data/postgres/standby.signal /stolon-data/postgres/postmaster.pid

          echo "=== PITR Complete ==="
      env:
        - name: TARGET_TIME
          value: "${TARGET_TIME}"
      envFrom:
        - secretRef:
            name: pgbackrest-secrets
      volumeMounts:
        - name: data
          mountPath: /stolon-data
        - name: pgbackrest-config
          mountPath: /etc/pgbackrest/pgbackrest.conf
          subPath: pgbackrest.conf
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: data-stolon-keeper-0
    - name: pgbackrest-config
      configMap:
        name: pgbackrest-config
EOF

# Step 3: Monitor and complete
kubectl -n stolon logs -f pgbackrest-pitr
kubectl -n stolon delete pod pgbackrest-pitr
kubectl -n stolon scale statefulset stolon-keeper --replicas=3
```

### Restore Scenario 3: Restore Specific Backup Set

Use this to restore from a specific backup (not necessarily the latest).

```bash
# First, list available backups
kubectl -n stolon exec stolon-keeper-0 -- bash -c "gosu stolon pgbackrest --stanza=stolon info"

# Example output:
#   full backup: 20240115-020000F
#   incr backup: 20240115-020000F_20240116-020000I
#   incr backup: 20240115-020000F_20240117-020000I

# Then restore specific backup set (replace BACKUP_LABEL)
BACKUP_LABEL="20240115-020000F_20240116-020000I"

# Scale down and restore using the same pod template as Scenario 1,
# but change the restore command to:
gosu stolon pgbackrest --stanza=stolon restore --set=${BACKUP_LABEL}
```

### Restore Scenario 4: Restore to New Cluster (Migration)

Use this to restore data to a completely new cluster.

```bash
# On NEW cluster (after Steps 1-6 from main setup):

# 1. Configure pgbackrest.conf to point to the SAME S3 bucket as source cluster

# 2. Initialize stanza (reads existing backups)
kubectl -n stolon exec stolon-keeper-0 -- bash -c "
  mkdir -p /tmp/pgbackrest
  chown stolon:stolon /tmp/pgbackrest
  gosu stolon pgbackrest --stanza=stolon stanza-create
"

# 3. List available backups from source
kubectl -n stolon exec stolon-keeper-0 -- bash -c "gosu stolon pgbackrest --stanza=stolon info"

# 4. Scale down and restore (use Scenario 1 or 2 procedure)
```

### Restore Verification Checklist

After any restore, verify the following:

```bash
# 1. Check cluster status
kubectl -n stolon exec stolon-keeper-0 -- stolonctl \
  --cluster-name=kube-stolon \
  --store-backend=kubernetes \
  --kube-resource-kind=configmap \
  status

# 2. Verify all databases exist
kubectl -n stolon exec stolon-keeper-0 -- bash -c "
  gosu stolon psql -h /tmp -U stolon postgres -c \"
    SELECT datname, pg_size_pretty(pg_database_size(datname)) as size
    FROM pg_database
    WHERE datname NOT IN ('template0', 'template1');
  \"
"

# 3. Check table counts in critical databases
kubectl -n stolon exec stolon-keeper-0 -- bash -c "
  gosu stolon psql -h /tmp -U stolon YOUR_DATABASE -c \"
    SELECT schemaname, relname, n_tup_ins as rows
    FROM pg_stat_user_tables
    ORDER BY n_tup_ins DESC
    LIMIT 10;
  \"
"

# 4. Verify replication is working
kubectl -n stolon exec stolon-keeper-0 -- bash -c "
  gosu stolon psql -h /tmp -U stolon postgres -c \"
    SELECT client_addr, state, sent_lsn, write_lsn, replay_lsn
    FROM pg_stat_replication;
  \"
"

# 5. Take a new backup after verification
kubectl -n stolon exec stolon-keeper-0 -- bash -c "
  gosu stolon pgbackrest --stanza=stolon backup --type=full
"
```

### Troubleshooting Restore Issues

#### Issue: "Multi-Attach error for volume"
```bash
# Cause: PVC is still attached to running keeper
# Solution: Ensure all keepers are scaled to 0
kubectl -n stolon scale statefulset stolon-keeper --replicas=0
kubectl -n stolon get pods -l component=stolon-keeper  # Should show no pods
```

#### Issue: "could not locate a valid checkpoint record"
```bash
# Cause: Recovery.signal was removed before WAL recovery completed
# Solution: Re-run restore and let PostgreSQL complete recovery before cleanup
```

#### Issue: "FATAL: cannot connect to invalid database"
```bash
# Cause: PITR stopped at transaction boundary during database creation/drop
# Solution: Choose a different target time when database was in consistent state
```

#### Issue: "could not bind IPv4 address"
```bash
# Cause: postgresql.conf has old pod's IP address
# Solution: Add this to restore script before starting PostgreSQL:
sed -i "s/listen_addresses = .*/listen_addresses = 'localhost'/" /stolon-data/postgres/postgresql.conf
```

#### Issue: "must specify restore_command"
```bash
# Cause: postgresql.auto.conf was cleared but recovery.signal still exists
# Solution: Either remove recovery.signal OR keep restore_command in postgresql.auto.conf
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
