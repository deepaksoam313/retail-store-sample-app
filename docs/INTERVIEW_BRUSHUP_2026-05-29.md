# Senior DevOps Interview — Complete Brush Up Guide
## Date: 2026-05-29 | Interview Tomorrow

---

# ═══════════════════════════════════════════════
# SECTION 1 — YOUR PROJECT (Most Important)
# ═══════════════════════════════════════════════

## Project Overview
```
Retail Store Sample App — Microservices on AWS EKS
  UI       (Java)   → frontend
  Catalog  (Go)     → product catalog API
  Cart     (Java)   → shopping cart → DynamoDB
  Orders   (Java)   → order management → MySQL (in-memory currently)
  Checkout (Node)   → checkout orchestration

Infrastructure:
  EKS Auto Mode (ap-south-1) → 3 AZs
  ArgoCD → GitOps deployments
  GitHub Actions → CI/CD
  Terraform → Infrastructure as Code
  NGINX Ingress + NLB → traffic routing
  cert-manager → SSL (Let's Encrypt)
  ESO → secrets from Secrets Manager
  Prometheus + Grafana → monitoring
```

## CI/CD Flow
```
Developer pushes code (src/ directory)
        ↓
GitHub Actions triggers
  → docker build → push to ECR (commit hash tag)
  → updates image tag in values.yaml
  → commits back to Git
        ↓
ArgoCD detects values.yaml change
        ↓
ArgoCD syncs → kubectl apply → rolling update on EKS
        ↓
Health check passes → deployment complete

Rollback = revert commit in Git → ArgoCD auto-syncs old image
```

## AZ Distribution
```
locals.tf:
  azs = slice(data.aws_availability_zones.available.names, 0, 3)
  → ap-south-1a, ap-south-1b, ap-south-1c

  private_subnets = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 8, k + 10)]
  → one subnet per AZ

EKS subnet_ids = all 3 private subnets
→ Auto Mode provisions nodes across all 3 AZs

Cart service:
  topologySpreadConstraints:
    maxSkew: 1
    topologyKey: topology.kubernetes.io/zone
  → forces pods into different AZs ✅

UI service:
  replicaCount: 1, no topologySpread → NOT prod grade ❌
```

---

# ═══════════════════════════════════════════════
# SECTION 2 — CI/CD INTERVIEW QUESTIONS
# ═══════════════════════════════════════════════

## Q: Explain your CI/CD pipeline
```
GitHub Actions (CI):
  trigger: push to src/ on production branch
  steps:
    1. checkout code
    2. login to ECR (OIDC — no long-lived keys)
    3. docker build --tag <ecr-url>:<commit-hash>
    4. trivy scan (fail if CRITICAL CVE found)
    5. docker push to ECR
    6. update values.yaml with new tag
    7. git commit + push

ArgoCD (CD):
  watches Git repo
  detects values.yaml change
  syncs to EKS cluster
  rolling update → zero downtime
```

## Q: How do you rollback?
```
Method 1 (preferred): git revert <bad-commit> → push → ArgoCD auto-deploys old version
Method 2: ArgoCD UI → History and Rollback → click previous revision
Method 3: argocd app rollback <app> <revision>
```

## Q: How do you handle secrets in CI/CD?
```
GitHub Actions uses OIDC role (no AWS access keys stored)
  → assumes IAM role via OIDC trust
  → gets temporary credentials

App secrets:
  stored in AWS Secrets Manager
  ESO fetches → creates K8s Secret
  pod reads env vars from K8s Secret
  NEVER in Dockerfile, NEVER in Git
```

---

# ═══════════════════════════════════════════════
# SECTION 3 — DOCKER
# ═══════════════════════════════════════════════

## COPY vs ADD
```
COPY = only copies local files/dirs → always use this
ADD  = COPY + auto-extracts tar + can fetch URLs → avoid unless needed
```

## ENTRYPOINT vs CMD
```
CMD         = default args, fully replaceable at runtime
ENTRYPOINT  = fixed executable, not replaceable (only appended to)

Together (prod standard):
  ENTRYPOINT ["java", "-jar", "app.jar"]   ← fixed
  CMD ["--spring.profiles.active=default"] ← replaceable default

docker run myimage --spring.profiles.active=prod
→ runs: java -jar app.jar --spring.profiles.active=prod ✅
```

## Multistage Dockerfile
```dockerfile
# Stage 1 — BUILD (thrown away)
FROM maven:3.9-eclipse-temurin-21 AS builder
WORKDIR /app
COPY pom.xml .
RUN mvn dependency:go-offline
COPY src/ ./src/
RUN mvn clean package -DskipTests

# Stage 2 — RUNTIME (final image)
FROM eclipse-temurin:21-jre-alpine
RUN addgroup -S appgroup && adduser -S appuser -G appgroup
USER appuser
COPY --from=builder /app/target/app.jar app.jar
ENTRYPOINT ["java", "-jar", "app.jar"]
```
```
Result: 800MB → 150MB
  No build tools in prod image
  No source code in prod image
  Non-root user ✅
```

## Docker Best Practices
```
✅ multistage builds (small image)
✅ non-root user (security)
✅ exec form CMD/ENTRYPOINT (proper signal handling)
✅ .dockerignore (fast builds)
✅ combine RUN commands (fewer layers)
✅ COPY before RUN (cache efficiency)
✅ pin exact base image versions
✅ scan with Trivy in CI/CD
❌ never secrets in Dockerfile
❌ never ENV PASSWORD=xxx
❌ never latest tag
```

## Signal Handling (SIGTERM vs SIGKILL)
```
SIGTERM = graceful shutdown (sent first, 30s grace period)
SIGKILL = force kill (sent after grace period, cannot catch)

Shell form: /bin/sh is PID 1 → SIGTERM goes to shell, not app ❌
Exec form:  app is PID 1 → SIGTERM goes directly to app ✅
```

---

# ═══════════════════════════════════════════════
# SECTION 4 — KUBERNETES
# ═══════════════════════════════════════════════

## Deployment Strategies
```
Recreate      → kill all → deploy new (downtime ❌, dev only)
Rolling Update → replace pods one by one (default, zero downtime ✅)
Blue/Green    → run both → switch traffic (zero downtime, safe ✅)
Canary        → 5% → 10% → 100% gradually (safest ✅)
A/B Testing   → split by user segment (feature testing)
```

## Rolling Update Config
```yaml
strategy:
  type: RollingUpdate
  rollingUpdate:
    maxUnavailable: 0   # never kill old pod before new is ready
    maxSurge: 1         # one extra pod during update
```

## Service Types
```
ClusterIP    = internal only (default, service-to-service)
NodePort     = exposed on node IP (testing only)
LoadBalancer = external AWS LB created
ExternalName = maps to external DNS (e.g., RDS endpoint)
```

## How Services Load Balance Pods
```
Service (ClusterIP) → kube-proxy iptables rules
  → random equal probability (round robin)
  → runs in kernel space, extremely fast

Two levels:
  Level 1: NLB/ALB → EC2 nodes (AWS load balancing)
  Level 2: kube-proxy iptables → pods (K8s load balancing)
```

## PodDisruptionBudget
```yaml
spec:
  minAvailable: 2      # always keep 2 pods running
  selector:
    matchLabels:
      app: cart        # applies ONLY to pods with this label
```
```
During node drain/upgrade:
  K8s checks PDB before evicting pod
  if eviction violates PDB → waits until new pod is ready
  → zero downtime during upgrades ✅
```

## topologySpreadConstraints
```yaml
topologySpreadConstraints:
- maxSkew: 1
  topologyKey: topology.kubernetes.io/zone
  whenUnsatisfiable: DoNotSchedule
  labelSelector:
    matchLabels:
      app: cart
```
```
maxSkew: 1 = max difference between AZs is 1 pod
→ AZ-a: 1 pod, AZ-b: 1 pod, AZ-c: 1 pod ✅
→ AZ-a goes down = 2 pods still serving ✅
```

## PV vs PVC
```
PV  = cluster-scoped, actual storage (EBS volume), created by admin/StorageClass
PVC = namespace-scoped, request for storage, created by app team

StorageClass (dynamic provisioning):
  PVC created → StorageClass auto-creates PV + EBS volume
  no manual admin step needed ✅

reclaimPolicy:
  Retain → PV stays when PVC deleted (use for databases)
  Delete → PV deleted when PVC deleted (use for temp storage)
```

## EBS vs EFS
```
EBS:
  block storage, one pod at a time (ReadWriteOnce)
  AZ-locked (volume and pod must be in same AZ)
  fast (low latency)
  use for: databases (MySQL, PostgreSQL)
  cost: $0.08/GB/month

EFS:
  shared file system, many pods simultaneously (ReadWriteMany)
  regional (spans all AZs)
  slower (network file system)
  use for: shared images, ML datasets, shared config
  cost: $0.30/GB/month (4x EBS)
```

## Namespace Isolation
```
Services are namespace-scoped
Same namespace:  curl http://orders:8080 ✅
Cross namespace: curl http://orders.team-orders.svc.cluster.local:8080 ✅

DNS format: <service>.<namespace>.svc.cluster.local

Isolation:
  ResourceQuota  → limits CPU/memory per namespace
  RBAC           → team sees only their namespace
  NetworkPolicy  → pods cannot talk cross-namespace by default
```

## StatefulSet vs Deployment
```
Deployment:
  pods get random names (app-abc123)
  no stable identity
  all pods share same PVC (or no PVC)
  use for: stateless apps

StatefulSet:
  pods get fixed names (mysql-0, mysql-1, mysql-2)
  stable network identity
  each pod gets own PVC (volumeClaimTemplates)
  use for: databases, Kafka, Elasticsearch
```

## EKS Cluster Upgrade Process
```
Rule: never skip minor versions (1.34 → 1.35 ✅, 1.34 → 1.36 ❌)
Order: control plane FIRST, then node groups

Control plane (AWS managed):
  aws eks update-cluster-version --kubernetes-version 1.35
  takes 8-12 minutes, zero downtime

Node group (rolling):
  aws eks update-nodegroup-version --kubernetes-version 1.35
  AWS: launches new node → cordons old → drains → terminates → repeats

Manual (one by one):
  kubectl cordon <node>   → stop new pods scheduling
  kubectl drain <node>    → move existing pods away
  terminate EC2           → ASG launches new node (must update AMI first)
  kubectl uncordon <node> → allow scheduling (if needed)

Zero downtime requirements:
  minReplicas >= 2
  PodDisruptionBudget configured
  topologySpreadConstraints configured
```

---

# ═══════════════════════════════════════════════
# SECTION 5 — NETWORKING
# ═══════════════════════════════════════════════

## NLB vs ALB
```
NLB = Layer 4 (TCP/UDP)
  only sees IP + Port
  ultra fast, static IP
  cannot: read HTTP, WAF, Cognito auth, path routing
  use for: TCP passthrough to NGINX, non-HTTP protocols

ALB = Layer 7 (HTTP/HTTPS)
  reads full HTTP request
  path/host routing, WAF, Cognito/Okta auth, SSL termination
  cannot: URL rewriting, rate limiting, custom error pages
  use for: HTTP routing, security at edge
```

## Three Architecture Patterns
```
Pattern 1 — NLB + NGINX (your project):
  Internet → NLB (TCP) → NGINX (SSL + routing) → pods
  cheap (one NLB), flexible, cloud agnostic

Pattern 2 — ALB only:
  Internet → ALB → pods directly
  simple, WAF+Cognito, but expensive at scale

Pattern 3 — ALB + NGINX (enterprise):
  Internet → ALB (WAF + Auth) → NGINX (routing) → pods
  best security + flexibility, more cost + latency
```

## SSL Termination
```
= decrypt HTTPS, forward plain HTTP internally

Option 1: At ALB → ACM cert, AWS managed, zero ops
Option 2: At NGINX (your project) → cert-manager + Let's Encrypt
Option 3: End-to-end TLS → ALB + NGINX both decrypt (banking/compliance)
```

## Route53
```
Global AWS DNS service, sits OUTSIDE your VPC

Routing policies:
  Simple      → one domain → one IP (basic)
  Weighted    → 90% v1, 10% v2 (canary)
  Latency     → route to fastest region (performance)
  Geolocation → route by country (compliance/data residency)
  Failover    → primary → secondary on health check fail (DR)
  Multivalue  → multiple IPs with health checks
  IP-Based    → route by client IP/CIDR

Route53 vs CoreDNS:
  Route53  = external DNS (internet → cluster), outside VPC
  CoreDNS  = internal DNS (inside cluster), pod-to-pod
```

## Network Policies — Zero Trust
```
Default: all pods can talk to all pods ❌
With NetworkPolicy: explicit allow only ✅

# only orders pod can reach orders-db
spec:
  podSelector:
    matchLabels:
      app: orders-db
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: orders
```

---

# ═══════════════════════════════════════════════
# SECTION 6 — SECRETS MANAGEMENT (ESO)
# ═══════════════════════════════════════════════

## ESO Flow (Hands-On Today)
```
AWS Secrets Manager (eso-test/nginx)
        ↓
OIDC Provider (trust between EKS + AWS IAM)
        ↓
IAM Policy + IRSA (ESO service account gets permissions)
        ↓
ESO installed (3 pods: controller, webhook, cert-controller)
        ↓
ClusterSecretStore (connects ESO → AWS, STATUS: Valid)
        ↓
ExternalSecret (fetches secret → creates K8s Secret)
        ↓
K8s Secret "nginx-secret" auto-created
        ↓
Nginx pod reads env vars from K8s Secret ✅
```

## Key Resources
```
ClusterSecretStore = HOW to connect (cluster-wide)
SecretStore        = HOW to connect (namespace-scoped)
ExternalSecret     = WHAT to fetch + WHERE to store
```

## Secret Rotation
```
ESO updates K8s secret automatically (refreshInterval: 1h)
BUT env vars injected at pod START time
→ pod must restart to pick up new values

3 ways:
  Manual:   kubectl rollout restart deployment
  Reloader: auto-restarts pod when secret changes ✅ (prod standard)
  Volume:   mount as file → updates live, no restart needed
```

## ESO vs CSI Driver
```
ESO:
  creates K8s secret before pod starts ✅
  simple env vars ✅
  auto-refreshes ✅
  secret exists without pod running ✅

CSI Driver:
  fetches at pod startup (volume mount)
  better for file-based secrets (TLS certs, SSH keys)
  secret only exists when pod runs
```

## IRSA (How ESO Authenticates to AWS)
```
No hardcoded credentials anywhere

Flow:
  ESO pod uses K8s service account token
    ↓
  sends token to AWS STS
    ↓
  AWS validates via OIDC provider
    ↓
  issues temporary credentials (15min, auto-renewed)
    ↓
  ESO calls Secrets Manager with temp credentials ✅
```

---

# ═══════════════════════════════════════════════
# SECTION 7 — STORAGE
# ═══════════════════════════════════════════════

## Database HA Options
```
Option 1 — RDS Multi-AZ (recommended):
  primary (AZ-a) → standby (AZ-b, auto-failover 60s)
  AWS manages replication, failover, backups
  zero ops overhead ✅

Option 2 — StatefulSet + EBS per pod:
  mysql-0 (AZ-a) → EBS-1 → PRIMARY (read+write)
  mysql-1 (AZ-b) → EBS-2 → REPLICA (read only, super_read_only=ON)
  mysql-2 (AZ-c) → EBS-3 → REPLICA (read only)

  Two K8s services:
    mysql-primary → mysql-0 (writes)
    mysql-replica → mysql-1, mysql-2 (reads)

  MySQL replication:
    primary writes → binlog → replicas apply changes ✅
```

## Why EFS for Shared Content (UI)
```
UI pods (3 replicas) → all need same product images
EFS mounted by all 3 pods simultaneously (ReadWriteMany)

No conflict because:
  different pods write DIFFERENT files ✅
  not same row like MySQL ✅
  last write wins (acceptable for files)

Conflict edge case:
  pod writes file → uses temp file + atomic rename
  → other pods always read complete file ✅
```

---

# ═══════════════════════════════════════════════
# SECTION 8 — ARGOCD
# ═══════════════════════════════════════════════

## ArgoCD RBAC + Okta
```
Flow:
  User → ArgoCD UI → DEX → Okta → JWT with groups
  ArgoCD maps groups → roles → permissions

argocd-cm (DEX config):
  connectors:
  - type: oidc
    config:
      issuer: https://yourcompany.okta.com
      clientID: $dex.okta.clientID
      insecureEnableGroups: true

argocd-rbac-cm (policy):
  policy.csv: |
    p, role:developer, applications, sync, */*, allow
    g, argocd-developers, role:developer
  policy.default: role:readonly
  scopes: "[groups, email]"
```

## App of Apps
```
ONE root app watches argocd/applications/ folder
→ creates all other apps automatically
→ add service: add yaml to folder + push
→ DR: kubectl apply -f root-app.yaml → everything back ✅
```

## ArgoCD Rollback
```
Method 1 (GitOps): git revert → push → auto-deploys ✅
Method 2 (UI): History and Rollback → click revision
Method 3 (CLI): argocd app rollback <app> <revision>
```

## Sync Waves (CRD ordering)
```
annotations:
  argocd.argoproj.io/sync-wave: "1"  ← deploy first
  argocd.argoproj.io/sync-wave: "2"  ← deploy second
  argocd.argoproj.io/sync-wave: "3"  ← deploy third

Use case: cert-manager CRDs (wave 1) before ClusterIssuer (wave 2)
```

---

# ═══════════════════════════════════════════════
# SECTION 9 — SERVICE MESH
# ═══════════════════════════════════════════════

## mTLS
```
TLS  = server proves identity to client (one-way)
mTLS = both client AND server prove identity (mutual)

Without mTLS: rogue-pod → orders ✅ (no verification)
With mTLS:    rogue-pod → orders ❌ (no valid cert)
              cart-pod  → orders ✅ (valid cert)
```

## North-South vs East-West
```
North-South = external traffic → cluster
  handled by: NGINX Ingress / ALB

East-West = service to service INSIDE cluster
  handled by: Service Mesh (Istio/Linkerd)
```

## When to Use Service Mesh
```
Need it:
  → 10+ microservices
  → mTLS requirement (zero trust)
  → circuit breaking (prevent cascade failures)
  → per-service observability
  → PCI-DSS / HIPAA compliance

Don't need it:
  → < 10 services
  → small team
  → simple communication
```

---

# ═══════════════════════════════════════════════
# SECTION 10 — LINUX & GENERAL DEVOPS
# ═══════════════════════════════════════════════

## Extend Volume in Linux
```bash
# EBS extend from AWS console first, then:
growpart /dev/xvda 1        # extend partition
resize2fs /dev/xvda1        # ext4
xfs_growfs /                # xfs (Amazon Linux)

# K8s: allowVolumeExpansion: true in StorageClass
# → edit PVC size → EBS auto-extends
```

## Load Average in `top`
```
load average: 1.23, 0.98, 0.75
               1min  5min  15min

= number of processes waiting for CPU
Compare to CPU cores (nproc):
  load = cores    → 100% utilized, at capacity
  load > cores    → overloaded, processes queuing
  load = 2×cores  → alert! ❌
```

## Get Running Ports
```bash
ss -tlnp              # modern, preferred
netstat -tlnp         # older systems
lsof -i :8080         # which process owns port
kubectl get svc -A    # K8s services
```

## Connection Between Two Ports
```bash
nc -zv 10.0.1.5 5432             # test connection
ssh -L 5432:rds:5432 bastion     # SSH tunnel
kubectl port-forward pod/db 5432  # K8s port forward
```

## Ansible — 20 Servers
```
ansible-playbook = idempotent (run 10 times = same result)
  → drift detection: if someone changes config manually
  → Ansible corrects it on next run ✅

Ensure state:
  → AWX/Tower runs playbook every 30 mins
  → ansible --check for dry run
  → handlers restart services only when config changes

Verify: ansible webservers -m command -a "systemctl status nginx"
```

## OS Patching
```bash
# Security patches only
yum update --security -y        # RHEL/Amazon Linux
apt-get upgrade --only-upgrade  # Ubuntu

# Prod: AWS Systems Manager Patch Manager
  → patch baseline (which CVEs)
  → maintenance window (Sunday 2am)
  → patch groups (dev first, then prod)
  → auto-reboot + compliance report
```

---

# ═══════════════════════════════════════════════
# SECTION 11 — HELM
# ═══════════════════════════════════════════════

## What is Helm
```
Package manager for Kubernetes
  Chart   = package of K8s manifests (recipe)
  Values  = environment config (ingredients)
  Release = deployed instance

helm install retail-store ./chart
helm upgrade retail-store ./chart
helm rollback retail-store 1
helm list -A
```

## Your Project
```
Each microservice has own Helm chart (src/<service>/chart/)
ArgoCD deploys via Helm with environment-specific values.yaml
GitHub Actions updates image tag in values.yaml → GitOps loop
```

---

# ═══════════════════════════════════════════════
# SECTION 12 — DR & LARGE SCALE CHALLENGES
# ═══════════════════════════════════════════════

## Anaplan UAE Outage — Why 7-8 Days
```
Day 1-2: wait and assess (temporary or permanent?)
Day 2-3: legal review (data residency — UAE data → another region?)
Day 3-4: spin up DR cluster + restore terabytes of data
Day 4-5: deploy all services in correct dependency order
Day 5-6: verify every customer model (financial data = must be exact)
Day 6-7: DNS cutover (48hr global propagation)
Day 7-8: full access restored

Root cause of long RTO:
  → cold standby (no pre-existing DR cluster)
  → data residency legal approval not pre-done
  → DR never fully tested at this scale
```

## Active-Passive vs Active-Active
```
Active-Passive:
  primary handles all traffic
  standby receives data replication
  failover = DNS switch = minutes (if warm) or days (if cold)
  simpler, cheaper

Active-Active:
  both regions handle traffic simultaneously
  instant failover (already running)
  complex data consistency
  2x cost
  good for: stateless apps, read-heavy workloads
  bad for: complex stateful apps (Anaplan models)
```

## Real Enterprise DevOps Challenges
```
1. Cost optimization
   → VPA right-sizing, Karpenter, schedule non-prod shutdown
   → $500K/month → $280K with right-sizing

2. Deployment velocity
   → OPA/Gatekeeper enforce resource limits
   → canary deployments (5% → 100%)
   → reduce failures: 15/day → 2/day

3. Observability at scale
   → RED metrics (Rate, Errors, Duration) per service
   → distributed tracing (find which service is slow)
   → MTTD: 30min → 2min, MTTR: 2hr → 8min

4. Security + compliance
   → Trivy scan in CI/CD (block CRITICAL CVEs)
   → NetworkPolicies (zero trust)
   → ESO + Secrets Manager (no hardcoded creds)
   → SOC2/PCI-DSS audit readiness

5. Multi-team access control
   → namespace per team
   → ArgoCD Projects (team deploys only to their namespace)
   → prod access = break-glass (auto-expires 4 hours)
```

## Database Connection Pool Exhausted
```
Problem:
  20 connections in pool
  slow query holds connection for 8 seconds
  21st request waits 30s → timeout → 503 error
  checkout → orders slow → entire app appears down

Debug:
  Grafana → p99 latency spike
  distributed trace → orders → DB = 7.9s
  DB slow query log → full table scan (no index)

Fix (immediate):
  CREATE INDEX idx_orders_customer_id ON orders(customer_id)
  query: 7823ms → 2ms ✅

Fix (permanent):
  increase pool size
  add circuit breaker (stop calling slow service)
```

---

# ═══════════════════════════════════════════════
# CHEAT SHEET — QUICK FIRE ANSWERS
# ═══════════════════════════════════════════════

```
Q: Difference ALB vs NLB?
A: ALB=L7 reads HTTP (routing/WAF/auth), NLB=L4 TCP only (fast/static IP)

Q: Why NLB + NGINX together?
A: NLB=AWS entry point (TCP passthrough), NGINX=L7 routing inside cluster, one NLB for all services = cheap

Q: Why need ALB for Okta?
A: Okta needs HTTP-level ops (redirect, JWT validation) — NLB never reads HTTP packet ❌

Q: What is SSL termination?
A: Decrypt HTTPS at LB/NGINX, forward plain HTTP internally. Your project: NGINX + cert-manager

Q: What is mTLS?
A: Both client AND server verify certificates. Used inside cluster (service mesh) for zero trust

Q: PV vs PVC?
A: PV=cluster-scoped actual storage, PVC=namespace-scoped request for storage

Q: EBS vs EFS?
A: EBS=one pod, one AZ, fast, databases. EFS=many pods, all AZs, shared files

Q: Why pod restart needed after secret rotation?
A: Env vars injected at pod START, K8s secret update doesn't refresh running pod

Q: What is IRSA?
A: IAM Role for Service Account — K8s SA token → AWS STS → temp credentials. No hardcoded keys

Q: Deployment vs StatefulSet?
A: Deployment=stateless (random pod names), StatefulSet=stateful (fixed names + own PVC per pod)

Q: What is PDB?
A: PodDisruptionBudget — ensures minimum pods always running during drain/upgrade

Q: What is topologySpreadConstraints?
A: Forces pods to spread across AZs. maxSkew:1 = max 1 pod difference between zones

Q: How does kube-proxy load balance?
A: iptables rules, random equal probability (round robin) across pod IPs

Q: What is ClusterSecretStore vs SecretStore?
A: ClusterSecretStore=cluster-wide (all namespaces), SecretStore=namespace-scoped

Q: App of Apps vs ApplicationSet?
A: App of Apps=different services single cluster, ApplicationSet=same service multiple clusters

Q: How does ArgoCD rollback work?
A: git revert (preferred) or argocd app rollback <app> <revision>

Q: What is load average in top?
A: Processes waiting for CPU over 1/5/15 min. Alert if > number of CPU cores

Q: SIGTERM vs SIGKILL?
A: SIGTERM=graceful (app gets 30s to finish), SIGKILL=force immediate (cannot catch)

Q: What is multistage Dockerfile?
A: Stage 1=build (maven), Stage 2=runtime (JRE only). Result: 800MB → 150MB, no build tools in prod

Q: Why non-root in Docker?
A: If container compromised, root=host escape ❌, non-root=limited damage ✅

Q: North-South vs East-West?
A: North-South=external→cluster (NGINX/ALB), East-West=service→service inside (service mesh)

Q: What is Descheduler?
A: Runs periodically, evicts unbalanced pods → scheduler places on better node. No restart needed

Q: Active-Active vs Active-Passive DR?
A: Active-Active=both regions live (instant failover, complex), Active-Passive=standby (simpler, RTO minutes-days)

Q: What is Route53 failover routing?
A: Primary endpoint health-checked every 30s. On failure → auto-switch to secondary. Used for DR

Q: What is OIDC in EKS?
A: Trust between EKS and AWS IAM. Allows pods to assume IAM roles without hardcoded credentials

Q: How to upgrade EKS zero downtime?
A: Upgrade control plane first. Then node group rolling (cordon→drain→terminate→new node joins). PDB + 2+ replicas required

Q: What is ExternalTrafficPolicy: Local?
A: Preserves client real IP. Without it, NLB IP seen by pod instead of user IP

Q: What is externalTrafficPolicy Local tradeoff?
A: Real client IP preserved ✅, but only nodes with pods receive traffic → slight imbalance

Q: What happens when you drain a node?
A: Moves all pods to other nodes. DaemonSets ignored. PDB respected. Node still running (just empty)

Q: Database connection pool exhausted — how to debug?
A: Grafana latency spike → distributed trace → slow DB query → check slow query log → missing index

Q: Why RDS over StatefulSet MySQL in prod?
A: RDS=AWS manages replication/failover/backups/scaling. StatefulSet=you manage everything. High ops overhead

Q: What is WAL in PostgreSQL?
A: Write Ahead Log = diary of all DB changes. Used for crash recovery, streaming replication, PITR
```

---

# ═══════════════════════════════════════════════
# KEY COMMANDS — QUICK REFERENCE
# ═══════════════════════════════════════════════

```bash
# Cluster
kubectl get nodes -o wide
kubectl get pods -A
kubectl top pods -A
kubectl top nodes

# Deployments
kubectl rollout restart deployment <name> -n <ns>
kubectl rollout status deployment <name> -n <ns>
kubectl scale deployment <name> --replicas=3 -n <ns>

# Debugging
kubectl describe pod <pod> -n <ns>
kubectl logs <pod> -n <ns> --previous
kubectl exec -it <pod> -n <ns> -- sh
kubectl get events -n <ns> --sort-by='.lastTimestamp'

# Services
kubectl get svc -A
kubectl get endpoints -n <ns>

# ESO
kubectl get clustersecretstore
kubectl get externalsecret -n <ns>
kubectl annotate externalsecret <name> -n <ns> force-sync=$(date +%s) --overwrite

# Node management
kubectl cordon <node>
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
kubectl uncordon <node>

# EKS
aws eks update-cluster-version --name <cluster> --kubernetes-version 1.35
aws eks update-nodegroup-version --cluster-name <cluster> --nodegroup-name <ng> --kubernetes-version 1.35
aws eks describe-cluster --name <cluster> --query "cluster.status"

# ArgoCD
argocd app sync <app>
argocd app rollback <app> <revision>
argocd app history <app>
argocd cluster list

# Helm
helm list -A
helm upgrade --install <release> ./chart -f values.yaml
helm rollback <release> 1
```

---

# ═══════════════════════════════════════════════
# INTERVIEW FORMULA
# ═══════════════════════════════════════════════

## For Every Answer
```
1. What it is (one line definition)
2. How it works (brief flow)
3. Why you used it in your project
4. What problem it solved
5. What would happen without it
```

## For Challenges
```
Situation  → what was the problem
Impact     → what was breaking / business impact
Action     → what you did to fix
Result     → what improved (measurable)
```

## Confidence Tips
```
✅ Say: "In our project we use X because Y"
✅ Say: "I debugged this using kubectl describe/logs"
✅ Say: "I added monitoring so we catch this early"
✅ Say: "The trade-off is X vs Y, we chose X because Z"

❌ Never: "I just googled it"
❌ Never: "I didn't face any challenges"
❌ Never: "I'm not sure but maybe..."
✅ Instead: "I don't have hands-on with X but conceptually it works like Y"
```

---

**Good luck tomorrow! You have built a prod-grade GitOps platform — own it confidently.**
