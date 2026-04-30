# Cart Data Storage Verification Guide

## Where Cart Data is Actually Stored

### 1. In-Memory Mode (Default)

**Code Location:** `InMemoryCartService.java` line 31-33
```java
private final Map<String, Cart> carts;

public InMemoryCartService() {
    this.carts = new HashMap<>();  // ← Data stored in JVM heap memory
}
```

**Storage:** Java `HashMap<String, Cart>` object in JVM heap
- **NOT** in `/tmp` volume
- **NOT** on disk
- Lost when pod restarts

**Verification Command:**
```bash
# 1. Add item to cart via API
kubectl exec -n retail-store deployment/cart -- curl -X POST \
  http://localhost:8080/carts/customer123/items \
  -H "Content-Type: application/json" \
  -d '{"itemId":"item1","quantity":2,"unitPrice":100}'

# 2. Check /tmp volume - you'll find NO cart data there
kubectl exec -n retail-store deployment/cart -- ls -la /tmp/
# Output: Only Java temp files like tomcat.*, spring.*, NOT cart data

# 3. Restart pod
kubectl rollout restart deployment/cart -n retail-store

# 4. Try to get cart - it's GONE (proves it was in JVM heap, not /tmp)
kubectl exec -n retail-store deployment/cart -- curl http://localhost:8080/carts/customer123
# Output: {"customerId":"customer123","items":[]}  ← empty!
```

---

### 2. DynamoDB Mode (Persistent)

**Code Location:** `DynamoDBCartService.java` line 48-67
```java
private final DynamoDbTable<DynamoItemEntity> table;

public DynamoDBCartService(
    DynamoDbClient dynamoDBClient,
    DynamoDbEnhancedClient dynamoDbEnhancedClient,
    boolean createTable,
    String tableName
) {
    this.table = dynamoDbEnhancedClient.table(tableName, CART_TABLE_SCHEMA);
    // ← Data stored in AWS DynamoDB table
}
```

**Storage:** AWS DynamoDB table (remote database)
- **NOT** in `/tmp` volume
- **NOT** in pod filesystem
- Survives pod restarts

**Verification Command:**
```bash
# 1. Enable DynamoDB mode
helm upgrade cart src/cart/chart/ -n retail-store \
  --set app.persistence.provider=dynamodb \
  --set app.persistence.dynamodb.tableName=retail-cart \
  --set app.persistence.dynamodb.createTable=true

# 2. Add item to cart
kubectl exec -n retail-store deployment/cart -- curl -X POST \
  http://localhost:8080/carts/customer456/items \
  -H "Content-Type: application/json" \
  -d '{"itemId":"item2","quantity":5,"unitPrice":200}'

# 3. Check DynamoDB directly (from AWS CLI)
aws dynamodb scan --table-name retail-cart --region ap-south-1
# Output: You'll see the cart item stored in DynamoDB

# 4. Check /tmp volume - still NO cart data
kubectl exec -n retail-store deployment/cart -- ls -la /tmp/
# Output: Only Java temp files, NOT cart data

# 5. Restart pod
kubectl rollout restart deployment/cart -n retail-store

# 6. Get cart - it's STILL THERE (proves it's in DynamoDB, not pod)
kubectl exec -n retail-store deployment/cart -- curl http://localhost:8080/carts/customer456
# Output: {"customerId":"customer456","items":[{"itemId":"item2",...}]}  ← persisted!
```

---

## Configuration Logic

**File:** `application.yml`
```yaml
retail:
  cart:
    persistence:
      provider: "in-memory"   # ← Controls which service is loaded
```

**File:** `InMemoryConfiguration.java`
```java
@ConditionalOnProperty(
  prefix = "retail.cart.persistence",
  name = "provider",
  havingValue = "in-memory"   // ← Only loads if provider=in-memory
)
public class InMemoryConfiguration {
  @Bean
  public CartService cartService() {
    return new InMemoryCartService();  // ← Uses HashMap in JVM heap
  }
}
```

**File:** `DynamoDBConfiguration.java` (similar pattern)
```java
@ConditionalOnProperty(
  prefix = "retail.cart.persistence",
  name = "provider",
  havingValue = "dynamodb"   // ← Only loads if provider=dynamodb
)
```

---

## What `/tmp` Volume Actually Contains

```bash
kubectl exec -n retail-store deployment/cart -- find /tmp -type f | head -20
```

**Typical output:**
```
/tmp/tomcat.8080.12345/work/Tomcat/localhost/ROOT/...
/tmp/hsperfdata_1000/123
/tmp/spring.log
```

These are:
- Tomcat working directory (unpacked WAR files)
- JVM performance data
- Spring Boot temp logs

**NOT cart data!**

---

## Summary Table

| Storage Location | In-Memory Mode | DynamoDB Mode | `/tmp` Volume |
|------------------|----------------|---------------|---------------|
| Cart items stored | JVM heap (`HashMap`) | AWS DynamoDB | ❌ Never |
| Survives pod restart | ❌ No | ✅ Yes | ❌ No |
| Purpose | Demo/testing | Production | Java temp files only |
| Data type | Application data | Application data | JVM/Tomcat temp files |

---

## Proof: Check the Code Flow

1. **API Request:** `POST /carts/{customerId}/items`
2. **Controller:** `CartsController.java` → calls `cartService.add()`
3. **Service (in-memory):** `InMemoryCartService.add()` → stores in `this.carts` HashMap
4. **Service (DynamoDB):** `DynamoDBCartService.add()` → calls `this.table.putItem()`

**Neither service ever touches `/tmp`!**

The `/tmp` volume is purely for Java runtime requirements due to `readOnlyRootFilesystem: true`.
