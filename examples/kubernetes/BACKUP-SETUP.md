# Stolon Backup Setup with pgBackRest

For 500GB+ PostgreSQL databases with incremental backups.

## Image

```
sourcefuse/stolon:v0.18.0-pg18-backup
```

## Features

- **Incremental backups** - Only changed blocks, not entire database
- **Parallel processing** - Fast backup/restore with multiple threads
- **Compression** - Reduces 500GB to ~150GB with zstd
- **S3/GCS/Azure support** - Native cloud storage integration
- **Point-in-time recovery (PITR)** - Restore to any point in time
- **WAL archiving** - Continuous backup of transaction logs

## Quick Start

### 1. Configure S3/GCS credentials

Edit `pgbackrest-config.yaml` and update:
- `repo1-s3-bucket`: Your backup bucket name
- `repo1-s3-region`: Your AWS region
- `PGBACKREST_REPO1_S3_KEY`: Your access key
- `PGBACKREST_REPO1_S3_KEY_SECRET`: Your secret key

### 2. Deploy pgBackRest config

```bash
kubectl apply -f pgbackrest-config.yaml
```

### 3. Enable WAL archiving in Stolon

```bash
kubectl exec stolon-keeper-0 -- stolonctl \
  --cluster-name=kube-stolon \
  --store-backend=kubernetes \
  --kube-resource-kind=configmap \
  update --patch '{
    "pgParameters": {
      "archive_mode": "on",
      "archive_command": "pgbackrest --stanza=stolon archive-push %p",
      "archive_timeout": "60"
    }
  }'
```

### 4. Initialize the stanza (first time only)

```bash
kubectl exec stolon-keeper-0 -- bash -c "
  mkdir -p /tmp/pgbackrest
  chown stolon:stolon /tmp/pgbackrest
  gosu stolon pgbackrest --stanza=stolon stanza-create
"
```

### 5. Take initial full backup

```bash
kubectl exec stolon-keeper-0 -- bash -c "gosu stolon pgbackrest --stanza=stolon backup --type=full"
```

## Backup Schedule

| Type | Schedule | Retention | Size (500GB DB) |
|------|----------|-----------|-----------------|
| Full | Sunday 1 AM | 4 weeks | ~150GB compressed |
| Incremental | Daily 2 AM | 7 days | ~5-20GB each |
| WAL | Continuous | 7 days | ~1-5GB/day |

## Commands

```bash
# Check backup status
kubectl exec stolon-keeper-0 -- bash -c "gosu stolon pgbackrest --stanza=stolon info"

# Manual incremental backup
kubectl exec stolon-keeper-0 -- bash -c "gosu stolon pgbackrest --stanza=stolon backup --type=incr"

# Manual full backup
kubectl exec stolon-keeper-0 -- bash -c "gosu stolon pgbackrest --stanza=stolon backup --type=full"

# Restore (PITR to specific time)
kubectl exec stolon-keeper-0 -- bash -c "gosu stolon pgbackrest --stanza=stolon restore \
  --target='2024-01-15 10:00:00' \
  --target-action=promote"

# Restore latest
kubectl exec stolon-keeper-0 -- bash -c "gosu stolon pgbackrest --stanza=stolon restore"
```

## Storage Estimates (500GB database)

| Component | Size | Monthly Cost (S3) |
|-----------|------|-------------------|
| 4 Full backups | ~600GB | ~$14 |
| 7 Incremental | ~100GB | ~$2 |
| WAL archives | ~150GB | ~$3 |
| **Total** | ~850GB | **~$19/month** |

## Cloud Provider Examples

### AWS S3
```ini
repo1-type=s3
repo1-s3-endpoint=s3.amazonaws.com
repo1-s3-bucket=my-backup-bucket
repo1-s3-region=us-east-1
```

### Google Cloud Storage
```ini
repo1-type=gcs
repo1-gcs-bucket=my-backup-bucket
```

### Azure Blob
```ini
repo1-type=azure
repo1-azure-container=my-backup-container
repo1-azure-account=myaccount
```

### MinIO (Self-hosted S3)
```ini
repo1-type=s3
repo1-s3-endpoint=minio.example.com:9000
repo1-s3-bucket=backups
repo1-s3-uri-style=path
repo1-storage-verify-tls=n
```

## Troubleshooting

### Permission denied errors
```bash
# Ensure pgbackrest runs as stolon user
kubectl exec stolon-keeper-0 -- bash -c "
  mkdir -p /tmp/pgbackrest
  chown stolon:stolon /tmp/pgbackrest
"
```

### Cannot connect to PostgreSQL
```bash
# Verify PGPASSWORD is set in environment
kubectl exec stolon-keeper-0 -- env | grep PGPASSWORD
```

### S3 connection errors
```bash
# Verify S3 credentials are set
kubectl exec stolon-keeper-0 -- env | grep PGBACKREST_REPO1_S3
```
