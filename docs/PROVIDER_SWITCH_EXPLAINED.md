# How Cart Service Switches from in-memory to DynamoDB

## The Key Question

Your application JAR has `provider: "in-memory"` hardcoded in `application.yml`.
So how does it switch to DynamoDB at runtime?

**Answer:** Environment variables OVERRIDE application.yml in Spring Boot.

---

## The Switch Mechanism — Step by Step

### Step 1 — What's in the JAR (Build Time)

When you build the cart Docker image, `application.yml` is packaged inside:

```yaml
# src/cart/src/main/resources/application.yml
retail:
  cart:
    persistence:
      provider: "in-memory"    # ← hardcoded in JAR
```

This is the **default fallback** — used only if no env var overrides it.

---

### Step 2 — What Kubernetes Injects (Runtime)

When the pod starts, Kubernetes injects environment variables via `envFrom`:

```yaml
# deployment.yaml
envFrom:
  - configMapRef:
      name: cart-config       # ← loaded FIRST
  - secretRef:
      name: cart-secrets      # ← loaded SECOND (overrides ConfigMap)
```

---

### Step 3 — ConfigMap Sets provider=in-memory

```yaml
# ConfigMap "cart-config" (from configmap.yaml template)
apiVersion: v1
kind: ConfigMap
metadata:
  name: cart-config
data:
  RETAIL_CART_PERSISTENCE_PROVIDER: "in-memory"   # ← from values.yaml
```

At this point, the pod has:
```bash
RETAIL_CART_PERSISTENCE_PROVIDER=in-memory
```

---

### Step 4 — Secret OVERRIDES to provider=dynamodb

```yaml
# K8s Secret "cart-secrets" (created by CSI Driver from Secrets Manager)
apiVersion: v1
kind: Secret
metadata:
  name: cart-secrets
data:
  RETAIL_CART_PERSISTENCE_PROVIDER: ZHluYW1vZGI=   # ← base64("dynamodb")
  RETAIL_CART_PERSISTENCE_DYNAMODB_TABLE_NAME: cmV0YWlsLXN0b3JlLWNhcnQteHh4eA==
  RETAIL_CART_PERSISTENCE_DYNAMODB_CREATE_TABLE: dHJ1ZQ==
```

Because `secretRef` comes AFTER `configMapRef` in `envFrom`, it **overwrites** the ConfigMap value.

Final env vars in the pod:
```bash
RETAIL_CART_PERSISTENCE_PROVIDER=dynamodb   # ← Secret wins ✅
RETAIL_CART_PERSISTENCE_DYNAMODB_TABLE_NAME=retail-store-cart-xxxx
RETAIL_CART_PERSISTENCE_DYNAMODB_CREATE_TABLE=true
```

---

### Step 5 — Spring Boot Reads Env Vars (Overrides application.yml)

Spring Boot property resolution order (highest priority first):

```
1. Environment variables           ← RETAIL_CART_PERSISTENCE_PROVIDER=dynamodb ✅
2. application-{profile}.yml
3. application.yml                  ← provider: "in-memory" (ignored)
```

Spring Boot converts env var to property:
```
RETAIL_CART_PERSISTENCE_PROVIDER  →  retail.cart.persistence.provider
```

So at runtime:
```
retail.cart.persistence.provider = "dynamodb"   ← from env var, NOT from application.yml
```

---

### Step 6 — @ConditionalOnProperty Decides Which Service Loads

```java
// InMemoryConfiguration.java
@ConditionalOnProperty(
  prefix = "retail.cart.persistence",
  name = "provider",
  havingValue = "in-memory"     // ← checks if provider == "in-memory"
)
public class InMemoryConfiguration {
  @Bean
  public CartService cartService() {
    return new InMemoryCartService();   // ← NOT loaded (condition false)
  }
}
```

```java
// DynamoDBConfiguration.java
@ConditionalOnProperty(
  prefix = "retail.cart.persistence",
  name = "provider",
  havingValue = "dynamodb"      // ← checks if provider == "dynamodb"
)
public class DynamoDBConfiguration {
  @Bean
  public CartService dynamoCartService(...) {
    return new DynamoDBCartService(...);   // ← LOADED ✅ (condition true)
  }
}
```

Spring Boot evaluates:
```
retail.cart.persistence.provider = "dynamodb"
→ InMemoryConfiguration condition FALSE → skipped
→ DynamoDBConfiguration condition TRUE  → loaded ✅
```

---

## Visual Timeline

```
Docker Image Built
    ↓
application.yml inside JAR: provider="in-memory"
    ↓
────────────────────────────────────────────────────────
Pod Starts on EKS
    ↓
envFrom loads ConfigMap:
    RETAIL_CART_PERSISTENCE_PROVIDER=in-memory
    ↓
envFrom loads Secret (OVERWRITES ConfigMap):
    RETAIL_CART_PERSISTENCE_PROVIDER=dynamodb   ← Secret wins
    ↓
────────────────────────────────────────────────────────
Spring Boot Starts
    ↓
Reads env var RETAIL_CART_PERSISTENCE_PROVIDER=dynamodb
    ↓
Converts to property: retail.cart.persistence.provider=dynamodb
    ↓
application.yml value "in-memory" IGNORED (env var has higher priority)
    ↓
@ConditionalOnProperty evaluates:
    InMemoryConfiguration: provider=="in-memory"? NO → skip
    DynamoDBConfiguration: provider=="dynamodb"? YES → load ✅
    ↓
DynamoDBCartService instantiated
    ↓
Cart data goes to DynamoDB ✅
```

---

## Proof — Check Inside Running Pod

```bash
# 1. Check what env vars the pod actually has
kubectl exec -n retail-store deployment/cart -- env | grep RETAIL_CART

# Output:
# RETAIL_CART_PERSISTENCE_PROVIDER=dynamodb              ← from Secret
# RETAIL_CART_PERSISTENCE_DYNAMODB_TABLE_NAME=retail-store-cart-xxxx
# RETAIL_CART_PERSISTENCE_DYNAMODB_CREATE_TABLE=true

# 2. Check what's still in application.yml inside the JAR
kubectl exec -n retail-store deployment/cart -- cat /workspace/BOOT-INF/classes/application.yml

# Output:
# retail:
#   cart:
#     persistence:
#       provider: "in-memory"    ← still there, but IGNORED

# 3. Check Spring Boot logs
kubectl logs -n retail-store deployment/cart | grep persistence

# Output:
# Using DynamoDB persistence    ← proves DynamoDBConfiguration loaded
# DynamoDB table: retail-store-cart-xxxx
```

---

## Why This Design?

| Benefit | Explanation |
|---------|-------------|
| No code changes | Same JAR works in dev (in-memory) and prod (DynamoDB) |
| No image rebuild | Switch persistence by changing env vars only |
| Secrets stay out of Git | `application.yml` in Git has safe defaults |
| GitOps friendly | Helm values control behavior, not hardcoded config |

---

## What If secrets.enabled=false?

```
envFrom loads ConfigMap:
    RETAIL_CART_PERSISTENCE_PROVIDER=in-memory
    ↓
envFrom loads Secret:
    (skipped — secrets.enabled=false in values.yaml)
    ↓
Spring Boot reads:
    retail.cart.persistence.provider=in-memory   ← ConfigMap value used
    ↓
@ConditionalOnProperty:
    InMemoryConfiguration loads ✅
    DynamoDBConfiguration skipped
    ↓
InMemoryCartService instantiated
    ↓
Cart data stored in HashMap (lost on restart)
```

---

## Summary Table

| Source | Priority | Value | Used? |
|--------|----------|-------|-------|
| `application.yml` (JAR) | Lowest | `in-memory` | ❌ Overridden |
| ConfigMap (Helm) | Medium | `in-memory` | ❌ Overridden |
| Secret (Secrets Manager via KMS) | Highest | `dynamodb` | ✅ WINS |

The switch happens because **environment variables have higher priority than application.yml** in Spring Boot's property resolution.

---

## Full Property Resolution Order (Spring Boot)

From highest to lowest priority:

1. Command line arguments (`--retail.cart.persistence.provider=dynamodb`)
2. Java system properties (`-Dretail.cart.persistence.provider=dynamodb`)
3. **Environment variables** (`RETAIL_CART_PERSISTENCE_PROVIDER=dynamodb`) ← We use this
4. `application-{profile}.properties/yml` outside JAR
5. `application-{profile}.properties/yml` inside JAR
6. `application.properties/yml` outside JAR
7. `application.properties/yml` inside JAR ← Default fallback

Our setup uses #3 (env vars) to override #7 (application.yml in JAR).
