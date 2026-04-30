# Cart Service — Complete Flow Documentation

## Table of Contents
- [Overview](#overview)
- [Architecture](#architecture)
- [Phase 1 — Infrastructure Setup (Terraform)](#phase-1--infrastructure-setup-terraform)
- [Phase 2 — Pod Startup](#phase-2--pod-startup)
- [Phase 3 — Spring Boot Initialization](#phase-3--spring-boot-initialization)
- [Phase 4 — User Adds Item to Cart](#phase-4--user-adds-item-to-cart)
- [Phase 5 — User Views Cart](#phase-5--user-views-cart)
- [Volume Mounts Explained](#volume-mounts-explained)
- [Provider Decision Chain](#provider-decision-chain)
- [Full Flow Diagram](#full-flow-diagram)

---

## Overview

The cart service stores shopping cart data. It supports two persistence modes:

| Mode | Storage | Survives Restart |
|------|---------|-----------------|
| `in-memory` | JVM HashMap | ❌ No |
| `dynamodb` | AWS DynamoDB | ✅ Yes |

Which mode runs is controlled by the env var `RETAIL_CART_PERSISTENCE_PROVIDER`.
This env var is injected securely via **AWS KMS + Secrets Manager + CSI Driver**.

---

## Architecture

```
User Browser
    ↓
UI Service (Java)
    ↓
Cart Service (Java/Spring Boot)
    ↓
AWS DynamoDB Table
```

---

## Phase 1 — Infrastructure Setup (Terraform)

Runs once when you execute `terraform apply`.

```
terraform apply
    ↓
① KMS Key created
   - Dedicated key for secrets encryption
   - Auto-rotation enabled
   - Alias: alias/<cluster-name>-secrets

    ↓
② Secrets Manager secret created: "<cluster-name>/cart"
   Content (encrypted by KMS):
   {
     "RETAIL_CART_PERSISTENCE_PROVIDER": "dynamodb",
     "RETAIL_CART_PERSISTENCE_DYNAMODB_TABLE_NAME": "retail-store-cart-xxxx",
     "RETAIL_CART_PERSISTENCE_DYNAMODB_CREATE_TABLE": "true"
   }

    ↓
③ IAM Policy created (least privilege):
   - secretsmanager:GetSecretValue on cart secret ARN only
   - kms:Decrypt on secrets KMS key only

    ↓
④ IRSA Role created:
   - Bound to service account: retail-store/cart
   - Attached to IAM Policy above
   - Uses OIDC → no static credentials

    ↓
⑤ Secrets Store CSI Driver installed on EKS (DaemonSet on every node)

    ↓
⑥ SecretProviderClass "cart-secrets" created in retail-store namespace:
   - objectName: "<cluster>/cart" from Secrets Manager
   - jmesPath extracts 3 fields
   - secretObjects: instructs CSI to create K8s Secret "cart-secrets"

    ↓
⑦ ArgoCD Application "retail-store-cart" created:
   - Helm parameter secrets.irsaRoleArn injected automatically
   - ArgoCD syncs cart Helm chart from Git
```

---

## Phase 2 — Pod Startup

Runs every time a cart pod starts on EKS.

```
ArgoCD syncs cart Helm chart
    ↓
Kubernetes schedules cart pod on a node
    ↓
Kubernetes sees CSI volume in pod spec:
   volumes:
   - name: secrets-store
     csi:
       driver: secrets-store.csi.k8s.io
       volumeAttributes:
         secretProviderClass: cart-secrets
    ↓
Kubernetes calls CSI Driver on that node
    ↓
CSI Driver reads SecretProviderClass "cart-secrets"
   → finds objectName: "<cluster>/cart" in Secrets Manager
    ↓
CSI Driver uses pod IRSA token:
   Pod ServiceAccount → OIDC → AWS STS AssumeRoleWithWebIdentity
   → temporary AWS credentials (no static keys)
    ↓
CSI Driver calls AWS Secrets Manager:
   GetSecretValue(SecretId="<cluster>/cart")
    ↓
Secrets Manager calls AWS KMS:
   Decrypt(CiphertextBlob=<encrypted secret>)
    ↓
KMS returns decrypted secret JSON
    ↓
CSI Driver extracts jmesPath fields → writes files at /mnt/secrets/:
   /mnt/secrets/RETAIL_CART_PERSISTENCE_PROVIDER          → "dynamodb"
   /mnt/secrets/RETAIL_CART_PERSISTENCE_DYNAMODB_TABLE_NAME → "retail-store-cart-xxxx"
   /mnt/secrets/RETAIL_CART_PERSISTENCE_DYNAMODB_CREATE_TABLE → "true"
    ↓
CSI Driver creates K8s Secret "cart-secrets":
   apiVersion: v1
   kind: Secret
   metadata:
     name: cart-secrets
     namespace: retail-store
   data:
     RETAIL_CART_PERSISTENCE_PROVIDER: ZHluYW1vZGI=        (base64 "dynamodb")
     RETAIL_CART_PERSISTENCE_DYNAMODB_TABLE_NAME: cmV0YWls...
     RETAIL_CART_PERSISTENCE_DYNAMODB_CREATE_TABLE: dHJ1ZQ==
    ↓
Cart container starts
    ↓
envFrom injects ConfigMap first:
   RETAIL_CART_PERSISTENCE_PROVIDER=in-memory   ← from ConfigMap
    ↓
envFrom injects Secret next (OVERRIDES ConfigMap):
   RETAIL_CART_PERSISTENCE_PROVIDER=dynamodb    ← from cart-secrets ✅
   RETAIL_CART_PERSISTENCE_DYNAMODB_TABLE_NAME=retail-store-cart-xxxx
   RETAIL_CART_PERSISTENCE_DYNAMODB_CREATE_TABLE=true
```

---

## Phase 3 — Spring Boot Initialization

Runs inside the cart container after env vars are injected.

```
Spring Boot starts (CartApplication.main())
    ↓
Reads env var: RETAIL_CART_PERSISTENCE_PROVIDER=dynamodb
    ↓
DynamoDBProperties.java binds env vars:
   @ConfigurationProperties("retail.cart.persistence.dynamodb")
   tableName   = "retail-store-cart-xxxx"   ← from RETAIL_CART_PERSISTENCE_DYNAMODB_TABLE_NAME
   createTable = true                        ← from RETAIL_CART_PERSISTENCE_DYNAMODB_CREATE_TABLE
   endpoint    = ""                          ← not set, uses AWS default
    ↓
@ConditionalOnProperty checks:
   provider = "dynamodb" → DynamoDBConfiguration.java loads ✅
   provider = "in-memory" → InMemoryConfiguration.java skipped ❌
    ↓
DynamoDBConfiguration.java creates beans:
   ① DynamoDbClient built:
      - No endpoint override → connects to real AWS DynamoDB
      - Uses pod IRSA credentials automatically via AWS SDK
   ② DynamoDbEnhancedClient built (wraps DynamoDbClient)
   ③ DynamoDBCartService instantiated:
      - tableName = "retail-store-cart-xxxx"
      - createTable = true
    ↓
DynamoDBCartService.init() runs (@PostConstruct):
   createTable=true → calls this.table.createTable(...)
   Creates DynamoDB table with:
   - Partition key: id (String)
   - GSI: idx_global_customerId (for querying by customer)
    ↓
DynamoDBCartService.onApplicationEvent() runs (ApplicationReadyEvent):
   Calls this.items("test") → verifies DynamoDB connection is working
    ↓
Cart service READY on port 8080 ✅
Spring Boot logs: "Using DynamoDB persistence"
```

---

## Phase 4 — User Adds Item to Cart

Runs on every "Add to Cart" click.

```
User clicks "Add to Cart" on product page
    ↓
UI Service sends HTTP request:
   POST http://cart/carts/customer123/items
   Content-Type: application/json
   Body: { "itemId": "item1", "quantity": 2, "unitPrice": 100 }
    ↓
CartsController.java receives request:
   @PostMapping("/{customerId}/items")
   public Item addToCart(@PathVariable String customerId, @RequestBody Item item)
    ↓
Calls: this.service.add("customer123", "item1", 2, 100)
   this.service → Spring injects DynamoDBCartService (provider=dynamodb)
    ↓
DynamoDBCartService.add() executes:

   Step 1: Build partition key
   String hashKey = "customer123:item1"   ← customerId + ":" + itemId

   Step 2: Check if item already exists
   this.table.getItem(Key.builder().partitionValue("customer123:item1").build())
   → AWS DynamoDB GetItem API called

   Step 3a: Item NOT found → create new:
   DynamoItemEntity item = new DynamoItemEntity(
     "customer123:item1",  ← id (partition key)
     "customer123",        ← customerId (GSI key)
     "item1",              ← itemId
     2,                    ← quantity
     100                   ← unitPrice
   )

   Step 3b: Item FOUND → update quantity:
   item.setQuantity(existingQuantity + 2)

   Step 4: Write to DynamoDB
   this.table.putItem(item)
   → AWS SDK calls DynamoDB PutItem API
   → Item stored in table "retail-store-cart-xxxx"
    ↓
DynamoDB stores:
   {
     "id":         "customer123:item1",
     "customerId": "customer123",
     "itemId":     "item1",
     "quantity":   2,
     "unitPrice":  100
   }
    ↓
Returns DynamoItemEntity back to CartsController
    ↓
CartsController returns HTTP 201 Created to UI
    ↓
UI shows "Item added to cart" ✅
```

---

## Phase 5 — User Views Cart

Runs when user opens the cart page.

```
User opens cart page
    ↓
UI Service sends HTTP request:
   GET http://cart/carts/customer123/items
    ↓
CartsController.java receives request:
   @GetMapping("/{customerId}/items")
   public List<Item> getItems(@PathVariable String customerId)
    ↓
Calls: this.service.items("customer123")
    ↓
DynamoDBCartService.items() executes:

   Step 1: Get GSI reference
   DynamoDbIndex<DynamoItemEntity> index = this.table.index("idx_global_customerId")

   Step 2: Build query
   QueryConditional q = QueryConditional.keyEqualTo(
     Key.builder().partitionValue("customer123").build()
   )

   Step 3: Execute query
   Iterator<Page<DynamoItemEntity>> result = index.query(q).iterator()
   → AWS SDK calls DynamoDB Query API on GSI "idx_global_customerId"
   → Finds all items where customerId = "customer123"
    ↓
DynamoDB returns:
   [
     { id: "customer123:item1", customerId: "customer123", itemId: "item1", quantity: 2, unitPrice: 100 },
     { id: "customer123:item2", customerId: "customer123", itemId: "item2", quantity: 1, unitPrice: 50  }
   ]
    ↓
DynamoDBCartService returns List<DynamoItemEntity>
    ↓
CartsController maps to List<Item> → returns HTTP 200 to UI
    ↓
UI renders cart items to user ✅
```

---

## Volume Mounts Explained

Two volumes exist in the cart deployment — completely different purposes:

```
Volume 1: tmp-volume
─────────────────────────────────────────
Type     : emptyDir (medium: Memory)
Mount    : /tmp
Why      : readOnlyRootFilesystem=true makes entire container
           filesystem read-only. Java/Spring Boot/Tomcat needs
           to write temp files to /tmp at runtime.
Contains : JVM perf data, Tomcat working dir, Spring temp files
Cart app : ❌ Never reads/writes cart data here
Secrets  : ❌ Never
Created  : Day 1, before any KMS changes

Volume 2: secrets-store
─────────────────────────────────────────
Type     : CSI (secrets-store.csi.k8s.io)
Mount    : /mnt/secrets
Why      : CSI Driver REQUIRES a volume mount to trigger.
           Without it, CSI never runs, never fetches from
           Secrets Manager, K8s Secret never created, pod crashes.
Contains : 3 secret files written by CSI Driver
Cart app : ❌ Never reads directly
Secrets  : ✅ Yes — but only as trigger to create K8s Secret
Created  : Added for KMS secrets integration
```

---

## Provider Decision Chain

How `provider=dynamodb` wins over `provider=in-memory`:

```
Layer 1: application.yml (JAR default)
   retail.cart.persistence.provider = "in-memory"
   ↓ overridden by

Layer 2: ConfigMap (Helm values.yaml → app.persistence.provider)
   RETAIL_CART_PERSISTENCE_PROVIDER = "in-memory"
   ↓ overridden by

Layer 3: K8s Secret "cart-secrets" (from Secrets Manager via KMS)
   RETAIL_CART_PERSISTENCE_PROVIDER = "dynamodb"  ← WINS ✅
   (secretRef loaded after configMapRef in envFrom)
   ↓ read by

Layer 4: Spring Boot @ConditionalOnProperty
   provider = "dynamodb" → DynamoDBCartService loads
   provider = "in-memory" → InMemoryCartService loads (skipped)
```

---

## Full Flow Diagram

```
┌──────────────────────────────────────────────────────────────────┐
│  TERRAFORM APPLY (once)                                          │
│                                                                  │
│  KMS Key → Secrets Manager → IRSA Role → CSI Driver             │
│  → SecretProviderClass → ArgoCD App (with irsaRoleArn)          │
└──────────────────────────────────────────────────────────────────┘
                              ↓
┌──────────────────────────────────────────────────────────────────┐
│  POD STARTUP (every restart)                                     │
│                                                                  │
│  CSI Volume mounted → CSI Driver triggers                        │
│  → IRSA token → STS → temp credentials                          │
│  → Secrets Manager GetSecretValue                                │
│  → KMS Decrypt                                                   │
│  → files written to /mnt/secrets/                               │
│  → K8s Secret "cart-secrets" created                            │
│  → envFrom injects provider=dynamodb into pod                   │
└──────────────────────────────────────────────────────────────────┘
                              ↓
┌──────────────────────────────────────────────────────────────────┐
│  SPRING BOOT INIT (every restart)                                │
│                                                                  │
│  Reads provider=dynamodb                                         │
│  → @ConditionalOnProperty → DynamoDBConfiguration loads         │
│  → DynamoDbClient → DynamoDbEnhancedClient                      │
│  → DynamoDBCartService instantiated                              │
│  → DynamoDB table created (if not exists)                        │
│  → Cart service READY on :8080                                   │
└──────────────────────────────────────────────────────────────────┘
                              ↓
┌──────────────────────────────────────────────────────────────────┐
│  ADD TO CART (every user action)                                 │
│                                                                  │
│  UI → POST /carts/{customerId}/items                             │
│  → CartsController.addToCart()                                   │
│  → DynamoDBCartService.add()                                     │
│  → hashKey = customerId:itemId                                   │
│  → DynamoDB GetItem (check exists)                               │
│  → DynamoDB PutItem (write/update)                               │
│  → HTTP 201 back to UI ✅                                        │
└──────────────────────────────────────────────────────────────────┘
                              ↓
┌──────────────────────────────────────────────────────────────────┐
│  VIEW CART (every page load)                                     │
│                                                                  │
│  UI → GET /carts/{customerId}/items                              │
│  → CartsController.getItems()                                    │
│  → DynamoDBCartService.items()                                   │
│  → DynamoDB Query on GSI "idx_global_customerId"                 │
│  → Returns all items for customer                                │
│  → HTTP 200 back to UI ✅                                        │
└──────────────────────────────────────────────────────────────────┘
```

---

## Files Reference

| File | Purpose |
|------|---------|
| `terraform/secrets.tf` | KMS key + Secrets Manager secrets |
| `terraform/iam_secrets.tf` | IRSA role + IAM policy |
| `terraform/addons.tf` | Secrets Store CSI Driver installation |
| `terraform/secrets_automation.tf` | SecretProviderClass + ArgoCD app with IRSA |
| `src/cart/chart/templates/deployment.yaml` | Two volumes + envFrom (ConfigMap + Secret) |
| `src/cart/chart/templates/serviceaccount.yaml` | IRSA annotation injected via Helm |
| `src/cart/chart/templates/configmap.yaml` | Default provider config |
| `src/cart/chart/values.yaml` | secrets.enabled=true + irsaRoleArn |
| `src/cart/src/main/resources/application.yml` | Spring Boot default provider=in-memory |
| `src/cart/src/main/java/.../config/DynamoDBConfiguration.java` | Loads DynamoDBCartService when provider=dynamodb |
| `src/cart/src/main/java/.../config/InMemoryConfiguration.java` | Loads InMemoryCartService when provider=in-memory |
| `src/cart/src/main/java/.../services/DynamoDBCartService.java` | All cart operations against DynamoDB |
| `src/cart/src/main/java/.../services/InMemoryCartService.java` | All cart operations against HashMap |
| `src/cart/src/main/java/.../web/CartsController.java` | REST API endpoints for cart |
| `src/cart/src/main/java/.../repositories/dynamo/entities/DynamoItemEntity.java` | DynamoDB table schema |
| `src/cart/src/main/java/.../config/DynamoDBProperties.java` | Binds env vars to Java properties |
