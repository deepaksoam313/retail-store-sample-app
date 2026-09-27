# ALB, NLB, Ingress Controller, SSL Termination & Service Mesh
## Date: 2026-05-29

---

## 1. OSI Layer — Foundation

```
Layer 7 (Application) = reads full HTTP request
  → headers, URL path, cookies, body
  → ALB, NGINX operate here

Layer 4 (Transport) = only sees IP + Port
  → does NOT read HTTP content
  → NLB operates here
```

---

## 2. NLB (Network Load Balancer)

### What it is
```
AWS managed Layer 4 load balancer
Only sees: IP address + Port number
Does NOT read HTTP headers, cookies, request body
Ultra fast — no packet inspection
```

### Properties
```
✅ Ultra low latency (microseconds)
✅ Static IP / Elastic IP support
✅ Handles TCP, UDP, TLS
✅ Scales to millions of requests/sec
✅ Preserves client source IP
❌ Cannot read HTTP headers
❌ Cannot do path/host based routing
❌ Cannot integrate with WAF
❌ Cannot do Cognito/Okta auth
❌ Cannot redirect HTTP → HTTPS
```

### When to Use
```
→ gaming servers (microsecond latency)
→ IoT (MQTT, custom TCP protocols)
→ financial trading systems
→ when client needs static IP (firewall whitelisting)
→ non-HTTP protocols
→ as TCP passthrough to NGINX (your project)
```

### Your Project
```
NLB created automatically when NGINX Ingress Controller
service type = LoadBalancer

NLB just forwards raw TCP to NGINX
NGINX does all L7 work
NLB = entry point into VPC only
```

---

## 3. ALB (Application Load Balancer)

### What it is
```
AWS managed Layer 7 load balancer
Reads full HTTP request
Smart routing based on content
```

### Properties
```
✅ Path-based routing  (/api → service A, / → service B)
✅ Host-based routing  (app.domain.com, api.domain.com)
✅ SSL termination (ACM managed certs, auto-renew)
✅ WAF integration (block SQL injection, XSS, DDoS)
✅ Cognito/Okta OIDC authentication
✅ Weighted routing (canary — 90/10 split)
✅ HTTP → HTTPS redirect
✅ gRPC support
✅ WebSocket support
❌ No static IP (DNS based)
❌ Higher latency than NLB (inspects packets)
❌ More expensive
❌ Cannot do URL rewriting
❌ Cannot do rate limiting
❌ Cannot do custom error pages
```

### When to Use
```
→ when you need WAF (security)
→ when you need Cognito/Okta auth at edge
→ simple path/host routing without NGINX
→ small number of services (cost acceptable)
→ deep AWS integration required
→ AWS Shield DDoS protection needed
```

---

## 4. ALB vs NLB Comparison

| Feature | ALB | NLB |
|---------|-----|-----|
| OSI Layer | 7 (Application) | 4 (Transport) |
| Protocols | HTTP, HTTPS, WebSocket, gRPC | TCP, UDP, TLS |
| Routing | Path, host, header, query | IP + Port only |
| SSL termination | Yes (ACM) | Pass-through |
| WAF | Yes | No |
| Cognito/Okta auth | Yes | No |
| Static IP | No | Yes |
| Latency | Higher | Ultra low |
| Price | Higher | Lower |
| URL rewriting | No | No |
| Rate limiting | No | No |

---

## 5. NGINX Ingress Controller

### What it is
```
L7 proxy running as pod INSIDE Kubernetes cluster
Reads Ingress resources → configures routing rules
Handles everything ALB cannot do
```

### What NGINX Can Do (ALB Cannot)
```
✅ URL rewriting      → /api/v1/users → /users
✅ Rate limiting      → 100 req/min per IP
✅ Custom error pages → branded 404, 503 pages
✅ Header manipulation → add/remove/modify headers
✅ Mirror traffic     → copy traffic to testing service
✅ mTLS between LB and pods
✅ Lua scripting      → custom logic at proxy level
✅ Cross-namespace routing
✅ Canary routing     → 10% to new version
✅ Cloud agnostic     → same config on AWS/GCP/Azure
```

### How It Works
```
Ingress resource (yaml) defines rules
  ↓
NGINX Ingress Controller reads rules
  ↓
configures NGINX proxy inside pod
  ↓
routes traffic to correct K8s service
```

### Your Project NGINX Config (values.yaml)
```yaml
ingress:
  className: "nginx"
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/proxy-body-size: "8m"
    nginx.ingress.kubernetes.io/proxy-connect-timeout: "30"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "600"
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
  tls:
  - secretName: tls-secret
    hosts:
    - retail-store.deepaksoam313.com
```

---

## 6. Can NGINX Work Without NLB/ALB?

```
On-premise / bare metal:
  User → directly hits NGINX pod IP (NodePort)
  No cloud LB needed ✅

On AWS EKS:
  NGINX pod runs inside PRIVATE subnet
  No public IP assigned to pods
  Internet CANNOT reach pods directly ❌

  You NEED something in PUBLIC subnet:
    → NLB (your project) — TCP passthrough
    → ALB — L7 routing + security
    → NodePort with EC2 public IP (not prod)

NLB/ALB = entry point from internet into VPC
NGINX = actual L7 router inside cluster
```

---

## 7. Three Architecture Patterns

### Pattern 1 — NLB + NGINX (Your Project)
```
Internet → NLB (TCP passthrough) → NGINX (SSL + routing) → pods

Pros:
  ✅ one NLB for ALL services (cheap)
  ✅ NGINX handles all L7 routing
  ✅ SSL via cert-manager (Let's Encrypt)
  ✅ rate limiting, URL rewriting
  ✅ cloud agnostic

Cons:
  ❌ no WAF
  ❌ no Cognito/Okta auth at edge
  ❌ no AWS Shield
```

### Pattern 2 — ALB Only (AWS LB Controller)
```
Internet → ALB → pods directly (target group)

Pros:
  ✅ WAF integration
  ✅ Cognito/Okta auth
  ✅ AWS managed SSL (ACM)
  ✅ simpler (no NGINX to manage)

Cons:
  ❌ one ALB per Ingress = expensive at scale
  ❌ no URL rewriting
  ❌ no rate limiting
  ❌ AWS specific (not portable)
```

### Pattern 3 — ALB + NGINX (Enterprise)
```
Internet → ALB (WAF + Auth + SSL) → NGINX (routing + rate limit) → pods

Pros:
  ✅ ALB handles security layer
  ✅ NGINX handles advanced routing
  ✅ best of both worlds

Cons:
  ❌ extra cost (ALB + NLB)
  ❌ extra latency (double hop)
  ❌ more complex
  Only justified when BOTH security + advanced routing needed
```

---

## 8. SSL Termination

### What it is
```
SSL termination = decrypt HTTPS traffic
                  forward as plain HTTP internally

Without SSL termination:
  User → HTTPS (encrypted) → all the way to pod
  every pod needs certificate
  every pod does crypto work ❌

With SSL termination:
  User → HTTPS → LB/NGINX decrypts here
               → HTTP (plain) → pods
  one place manages certs ✅
  pods never deal with certificates ✅
```

### Option 1 — Terminate at ALB (AWS managed)
```
HTTPS → ALB (decrypt, ACM cert) → HTTP → NGINX → pods

Pros:
  AWS manages cert renewal automatically
  zero ops overhead
Cons:
  traffic between ALB and NGINX = plain HTTP inside VPC
  (acceptable — VPC is private network)
```

### Option 2 — Terminate at NGINX (Your Project)
```
HTTPS → NLB (passthrough) → NGINX (decrypt, cert-manager cert) → HTTP → pods

Pros:
  cert-manager auto-renews via Let's Encrypt
  more control over SSL config
Cons:
  you manage certificates
```

### Option 3 — End-to-End TLS (Zero Trust)
```
HTTPS → ALB (decrypt+re-encrypt) → HTTPS → NGINX (decrypt+re-encrypt) → HTTPS → pods

Used in: banking, healthcare, PCI-DSS compliance
Reason:  encrypted everywhere, even inside VPC
Cons:    double crypto overhead, two certs to manage
```

### Your Project (Option 2)
```yaml
# cert-manager gets cert from Let's Encrypt
cert-manager.io/cluster-issuer: "letsencrypt-prod"

# NGINX terminates SSL
nginx.ingress.kubernetes.io/ssl-redirect: "true"
nginx.ingress.kubernetes.io/force-ssl-redirect: "true"

tls:
- secretName: tls-secret
  hosts:
  - retail-store.deepaksoam313.com
```

---

## 9. Okta Auth — Why ALB Needed (Not NLB)

```
Okta auth flow needs HTTP-level operations:
  → redirect user to Okta login page (HTTP 302)
  → receive token callback (HTTP GET with code param)
  → validate JWT token (read Authorization header)
  → set session cookie (write HTTP header)

NLB = Layer 4, only sees TCP
  → cannot read HTTP headers ❌
  → cannot redirect to Okta ❌
  → cannot validate JWT ❌

ALB = Layer 7, reads full HTTP request
  → can redirect to Okta ✅
  → can validate JWT ✅
  → can set headers ✅
```

### ALB + Okta Config
```yaml
annotations:
  alb.ingress.kubernetes.io/auth-type: oidc
  alb.ingress.kubernetes.io/auth-idp-oidc: |
    {
      "issuer": "https://yourcompany.okta.com",
      "authorizationEndpoint": "https://yourcompany.okta.com/oauth2/v1/authorize",
      "tokenEndpoint": "https://yourcompany.okta.com/oauth2/v1/token",
      "userInfoEndpoint": "https://yourcompany.okta.com/oauth2/v1/userinfo",
      "secretName": "okta-alb-secret"
    }
  alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:...
```

### With Okta — Replace NLB with ALB
```
Current (no Okta):
  User → NLB (TCP passthrough) → NGINX (SSL + routing) → pods

With Okta:
  User → ALB (Okta auth + SSL termination) → NGINX (routing only) → pods

ALB does:                    NGINX does:
─────────────────────        ──────────────────────
✅ SSL termination (ACM)     ✅ path/host routing
✅ Okta OIDC validation      ✅ rate limiting
✅ redirect to Okta login    ✅ URL rewriting
✅ inject user headers       ✅ canary routing
✅ WAF                       ✅ custom error pages
✅ DDoS protection           ❌ SSL (ALB handles)
❌ advanced routing          ❌ auth (ALB handles)
```

---

## 10. Load Balancing Across Pods — Two Levels

```
AWS definition: "distributing traffic across pool of resources"
  NLB/ALB pool = EC2 nodes
  They balance across NODES ✅

Pod level balancing = kube-proxy (iptables)
  balances across pods ✅

Two levels:
Level 1: NLB/ALB → EC2 nodes (AWS load balancing)
Level 2: kube-proxy iptables → pods (K8s load balancing)
```

### kube-proxy iptables (default)
```
Service ClusterIP: 10.96.45.23:80
  ↓
iptables rules on every node:
  33% → pod1 (10.0.10.5:8080)
  33% → pod2 (10.0.11.6:8080)
  33% → pod3 (10.0.12.7:8080)

Algorithm: random equal probability (effectively round robin)
Happens in kernel space — extremely fast
```

---

## 11. Service Mesh (Istio)

### What is North-South vs East-West Traffic
```
North-South = traffic coming IN from outside cluster
  Internet → NLB/ALB → NGINX → pods
  Handled by: NGINX Ingress / ALB

East-West = traffic between services INSIDE cluster
  cart → orders → checkout → payments
  Handled by: Service Mesh (Istio/Linkerd)
```

### What is a Service Mesh
```
Without service mesh:
  cart-service → orders-service
  → plain HTTP, no encryption
  → no visibility
  → no retry logic
  → if orders slow → cart just hangs

With service mesh (Istio):
  cart-service → [envoy sidecar] → [envoy sidecar] → orders-service
  → automatic mTLS (encrypted + verified)
  → automatic retries
  → circuit breaking
  → full traffic visibility
```

### Sidecar Proxy
```
Every pod gets Envoy sidecar injected automatically:

pod without mesh:          pod with mesh:
┌─────────────┐            ┌──────────────────────────┐
│   app       │            │  app  │  envoy sidecar   │
└─────────────┘            └──────────────────────────┘
                                      ↑
                           intercepts ALL traffic
                           in and out of pod
```

### What Service Mesh Provides
```
mTLS (mutual TLS):
  every service verifies every other service
  compromised pod cannot call other services ✅

Circuit Breaking:
  orders-service slow → circuit opens
  cart stops calling orders → returns cached response
  prevents cascade failures ✅

Retries:
  request fails → automatically retry 3 times
  app code does not need retry logic ✅

Observability:
  latency per service
  error rate per service
  full distributed traces
  which service is slow? → visible in Jaeger/Grafana ✅

Traffic splitting:
  10% traffic to new version (canary between services)
  not just at ingress level ✅
```

### mTLS Explained
```
Normal TLS (one-way):
  Client → "who are you?"
  Server → "I am orders-service, here is my cert" ✅
  Client → trusts server, sends request
  Server → never verifies who client is ❌

mTLS (mutual):
  Client → "who are you?"
  Server → "I am orders-service, here is my cert" ✅
  Server → "who are YOU?"
  Client → "I am cart-service, here is MY cert" ✅
  Server → verifies client cert → allows or denies

Without mTLS:
  rogue-pod → orders-service ✅ (orders has no idea who is calling)

With mTLS:
  rogue-pod → orders-service ❌ (no valid cert = rejected)
  cart-service → orders-service ✅ (valid cert = allowed)
```

### Where Service Mesh Sits
```
Internet
    ↓
NLB → NGINX (north-south — external to cluster)
    ↓
Service Mesh (east-west — service to service INSIDE cluster)
    ↓
cart ──mTLS──► orders ──mTLS──► checkout ──mTLS──► payments
  ↑                ↑                ↑
envoy proxy    envoy proxy      envoy proxy
(metrics,      (circuit break,  (retry logic,
 traces)        rate limit)      timeout)
```

### Do You Need Service Mesh?
```
You DON'T need it if:
  → small number of services (< 10)
  → simple communication patterns
  → no strict compliance requirements
  → small team (mesh adds ops complexity)

You DO need it if:
  → many microservices (10+)
  → need mTLS between every service (zero trust)
  → need circuit breaking (prevent cascade failures)
  → need traffic observability per service
  → canary between internal services
  → compliance: PCI-DSS, HIPAA (encrypt everything)
```

### Your Project (Istio disabled)
```yaml
# values.yaml — currently disabled
istio:
  enabled: false   ← not using mesh yet
```

If enabled, full stack:
```
Internet
    ↓
NLB (entry point)
    ↓
NGINX (SSL termination + L7 routing)
    ↓
Istio sidecar (mTLS + observability starts here)
    ↓
UI ──mTLS──► Cart ──mTLS──► Orders ──mTLS──► DB
  ↑              ↑               ↑
envoy proxy   envoy proxy    envoy proxy
    ↓
Prometheus + Grafana + Jaeger (full visibility)
```

---

## 12. Full Architecture — Your Project

```
Layer                Who                  Does What
─────────────────────────────────────────────────────────
Internet entry       NLB                  TCP passthrough, node LB
SSL termination      NGINX                Decrypts HTTPS → HTTP
L7 routing           NGINX                path/host routing to services
Pod load balancing   kube-proxy           round robin across pods
Service-to-service   Istio (disabled)     mTLS, retries, circuit breaking
Auth at edge         ALB (not used yet)   Cognito/WAF (if Okta needed)
```

---

## 13. Industry Usage

```
Startup / small team     → ALB only (simple, managed)
Mid-size product team    → NLB + NGINX (flexible, cheap) ← your project
Enterprise / bank / SaaS → ALB + NGINX (security + flexibility)
Multi-cloud company      → NGINX only (same config everywhere)
```

---

## 14. Interview One-liners

**ALB vs NLB:**
> "ALB is Layer 7 — reads full HTTP request, does path/host routing, WAF, Cognito auth. NLB is Layer 4 — only sees IP and port, ultra fast, static IP, cannot read HTTP. Use NLB for raw performance and non-HTTP protocols, ALB for smart HTTP routing and security."

**Why NLB + NGINX together:**
> "NLB is the AWS entry point into the VPC — it's a TCP passthrough. NGINX does all the L7 work inside the cluster — SSL termination, path routing, rate limiting, URL rewriting. One NLB for all services is cheaper than one ALB per service."

**Why ALB needed for Okta:**
> "Okta auth requires HTTP-level operations — redirecting to login page, validating JWT tokens, setting cookies. NLB is Layer 4 and never reads the HTTP packet so it cannot do any of this. ALB reads the full HTTP request so it can handle the entire OIDC flow."

**SSL Termination:**
> "SSL termination means decrypting HTTPS traffic at the load balancer and forwarding plain HTTP internally. In our project NGINX terminates SSL using cert-manager with Let's Encrypt. If we add ALB for Okta, ALB would terminate SSL using ACM and NGINX would only handle routing."

**Service Mesh:**
> "Service mesh handles east-west traffic — communication between services inside the cluster. It injects an Envoy sidecar into every pod that intercepts all traffic and provides automatic mTLS, retries, circuit breaking, and observability. NGINX handles north-south traffic from outside. We have Istio configured but disabled — we'd enable it when we need zero-trust between services or compliance requirements like PCI-DSS."
