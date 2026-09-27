# Senior DevOps Engineer — Interview Preparation Guide
## Complete Notes + Cheat Sheet

---

# SECTION 1 — ArgoCD HA (High Availability)

## Key Points to Remember
- ArgoCD HA = run every component with 3 replicas
- 5 components: server, application-controller, repo-server, dex-server, redis
- application-controller uses StatefulSet (needs stable identity for sharding)
- Redis uses Sentinel mode (1 master + 2 slaves + 3 sentinels)
- PodDisruptionBudget ensures minimum 2 pods always running
- Redis Sentinel quorum = 2 (need 2 sentinels to agree on failover)

## Components and Roles
- **argocd-server** → UI + API (front desk)
- **application-controller** → sync engine, watches Git vs cluster (brain)
- **repo-server** → clones Git, renders Helm charts (librarian)
- **dex-server** → SSO authentication (security guard)
- **redis** → shared cache between all components (shared memory)

## Sharding
- 3 app-controllers each handle different apps
- controller-0 → apps 1-3, controller-1 → apps 4-6, controller-2 → apps 7-9
- If one dies → others take over its shards

## Install Command
```bash
helm install argocd argo/argo-cd \
  --namespace argocd \
  --version 6.7.0 \
  --values values-production.yaml \
  --wait --timeout 15m
```

---

# SECTION 2 — GitLab/Okta OIDC SSO

## Key Points to Remember
- SSO = one login for all tools
- ArgoCD uses DEX as built-in identity broker
- DEX connects to GitLab/Okta and issues tokens
- Groups claim MUST be configured in Okta/GitLab to send group info
- Disable local admin AFTER SSO is verified working
- Credentials stored in Secrets Manager, fetched by ESO

## GitLab SSO Flow
```
User clicks Login → ArgoCD → Dex → GitLab
GitLab validates → sends token with groups
Dex validates → passes to ArgoCD
ArgoCD checks RBAC → grants access
```

## Okta vs GitLab
- **GitLab SSO** → dev tools only, free
- **Okta SSO** → enterprise everything (AWS, Grafana, ArgoCD), paid
- Okta supports OIDC + SAML + LDAP
- One Okta disable → loses access to everything

## Important Config
```yaml
dex.config: |
  connectors:
  - type: oidc        # for Okta
    config:
      issuer: https://yourcompany.okta.com
      clientID: $dex.okta.clientID
      clientSecret: $dex.okta.clientSecret
      scopes: [openid, profile, email, groups]
      insecureEnableGroups: true
```

---

# SECTION 3 — ArgoCD RBAC

## Key Points to Remember
- Two built-in roles: role:admin, role:readonly
- Default should always be role:readonly
- Policy format: `p, SUBJECT, RESOURCE, ACTION, OBJECT, EFFECT`
- Group mapping: `g, GROUP_NAME, ROLE_NAME`
- Two levels: Global RBAC (argocd-rbac-cm) + Project RBAC (AppProject)
- scopes: "[groups]" must be set to use group claims

## Policy Examples
```
p, role:developer, applications, get, */*, allow
p, role:developer, applications, sync, */*, allow
p, role:developer, logs, get, */*, allow
g, argocd-developers, role:developer
```

## Resources Available
- applications, clusters, repositories, logs, exec, projects, accounts

## Actions Available
- get, create, update, delete, sync, override, action

---

# SECTION 4 — ArgoCD Notifications

## Key Points to Remember
- 3 concepts: Trigger (WHEN), Template (WHAT), Service (WHERE)
- Services: Slack, Email, Teams, PagerDuty
- Triggers: on-deployed, on-sync-failed, on-health-degraded, on-out-of-sync
- Subscribe apps via annotations
- Credentials stored in Secrets Manager, fetched by ESO

## Annotation to Subscribe App
```yaml
annotations:
  notifications.argoproj.io/subscribe.on-deployed.slack: deployments
  notifications.argoproj.io/subscribe.on-sync-failed.slack: alerts
```

## Default Triggers (all apps)
```yaml
defaultTriggers: |
  - on-sync-failed
  - on-health-degraded
```

---

# SECTION 5 — ArgoCD Disaster Recovery

## Key Points to Remember
- Git IS the backup (RPO = 0)
- RTO target = 30 minutes
- 3 layers: Git + Secrets Manager + Velero
- Velero backs up what Git and Secrets Manager cannot: cluster credentials
- App of Apps = single kubectl apply restores everything
- argocd-secret must be backed up to Secrets Manager

## What Each Backup Covers
- **Git** → Application definitions, RBAC, Helm charts
- **Secrets Manager** → argocd-secret, OAuth credentials
- **Velero** → cluster credentials, repo credentials, everything in namespace

## When to Use Each
- Bad deployment → Git rollback (2 min)
- Wrong config → Git revert (5 min)
- Secret lost → Secrets Manager (5 min)
- Namespace deleted → Velero restore (5 min)
- Cluster deleted → Terraform + Git + Velero (45 min)

## DR Commands
```bash
# Restore from Velero
velero restore create --from-backup argocd-backup-latest

# Apply root app after cluster recreate
kubectl apply -f argocd/root-app.yaml
```

---

# SECTION 6 — App of Apps Pattern

## Key Points to Remember
- ONE root application manages ALL other applications
- Root app watches a folder in Git (argocd/applications/)
- Adding new service = add yaml file to folder + git push
- Removing service = remove yaml file + git push
- Best for: different services on single cluster
- DR = apply root-app.yaml → everything comes back

## Structure
```
argocd/
  root-app.yaml              ← apply this ONE file
  applications/
    retail-store-cart.yaml   ← managed by root-app
    retail-store-orders.yaml ← managed by root-app
    grafana.yaml             ← managed by root-app
```

## Root App Key Config
```yaml
spec:
  source:
    path: argocd/applications    # ← watches this folder
  syncPolicy:
    automated:
      prune: true      # ← delete apps removed from Git
      selfHeal: true
```

---

# SECTION 7 — ApplicationSet

## Key Points to Remember
- ONE template generates MANY applications
- 3 generators: List, Cluster, Git
- Matrix generator = combine multiple generators
- Best for: same service on multiple clusters
- New cluster added → apps auto-created (Cluster generator)
- New service added → apps auto-created (Git generator)

## 3 Generators
- **List** → explicit list of clusters/environments
- **Cluster** → auto-discovers registered clusters by label
- **Git** → auto-discovers folders in Git repo

## When to Use
- App of Apps → different services, single cluster
- ApplicationSet → same service, multiple clusters
- Both together → App of Apps + ApplicationSet

## Matrix Example
```
5 services × 3 clusters = 15 Applications
Generated from ONE ApplicationSet ✅
```

---

# SECTION 8 — Sync Windows

## Key Points to Remember
- Two types: allow (can deploy) and deny (cannot deploy)
- Cron format: "minute hour day month weekday"
- manualSync: true = emergency override allowed
- manualSync: false = absolute lockdown
- Configured in AppProject (all apps) or Application (specific app)

## Common Schedules
```
"0 9 * * 1-5"   → 9am Monday to Friday
"0 18 * * 1-5"  → 6pm Monday to Friday
"0 0 * * 6"     → midnight Saturday (start of weekend)
```

## Production Setup
```yaml
syncWindows:
- kind: allow
  schedule: "0 9 * * 1-5"
  duration: 9h
  manualSync: true      # ← emergency override
- kind: deny
  schedule: "0 0 * * 6"
  duration: 48h
  manualSync: true      # ← SRE can override
```

---

# SECTION 9 — ArgoCD Projects

## Key Points to Remember
- Project = security boundary (like department in company)
- Controls: sourceRepos, destinations, resources, RBAC, sync windows
- NEVER use default project in production
- One project per team/application
- namespaceResourceBlacklist: Secret → never allow secrets in Git
- AppProject + Global RBAC work together

## What Projects Control
- **sourceRepos** → which Git repos allowed
- **destinations** → which clusters/namespaces allowed
- **namespaceResourceWhitelist** → which K8s resources allowed
- **clusterResourceWhitelist** → which cluster resources allowed
- **roles** → project level RBAC

## Security Best Practice
```yaml
namespaceResourceBlacklist:
- group: ""
  kind: Secret    # ← never allow secrets in Git ✅
```

---

# SECTION 10 — ESO vs CSI Driver

## Key Points to Remember
- Both fetch from AWS Secrets Manager
- CSI Driver = fetches at pod startup via volume mount
- ESO = fetches independently before pod starts
- ESO is simpler, more reliable for env vars
- CSI Driver better for file-based secrets (TLS certs, SSH keys)
- ESO auto-refreshes every hour (refreshInterval)

## Key Differences
| Feature | CSI Driver | ESO |
|---------|-----------|-----|
| Pod spec | Complex (volume mount) | Simple (envFrom only) |
| Secret timing | During pod start | Before pod starts |
| Auto rotation | Manual restart | Every hour ✅ |
| File support | ✅ Yes | ❌ Limited |
| Debugging | Complex | Simple ✅ |

## ESO 3 Resources
- **ClusterSecretStore** → connects ESO to AWS (cluster-wide)
- **SecretStore** → connects ESO to AWS (namespace-scoped)
- **ExternalSecret** → what to fetch, where to store

---

# SECTION 11 — GKE Workload Identity

## Key Points to Remember
- Same concept as EKS IRSA but for GCP
- No JSON key files needed
- K8s SA annotated with GCP SA email
- GKE exchanges K8s token for GCP token automatically
- Annotation: `iam.gke.io/gcp-service-account`
- Must enable on cluster AND node pool

## 4 Things Needed
1. GKE cluster with workload_identity_config enabled
2. GCP Service Account with Secret Manager access
3. Workload Identity binding (K8s SA → GCP SA)
4. K8s ServiceAccount with GCP SA annotation

## Trust Setup
```hcl
# Allow K8s SA to impersonate GCP SA
member = "serviceAccount:PROJECT.svc.id.goog[NAMESPACE/K8S_SA]"
role   = "roles/iam.workloadIdentityUser"
```

---

# SECTION 12 — AKS Workload Identity

## Key Points to Remember
- Same concept as EKS IRSA but for Azure
- Uses User Assigned Managed Identity (not System Assigned)
- Federated Identity Credential = trust relationship
- Annotation: `azure.workload.identity/client-id`
- Must enable oidc_issuer_enabled AND workload_identity_enabled
- Azure Key Vault = equivalent of AWS Secrets Manager

## 4 Things Needed
1. AKS with OIDC + Workload Identity enabled
2. User Assigned Managed Identity
3. Federated Identity Credential (trust relationship)
4. K8s ServiceAccount with client-id annotation

## Three Clouds Comparison
| | AWS EKS | GKE | AKS |
|--|---------|-----|-----|
| Secret Store | Secrets Manager | Secret Manager | Key Vault |
| Identity | IAM Role | GCP SA | Managed Identity |
| K8s Annotation | eks.amazonaws.com/role-arn | iam.gke.io/gcp-service-account | azure.workload.identity/client-id |
| Trust Setup | OIDC Provider | Workload Pool | Federated Credential |

---

# SECTION 13 — Helm Chart Rationalisation

## Key Points to Remember
- Rationalise = standardise, clean up, organise
- All 20+ charts should have same structure
- Pin exact versions (never latest, never ~1.2)
- Library chart = shared templates, no duplication
- Internal OCI registry = no external dependencies
- Renovate Bot = automated version update PRs

## 5 Main Tasks
1. Audit current state (helm list -A)
2. Standardise chart structure (same values.yaml keys)
3. Create library/base chart (shared templates)
4. Push to internal OCI registry (ECR)
5. Setup Renovate Bot (automated updates)

## Standard values.yaml Keys (every chart must have)
- replicaCount, image, serviceAccount
- resources (limits + requests)
- readinessProbe, livenessProbe
- autoscaling, podDisruptionBudget
- secrets, ingress, metrics

## Version Strategy
```
PATCH (1.2.x) → auto-merge via Renovate ✅
MINOR (1.x.0) → review needed
MAJOR (x.0.0) → careful review + testing
```

---

# SECTION 14 — Docker Secrets Best Practices

## Key Points to Remember
- NEVER store secrets in Docker image
- Image = same in ALL environments
- Secrets = different per environment, injected at runtime
- Docker layers store everything — even deleted secrets
- .env files must be in .dockerignore
- Build args with secrets are stored in image layers

## What Goes Where
- **Image (build time)** → code, dependencies, runtime, safe defaults
- **ConfigMap (runtime)** → non-sensitive config
- **K8s Secret (runtime)** → sensitive config
- **ESO (runtime)** → fetches from Secrets Manager automatically

## DB Password Flow
```
Admin → Secrets Manager → ESO → K8s Secret → Pod env var → Spring Boot → RDS
```

## Scan Image for Secrets
```bash
trivy image cart:latest --security-checks secret
```

---

# SECTION 15 — Multi-Region / Hub-Spoke

## Key Points to Remember
- Hub = central management (ArgoCD, monitoring, secrets)
- Spoke = regional workloads only
- DynamoDB Global Tables = active-active (all regions read+write)
- RDS Cross-Region = active-passive (only primary writes)
- Route53 Latency Routing = routes to fastest region
- CloudFront = CDN for static content (no new cluster needed)

## Hub Manages
- ArgoCD (deploys to all spokes)
- ECR images
- KMS keys
- Secrets Manager
- Grafana (central monitoring)

## Spoke Runs
- Application pods
- Regional DynamoDB
- Regional RDS replica

## Route53 Latency Routing
- Same domain → different regions
- Routes based on network speed
- Health checks → failover if region down
- NOT geolocation (that's based on country)

---

# SECTION 16 — RBAC for Users

## Key Points to Remember
- Two groups: IAM Group (AWS) + K8s Group (Kubernetes)
- EKS Access Entry = bridge between IAM and K8s
- K8s Group is NOT a real object — just a string in token
- IAM Policy controls AWS access (eks:DescribeCluster)
- K8s Role/RoleBinding controls kubectl access
- SSM Parameter Store stores user lists (free tier)

## Flow
```
IAM User → EKS Access Entry → K8s Group → RoleBinding → Role → Permissions
```

## Three Teams
- **Developer** → get/list/watch pods/logs (retail-store ns only)
- **DevOps** → full app management + exec (retail-store ns only)
- **SRE** → read all + exec (all namespaces)

---

# SECTION 17 — StatefulSet and Database HA

## Key Points to Remember
- StatefulSet = fixed pod names (postgres-0, postgres-1, postgres-2)
- volumeClaimTemplates = auto-creates PVC per pod
- PVC naming: `<template-name>-<pod-name>`
- Patroni manages PostgreSQL failover
- WAL = Write Ahead Log (diary of all changes)
- WAL used for: crash recovery, replication, point-in-time recovery
- Primary fails → Patroni promotes replica → old primary becomes replica

## PVC Auto-Creation
```
StatefulSet replicas: 3
→ postgres-data-postgres-0 (PVC auto-created)
→ postgres-data-postgres-1 (PVC auto-created)
→ postgres-data-postgres-2 (PVC auto-created)
```

## Failure Scenarios
- Pod restarts → same PVC reattached → data safe ✅
- Primary fails → Patroni promotes replica → no data loss ✅
- Cluster deleted → data in RDS/DynamoDB safe ✅ (outside cluster)

---

# ═══════════════════════════════════════════════════════
# CHEAT SHEET — Quick Reference
# ═══════════════════════════════════════════════════════

## ArgoCD HA — Quick Reference
```
Components × 3:  server, app-controller, repo-server
Redis:           HA mode (1 master + 2 slaves + 3 sentinels)
PDB:             minAvailable: 2
Sharding:        app-controller splits apps across replicas
Install:         helm install argocd argo/argo-cd --values values-ha.yaml
```

## SSO — Quick Reference
```
GitLab:  type: gitlab, baseURL: https://gitlab.com
Okta:    type: oidc, issuer: https://company.okta.com
Groups:  must configure groups claim in Okta/GitLab
Disable admin: admin.enabled: "false" (after SSO works)
Scopes:  "[groups]" in argocd-rbac-cm
```

## RBAC — Quick Reference
```
Default:    policy.default: role:readonly
Policy:     p, role:developer, applications, sync, */*, allow
Group map:  g, argocd-developers, role:developer
Resources:  applications, clusters, logs, exec, repositories
Actions:    get, create, update, delete, sync, override
```

## Notifications — Quick Reference
```
Trigger  → WHEN (on-deployed, on-sync-failed, on-health-degraded)
Template → WHAT (message format)
Service  → WHERE (Slack, Email, Teams)
Subscribe: notifications.argoproj.io/subscribe.on-deployed.slack: channel
```

## DR — Quick Reference
```
Git:             RPO=0, RTO=30min, app definitions
Secrets Manager: argocd-secret, OAuth credentials
Velero:          cluster credentials, full namespace backup
Velero schedule: "0 2 * * *" (daily 2am), TTL 720h (30 days)
Restore:         velero restore create --from-backup argocd-backup
```

## App of Apps — Quick Reference
```
Root app watches: argocd/applications/ folder
Add service:      add yaml to folder + git push
Remove service:   remove yaml from folder + git push
DR:               kubectl apply -f argocd/root-app.yaml
Best for:         different services, single cluster
```

## ApplicationSet — Quick Reference
```
Generators:  List, Cluster, Git, Matrix
List:        explicit cluster list
Cluster:     auto-discovers by label
Git:         auto-discovers folders
Matrix:      combine generators (5 services × 3 clusters = 15 apps)
Best for:    same service, multiple clusters
```

## Sync Windows — Quick Reference
```
Allow:  can deploy during this time
Deny:   cannot deploy during this time
Cron:   "0 9 * * 1-5" = 9am Mon-Fri
Manual: manualSync: true = emergency override allowed
Check:  argocd proj windows list retail-store
```

## ESO vs CSI — Quick Reference
```
CSI:  volume mount → fetches at pod startup → file or env var
ESO:  ExternalSecret → fetches before pod → env var only
ESO wins: simpler, auto-rotate, secret exists before pod
CSI wins: file-based secrets (TLS certs, SSH keys)
```

## Workload Identity — Quick Reference
```
EKS:  eks.amazonaws.com/role-arn → AWS IAM Role → Secrets Manager
GKE:  iam.gke.io/gcp-service-account → GCP SA → Secret Manager
AKS:  azure.workload.identity/client-id → Managed Identity → Key Vault
All:  K8s SA token → Cloud IAM → Secret Store (no static credentials)
```

## Helm Rationalisation — Quick Reference
```
Audit:    helm list -A --output json
Standard: same values.yaml keys for all charts
Library:  shared templates, no duplication
Registry: OCI registry (ECR) for all charts
Renovate: auto PRs for version updates
Versions: pin exact (1.2.2), never latest/~1.2/^1
```

## Docker Secrets — Quick Reference
```
Build time: code + dependencies ONLY (no secrets)
Runtime:    K8s Secret / ConfigMap / ESO
Flow:       Secrets Manager → ESO → K8s Secret → env var → app
Scan:       trivy image cart:latest --security-checks secret
Never:      --build-arg with secrets, COPY .env, ENV PASSWORD=xxx
```

## Multi-Region — Quick Reference
```
CloudFront:  CDN, no new cluster, static content fast
Route53:     latency routing, same domain, fastest region
DynamoDB:    Global Tables, active-active, all regions write
RDS:         Cross-region replica, active-passive, primary writes
Hub-Spoke:   hub=management, spoke=workloads
```

## RBAC Users — Quick Reference
```
IAM Group:       AWS access (eks:DescribeCluster)
K8s Group:       kubectl access (string in token)
EKS Access Entry: bridge (IAM → K8s group)
SSM:             stores user lists (free tier)
Add user:        update SSM → terraform apply
Remove user:     update SSM → terraform apply
```

## WAL — Quick Reference
```
WAL = Write Ahead Log = diary of all DB changes
Uses: crash recovery, streaming replication, PITR
Patroni: uses WAL to sync new primary with replicas
PITR: restore to any second in last 35 days
pg_rewind: fast sync using WAL differences
```

## Key Commands — Quick Reference
```bash
# ArgoCD
argocd app sync <app>
argocd app rollback <app> <revision>
argocd app history <app>
argocd proj windows list <project>
argocd cluster list
argocd admin settings rbac can role:developer applications sync */\*

# Velero
velero backup get
velero restore create --from-backup <backup-name>
velero schedule create argocd-backup --schedule="0 2 * * *"

# ESO
kubectl get externalsecret -n retail-store
kubectl describe externalsecret cart-secrets -n retail-store

# Helm
helm list -A --output json
helm lint src/cart/chart
helm template src/cart/chart | grep apiVersion

# Secrets
aws secretsmanager get-secret-value --secret-id retail-store/cart
aws ssm get-parameter --name "/retail-store/rbac/developer_users" --with-decryption
```

## Interview One-Liners — Quick Reference
```
ArgoCD HA:        3 replicas each + Redis Sentinel + PDB
SSO:              Dex broker → GitLab/Okta → groups → RBAC roles
RBAC:             p, role, resource, action, object, allow/deny
Notifications:    trigger(when) + template(what) + service(where)
DR:               Git=config, SecretsManager=secrets, Velero=cluster-creds
App of Apps:      root-app watches folder → creates all apps
ApplicationSet:   one template → many apps (multi-cluster)
Sync Windows:     allow/deny + cron schedule + manualSync override
ESO:              ExternalSecret → K8s Secret before pod starts
CSI Driver:       volume mount → secret at pod startup
Workload Identity: K8s SA token → Cloud IAM → no static credentials
Helm Rational:    standardise + pin versions + library chart + Renovate
Docker secrets:   NEVER in image → inject at runtime via K8s
WAL:              diary of DB changes → replication + crash recovery
Hub-Spoke:        hub=ArgoCD+monitoring, spoke=app workloads
```
