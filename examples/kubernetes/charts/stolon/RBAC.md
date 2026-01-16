# Stolon RBAC Requirements

This document explains the Kubernetes RBAC (Role-Based Access Control) permissions required by Stolon and why each permission is necessary.

## Overview

Stolon is a PostgreSQL high-availability cluster manager that coordinates multiple PostgreSQL instances. To function correctly in Kubernetes, Stolon components need specific permissions to interact with the Kubernetes API.

## Required Permissions

### Role Definition

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: stolon
rules:
  # Rule 1: Pod, ConfigMap, and Event access
  - apiGroups: [""]
    resources: ["pods", "configmaps", "events"]
    verbs: ["*"]

  # Rule 2: Endpoint read access
  - apiGroups: [""]
    resources: ["endpoints"]
    verbs: ["get", "list", "watch"]
```

## Detailed Permission Justification

### 1. Pods Access (`pods` - full access)

| Verb | Why Needed |
|------|------------|
| `get` | Sentinels query pod metadata to discover keeper IP addresses and status |
| `list` | Sentinels list all pods with stolon labels to find cluster members |
| `watch` | Sentinels watch for pod changes (new keepers, deleted pods) to trigger cluster reconfiguration |
| `create` | Not typically used, but included for potential future features |
| `update` | Update pod labels/annotations for cluster state tracking |
| `delete` | Not typically used by stolon itself |

**Component using this:** Sentinel

**What happens without it:**
- Sentinels cannot discover keeper pods
- New keepers won't be detected automatically
- Cluster member discovery fails

### 2. ConfigMaps Access (`configmaps` - full access)

| Verb | Why Needed |
|------|------------|
| `get` | Read cluster specification and state |
| `list` | Find stolon-related ConfigMaps |
| `watch` | Watch for cluster spec changes |
| `create` | Create ConfigMaps to store cluster state (kubernetes backend only) |
| `update` | Update cluster state after elections, failovers |
| `delete` | Clean up obsolete ConfigMaps |

**Component using this:** Sentinel, Keeper (when using `kubernetes` store backend)

**What happens without it:**
- **With `kubernetes` backend:** Cluster will not function at all - cannot store/retrieve cluster state
- **With `etcdv3` backend:** Minimal impact - cluster state stored in etcd, but some features may be limited

### 3. Events Access (`events` - full access)

| Verb | Why Needed |
|------|------------|
| `create` | Create Kubernetes events for important cluster operations |
| `patch` | Update existing events |

**Component using this:** All components (Sentinel, Keeper, Proxy)

**Events created for:**
- Master election
- Failover operations
- Keeper health changes
- Proxy routing changes
- Error conditions

**What happens without it:**
- No Kubernetes events logged for stolon operations
- Reduced observability in `kubectl get events`
- Cluster still functions, but operational visibility is limited

### 4. Endpoints Access (`endpoints` - read-only)

| Verb | Why Needed |
|------|------------|
| `get` | Read service endpoint information |
| `list` | List endpoints for service discovery |
| `watch` | Watch for endpoint changes |

**Component using this:** Proxy, Sentinel

**What happens without it:**
- Service discovery may be impacted
- Proxies might not discover keeper endpoints correctly

## Store Backend Comparison

| Permission | `etcdv3` Backend | `kubernetes` Backend |
|------------|------------------|----------------------|
| pods (read) | Required | Required |
| pods (write) | Optional | Optional |
| configmaps (read) | Optional | **Required** |
| configmaps (write) | Optional | **Required** |
| events | Optional | Optional |
| endpoints | Recommended | Recommended |

## Deployment Options

### Option 1: Full RBAC Creation (Default)

Chart creates ServiceAccount, Role, and RoleBinding.

```yaml
serviceAccount:
  create: true
rbac:
  create: true
```

### Option 2: Use Existing ServiceAccount

Your admin pre-creates a ServiceAccount with appropriate permissions.

```yaml
serviceAccount:
  create: false
  name: "my-existing-stolon-sa"
rbac:
  create: true  # Chart still creates Role/RoleBinding
```

### Option 3: Use Existing Role

Your admin pre-creates the Role, chart creates RoleBinding.

```yaml
serviceAccount:
  create: true
rbac:
  create: false
  existingRoleName: "my-existing-stolon-role"
```

### Option 4: Fully Pre-Provisioned RBAC

Your admin pre-creates everything (ServiceAccount, Role, RoleBinding).

```yaml
serviceAccount:
  create: false
  name: "my-existing-stolon-sa"
rbac:
  create: false
  useExistingRoleBinding: true
```

## Minimal Permissions for etcdv3 Backend

If your security policy requires minimal permissions and you're using `etcdv3` backend, you can use a reduced Role:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: stolon-minimal
rules:
  # Minimum required: pod discovery for sentinels
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list", "watch"]

  # Optional: events for observability
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["create", "patch"]
```

**Note:** This minimal configuration:
- Works only with `etcdv3` store backend
- Loses some features that depend on ConfigMap access
- May have reduced functionality in edge cases

## Security Considerations

1. **Namespace Scoped:** The Role is namespace-scoped, not cluster-wide. Stolon only has access to resources in its own namespace.

2. **No Secrets Access:** Stolon does not require access to Kubernetes Secrets through RBAC. Credentials are mounted as volumes.

3. **No Node Access:** Stolon does not need node-level permissions.

4. **No PVC Management:** PVCs are managed by the StatefulSet controller, not by Stolon directly.

## Troubleshooting RBAC Issues

### Symptoms of Missing Permissions

| Symptom | Likely Missing Permission |
|---------|---------------------------|
| Sentinels can't find keepers | `pods` read access |
| Cluster state not persisting (k8s backend) | `configmaps` write access |
| No events in `kubectl get events` | `events` create access |
| "forbidden" errors in logs | Check specific resource in error message |

### Debugging Commands

```bash
# Check if ServiceAccount exists
kubectl get sa stolon -n <namespace>

# Check Role permissions
kubectl describe role stolon -n <namespace>

# Check RoleBinding
kubectl describe rolebinding stolon -n <namespace>

# Test permissions (requires kubectl auth can-i)
kubectl auth can-i list pods --as=system:serviceaccount:<namespace>:stolon -n <namespace>
kubectl auth can-i create configmaps --as=system:serviceaccount:<namespace>:stolon -n <namespace>

# Check pod logs for RBAC errors
kubectl logs -l app.kubernetes.io/component=sentinel -n <namespace> | grep -i forbidden
```

## Pre-Provisioning Script

For environments where the Helm chart cannot create RBAC resources, use this script:

```bash
#!/bin/bash
NAMESPACE="stolon"
SA_NAME="stolon"
ROLE_NAME="stolon"

# Create ServiceAccount
kubectl create serviceaccount $SA_NAME -n $NAMESPACE

# Create Role
kubectl apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: $ROLE_NAME
  namespace: $NAMESPACE
rules:
  - apiGroups: [""]
    resources: ["pods", "configmaps", "events"]
    verbs: ["*"]
  - apiGroups: [""]
    resources: ["endpoints"]
    verbs: ["get", "list", "watch"]
EOF

# Create RoleBinding
kubectl create rolebinding $ROLE_NAME \
  --role=$ROLE_NAME \
  --serviceaccount=$NAMESPACE:$SA_NAME \
  -n $NAMESPACE

echo "RBAC resources created. Deploy Helm chart with:"
echo "helm install stolon ./stolon -n $NAMESPACE \\"
echo "  --set serviceAccount.create=false \\"
echo "  --set serviceAccount.name=$SA_NAME \\"
echo "  --set rbac.create=false \\"
echo "  --set rbac.useExistingRoleBinding=true"
```
