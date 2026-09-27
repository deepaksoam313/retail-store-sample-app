# External Secrets Operator (ESO) — Hands On Guide
## Date: 2026-05-29 | Cluster: cluster-deepak-test | Region: ap-south-1

---

## What We Built

```
AWS Secrets Manager
      ↓
IAM Policy + IRSA
      ↓
ESO (External Secrets Operator)
      ↓
ClusterSecretStore
      ↓
ExternalSecret
      ↓
K8s Secret
      ↓
Nginx Pod (env vars)
```

---

## Step 1 — Create EKS Cluster

```bash
eksctl create cluster \
  --name eso-test-cluster \
  --region ap-south-1 \
  --nodegroup-name test-nodes \
  --node-type t3.medium \
  --nodes 2 \
  --nodes-min 1 \
  --nodes-max 3 \
  --managed
```

**What it does:**
- Creates VPC, EKS control plane, managed node group
- Updates kubeconfig automatically
- Takes ~15 minutes

**Verify:**
```bash
kubectl get nodes
kubectl get namespaces
kubectl config current-context
```

---

## Step 2 — Associate OIDC Provider

```bash
eksctl utils associate-iam-oidc-provider \
  --cluster cluster-deepak-test \
  --region ap-south-1 \
  --approve
```

**What it does:**
```
Creates trust relationship between EKS cluster and AWS IAM
Allows K8s service accounts to assume IAM roles
Without OIDC → pods need hardcoded AWS keys ❌
With OIDC    → pods use K8s service account token
             → AWS validates token via OIDC
             → issues temporary credentials ✅
             → no long-lived keys anywhere
```

**Verify:**
```bash
aws eks describe-cluster \
  --name cluster-deepak-test \
  --region ap-south-1 \
  --query "cluster.identity.oidc.issuer" \
  --output text
# output: https://oidc.eks.ap-south-1.amazonaws.com/id/08469EE00E46ED60B679499481937EBB
```

---

## Step 3 — Create Secret in AWS Secrets Manager

```bash
aws secretsmanager create-secret \
  --name "eso-test/nginx" \
  --description "Test secret for ESO hands-on" \
  --secret-string '{
    "APP_COLOR": "blue",
    "APP_MESSAGE": "Hello from Secrets Manager",
    "DB_PASSWORD": "supersecret123"
  }' \
  --region ap-south-1
```

**What it does:**
```
Stores secret securely in AWS Secrets Manager
Encrypted at rest using KMS
Access controlled via IAM policies
Full audit trail in CloudTrail

Why JSON:
  one secret = multiple key-value pairs
  cheaper (one secret = one billing unit)
  ESO extracts individual fields using "property"
```

**Output:**
```json
{
  "ARN": "arn:aws:secretsmanager:ap-south-1:964476970973:secret:eso-test/nginx-b8XAcD",
  "Name": "eso-test/nginx",
  "VersionId": "10063888-cb46-42da-b28c-da5f7e21974e"
}
```

---

## Step 4 — Create IAM Policy

```bash
cat > eso-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "SecretsManagerRead",
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret"
      ],
      "Resource": "arn:aws:secretsmanager:ap-south-1:964476970973:secret:eso-test/*"
    }
  ]
}
EOF

aws iam create-policy \
  --policy-name eso-test-policy \
  --policy-document file://eso-policy.json
```

**What it does:**
```
Defines WHAT actions are allowed on WHICH resources

Allows:
  secretsmanager:GetSecretValue   → read secret value
  secretsmanager:DescribeSecret   → read secret metadata

On resource:
  arn:aws:secretsmanager:ap-south-1:964476970973:secret:eso-test/*
  ↑ only secrets starting with "eso-test/" — least privilege ✅

Why least privilege:
  if ESO is compromised → can only read eso-test/* secrets
  cannot read other secrets in account
  cannot delete, cannot create
```

---

## Step 5 — Create IAM Service Account with IRSA

```bash
eksctl create iamserviceaccount \
  --name external-secrets \
  --namespace external-secrets \
  --cluster cluster-deepak-test \
  --region ap-south-1 \
  --attach-policy-arn arn:aws:iam::964476970973:policy/eso-test-policy \
  --approve \
  --override-existing-serviceaccounts
```

**What it does:**
```
Binds IAM role to K8s service account
Pod using that service account → gets IAM permissions
No AWS keys needed in pod ✅

Creates:
  1. IAM Role with trust policy:
     "who can assume this role?"
     → only K8s service account "external-secrets"
       in namespace "external-secrets"
       in cluster "cluster-deepak-test"

  2. K8s ServiceAccount with annotation:
     eks.amazonaws.com/role-arn: arn:aws:iam::964476970973:role/...

How it works at runtime:
  ESO pod starts
    ↓
  uses service account token (mounted automatically by K8s)
    ↓
  sends token to AWS STS
    ↓
  AWS validates: "is this token from our trusted OIDC provider?"
    ↓
  YES → issues temporary credentials (15min expiry, auto-renewed)
    ↓
  ESO uses credentials to call Secrets Manager ✅
```

---

## Step 6 — Install ESO via Helm

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm repo update

helm install external-secrets \
  external-secrets/external-secrets \
  --namespace external-secrets \
  --create-namespace \
  --set serviceAccount.create=false \
  --set serviceAccount.name=external-secrets
```

**Why `serviceAccount.create=false`:**
```
eksctl already created service account with IRSA annotation
If helm creates new one → no IRSA annotation → no AWS access ❌
So we reuse the one eksctl created ✅
```

**3 pods installed:**
```
external-secrets            → main controller
                              watches ExternalSecret objects
                              fetches from Secrets Manager
                              creates K8s secrets

external-secrets-webhook    → validates ExternalSecret manifests
                              before they are applied
                              rejects invalid configs

external-secrets-cert-controller → manages TLS certs
                                   for webhook communication
                                   internal cluster security
```

**Verify:**
```bash
kubectl get pods -n external-secrets
# all 3 should be 1/1 Running ✅

kubectl get crd | grep external-secrets
# should show 23 CRDs installed

kubectl api-resources | grep secretstore
# clustersecretstores   css   external-secrets.io/v1   false   ClusterSecretStore
# secretstores          ss    external-secrets.io/v1   true    SecretStore
```

> **Note:** API version is `external-secrets.io/v1` NOT `v1beta1` in newer ESO versions

---

## Step 7 — Create ClusterSecretStore

```bash
cat > cluster-secret-store.yaml << 'EOF'
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: aws-secrets-manager
spec:
  provider:
    aws:
      service: SecretsManager
      region: ap-south-1
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets
            namespace: external-secrets
EOF

kubectl apply -f cluster-secret-store.yaml
```

**What it does:**
```
Tells ESO HOW to connect to AWS Secrets Manager
Cluster-scoped = works for ALL namespaces

ClusterSecretStore vs SecretStore:
  ClusterSecretStore → one store for entire cluster ✅
  SecretStore        → one store per namespace

Each field:
  provider: aws          → use AWS as backend
  service: SecretsManager → AWS Secrets Manager
                            (could also be ParameterStore)
  region: ap-south-1    → which AWS region
  auth.jwt              → use JWT token from service account (IRSA)
  serviceAccountRef     → which service account has IRSA role

What happens when applied:
  ESO reads ClusterSecretStore
  tries to connect to AWS Secrets Manager using IRSA
  connection successful → STATUS: Valid, READY: True ✅
  if IRSA wrong   → STATUS: Invalid ❌
  if region wrong → STATUS: Invalid ❌
```

**Verify:**
```bash
kubectl get clustersecretstore
# NAME                  AGE   STATUS   CAPABILITIES   READY
# aws-secrets-manager   21s   Valid    ReadWrite      True  ✅
```

---

## Step 8 — Create Namespace + ExternalSecret

```bash
kubectl create namespace eso-test
```

```bash
cat > external-secret.yaml << 'EOF'
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: nginx-secret
  namespace: eso-test
spec:
  refreshInterval: 1h

  secretStoreRef:
    name: aws-secrets-manager
    kind: ClusterSecretStore

  target:
    name: nginx-secret
    creationPolicy: Owner

  data:
  - secretKey: APP_COLOR
    remoteRef:
      key: eso-test/nginx
      property: APP_COLOR

  - secretKey: APP_MESSAGE
    remoteRef:
      key: eso-test/nginx
      property: APP_MESSAGE

  - secretKey: DB_PASSWORD
    remoteRef:
      key: eso-test/nginx
      property: DB_PASSWORD
EOF

kubectl apply -f external-secret.yaml
```

**What it does:**
```
Tells ESO WHAT to fetch from Secrets Manager
and WHERE to store it (which K8s secret)
Namespace-scoped = lives in eso-test namespace

Each field:
  refreshInterval: 1h    → re-fetch every hour automatically
  secretStoreRef         → which ClusterSecretStore to use
  target.name            → K8s secret name to create
  creationPolicy: Owner  → ESO owns this secret
                           if ExternalSecret deleted
                           K8s secret also deleted
  data[].secretKey       → key name in K8s secret
  data[].remoteRef.key   → Secrets Manager secret name
  data[].remoteRef.property → field inside JSON value

What happens when applied:
  ESO controller detects new ExternalSecret
    ↓
  calls AWS Secrets Manager API:
    GetSecretValue(SecretId="eso-test/nginx")
    ↓
  receives JSON: {APP_COLOR: blue, APP_MESSAGE: ..., DB_PASSWORD: ...}
    ↓
  extracts each property
    ↓
  base64 encodes each value
    ↓
  creates K8s Secret "nginx-secret" in eso-test namespace
    ↓
  STATUS: SecretSynced, READY: True ✅
  every 1 hour → repeats → updates K8s secret
```

**Verify:**
```bash
kubectl get externalsecret -n eso-test
# NAME           STORE                  REFRESH   STATUS         READY   LAST SYNC
# nginx-secret   aws-secrets-manager    1h        SecretSynced   True    9s  ✅

# verify K8s secret created
kubectl get secret nginx-secret -n eso-test

# decode and verify values
kubectl get secret nginx-secret -n eso-test \
  -o jsonpath='{.data.APP_COLOR}' | base64 -d
# output: blue ✅
```

---

## Step 9 — Create Nginx Deployment

```bash
cat > nginx-deployment.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-test
  namespace: eso-test
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nginx-test
  template:
    metadata:
      labels:
        app: nginx-test
    spec:
      containers:
      - name: nginx
        image: nginx:alpine
        ports:
        - containerPort: 80
        env:
        - name: APP_COLOR
          valueFrom:
            secretKeyRef:
              name: nginx-secret
              key: APP_COLOR
        - name: APP_MESSAGE
          valueFrom:
            secretKeyRef:
              name: nginx-secret
              key: APP_MESSAGE
        - name: DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: nginx-secret
              key: DB_PASSWORD
EOF

kubectl apply -f nginx-deployment.yaml
```

**What happens at pod start:**
```
K8s scheduler places pod on node
  ↓
kubelet on node starts pod
  ↓
kubelet reads pod spec → sees secretKeyRef
  ↓
kubelet fetches nginx-secret from K8s API
  ↓
decodes base64 value
  ↓
injects as environment variable into container process
  ↓
nginx process starts with:
  APP_COLOR=blue
  APP_MESSAGE=Hello from Secrets Manager
  DB_PASSWORD=supersecret123 ✅
```

**Verify:**
```bash
kubectl get pods -n eso-test

kubectl exec -it \
  $(kubectl get pod -n eso-test -l app=nginx-test -o jsonpath='{.items[0].metadata.name}') \
  -n eso-test -- sh -c "env | grep -E 'APP_COLOR|APP_MESSAGE|DB_PASSWORD'"

# APP_COLOR=blue ✅
# APP_MESSAGE=Hello from Secrets Manager ✅
# DB_PASSWORD=supersecret123 ✅
```

---

## Step 10 — Test Secret Rotation

```bash
# update secret in Secrets Manager
aws secretsmanager update-secret \
  --secret-id "eso-test/nginx" \
  --secret-string '{
    "APP_COLOR": "green",
    "APP_MESSAGE": "Updated from Secrets Manager",
    "DB_PASSWORD": "newpassword456"
  }' \
  --region ap-south-1

# force ESO to refresh immediately (dont wait 1hr)
kubectl annotate externalsecret nginx-secret \
  -n eso-test \
  force-sync=$(date +%s) \
  --overwrite

# verify K8s secret updated
kubectl get secret nginx-secret -n eso-test \
  -o jsonpath='{.data.APP_COLOR}' | base64 -d
# output: green ✅

# restart pod to pick up new env vars
kubectl rollout restart deployment nginx-test -n eso-test

# verify new value in pod
kubectl exec -it \
  $(kubectl get pod -n eso-test -l app=nginx-test -o jsonpath='{.items[0].metadata.name}') \
  -n eso-test -- sh -c "env | grep APP_COLOR"
# APP_COLOR=green ✅
```

---

## Why Pod Restart is Needed

```
ESO updates K8s secret automatically ✅
  Secrets Manager → K8s secret "nginx-secret" updated

BUT env vars are injected at pod START time
  pod reads secret → injects as env var → pod runs
  secret updates → pod does NOT know ❌
  pod still has old value in memory

Pod restart → reads updated K8s secret → new value ✅
```

### 3 Ways to Handle in Production

| Method | How | Auto? | Use Case |
|--------|-----|-------|----------|
| Manual restart | `kubectl rollout restart` | ❌ | Testing only |
| Reloader | watches secret, auto-restarts | ✅ | Prod standard |
| Volume mount | file updates live, no restart | ✅ | TLS certs, config files |

### Reloader (Industry Standard)
```bash
helm repo add stakater https://stakater.github.io/stakater-charts
helm install reloader stakater/reloader -n eso-test

# add annotation to deployment
annotations:
  secret.reloader.stakater.com/reload: "nginx-secret"

# now: secret updates → Reloader detects → auto-restarts pod ✅
```

### Volume Mount (No Restart Needed)
```yaml
volumeMounts:
- name: secret-vol
  mountPath: /app/secrets
  readOnly: true
volumes:
- name: secret-vol
  secret:
    secretName: nginx-secret
# file inside pod updates automatically when secret changes ✅
# app must read file on every request
```

---

## Complete End-to-End Flow

```
Developer/Terraform
  creates secret in AWS Secrets Manager
          ↓
OIDC Provider
  trust between EKS and AWS IAM established
          ↓
IAM Policy + IRSA
  ESO service account gets permission to read secrets
  no hardcoded credentials anywhere
          ↓
ESO Operator (3 pods running)
  watches for ExternalSecret objects
          ↓
ClusterSecretStore
  ESO connects to AWS Secrets Manager
  STATUS: Valid ✅
          ↓
ExternalSecret
  ESO fetches "eso-test/nginx" from Secrets Manager
  extracts APP_COLOR, APP_MESSAGE, DB_PASSWORD
  creates K8s Secret "nginx-secret"
  refreshes every 1 hour automatically
          ↓
K8s Secret "nginx-secret"
  base64 encoded values
  owned by ESO
  auto-updated on refresh
          ↓
Nginx Deployment
  pod reads env vars from K8s secret at start time
  APP_COLOR=blue, APP_MESSAGE=..., DB_PASSWORD=... ✅
          ↓
Secret Rotation
  update Secrets Manager → ESO syncs → K8s secret updates
  pod restart (or Reloader) → picks up new values ✅
```

---

## ESO vs CSI Driver

| Feature | CSI Driver | ESO |
|---------|-----------|-----|
| Secret timing | During pod start | Before pod starts ✅ |
| Pod spec | Complex (volume mount) | Simple (envFrom) ✅ |
| Auto rotation | Manual restart | Every refreshInterval ✅ |
| Secret exists without pod | ❌ | ✅ |
| Debugging | Complex | Simple ✅ |
| File support | ✅ Yes | Limited |

---

## Why ESO is Better Than Hardcoding Secrets

```
Hardcoded (bad):                ESO (good):
────────────────                ──────────
secret in values.yaml ❌        secret in AWS only ✅
secret in Git ❌                no secret in Git ✅
manual rotation ❌              auto-rotation every 1hr ✅
no audit trail ❌               CloudTrail logs every access ✅
anyone with repo = secret ❌    IAM controls who reads ✅
static credentials ❌           temporary IRSA credentials ✅
```

---

## Cleanup

```bash
# delete test resources
kubectl delete namespace eso-test
kubectl delete clustersecretstore aws-secrets-manager

# delete ESO
helm uninstall external-secrets -n external-secrets

# delete secret from Secrets Manager
aws secretsmanager delete-secret \
  --secret-id "eso-test/nginx" \
  --force-delete-without-recovery \
  --region ap-south-1

# delete IAM policy
aws iam delete-policy \
  --policy-arn arn:aws:iam::964476970973:policy/eso-test-policy

# delete cluster
eksctl delete cluster \
  --name cluster-deepak-test \
  --region ap-south-1
```

---

## Key Commands Reference

```bash
# check ESO pods
kubectl get pods -n external-secrets

# check ClusterSecretStore status
kubectl get clustersecretstore

# check ExternalSecret sync status
kubectl get externalsecret -n <namespace>

# check K8s secret created by ESO
kubectl get secret <secret-name> -n <namespace>

# decode secret value
kubectl get secret <secret-name> -n <namespace> \
  -o jsonpath='{.data.<key>}' | base64 -d

# force ESO to re-sync immediately
kubectl annotate externalsecret <name> \
  -n <namespace> \
  force-sync=$(date +%s) --overwrite

# check ESO logs
kubectl logs -n external-secrets \
  -l app.kubernetes.io/name=external-secrets -f
```
