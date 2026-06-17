# ☕ micewriter-sdk-java
> 🌐 Part of the **[mIceWriter Telemetry Ingestion Ecosystem](file:///c:/Users/marko/source/repos/micewriter-hub/README.md)**

[![Ecosystem: mIceWriter](https://img.shields.io/badge/Ecosystem-mIceWriter-blueviolet?style=flat-square)](file:///c:/Users/marko/source/repos/micewriter-hub/README.md)
[![Lens: What](https://img.shields.io/badge/Lens-What-green?style=flat-square)](#)
[![Component: Java SDK](https://img.shields.io/badge/Component-Java%20SDK-blue?style=flat-square)](#)

This repository contains the Library/SDK that product developers use to interface with the `micewriter-engine` sidecar.
It is a **Maven multi-module project** that ships five artifacts from a single repo:

| Module | Artifact | Purpose |
|---|---|---|
| **BOM** | `micewriter-sdk-bom` | Import this into your `<dependencyManagement>` to align versions |
| **api** | `micewriter-sdk-java-api` | Contains *only* the `@IcebergEntity` and `@IcebergId` annotations. Use this in shared domain libraries! |
| **core** | `micewriter-sdk-java-core` | Framework-agnostic base — used transitively by both starters |
| **spring** | `micewriter-sdk-java-spring` | Spring Boot applications |
| **dropwizard** | `micewriter-sdk-java-dropwizard` | Dropwizard applications |

## 🌿 Branches and Versioning
The SDK maintains two active release lines depending on your infrastructure. They have **diverged** on both transport and serialization:
- **`2.x.x` (main branch)**: **gRPC over HTTP/2** for central per-table pipelines; serializes records as **CBOR** (Jackson `CBORFactory`).
- **`1.x.x` (v1 branch)**: **Unix Domain Sockets (UDS)** for per-pod sidecars; serializes records as **JSON** (Jackson `ObjectMapper`). The v1 line keeps JSON on the wire to stay lean on host CPU.

The sections below describe the **v1 (UDS) SDK**; v2 differences are called out inline. The v2 publish path has its own section: [v2 Transport: gRPC + CBOR](#-v2-transport-grpc--cbor-design).

> ⚠️ **v2 implementation status (as of 2026-06-17).** The `2.x` transport described here — the gRPC `Ingest` / `RegisterSchema` RPCs and CBOR record serialization — is the **target design**, not yet the shipped code. The current `main`-branch SDK still uses the **v1 UDS + JSON** transport: `UdsConnection` over Netty Epoll, Jackson `ObjectMapper`, and the `INGEST_RECORD 0x02` framing in the [Wire Protocol](#-wire-protocol) section. There is no gRPC client, no `.proto`, and no CBOR dependency wired in (`micewriter-sdk-java-core/pom.xml` carries an empty `<!-- CBOR ... -->` placeholder). The only v2-era change landed so far is **async pipelining over the existing UDS path** (`sendAsyncWithRetry`, §⚙️.3). Confirm the gRPC/CBOR cutover has actually merged before depending on it.

## 🛠️ Core Technology Stack
- **Language:** Java 17
- **Framework support:** Spring Boot AutoConfiguration **and** Dropwizard 4.x Bundle
- **Serialization:** JSON via Jackson `ObjectMapper` (v1). *(v2 uses CBOR via `CBORFactory`.)*
- **Network IO:** Netty Epoll (UDS communication — Linux only). *(v2 uses gRPC over HTTP/2.)*

## ⚙️ Functionality

This library abstracts away the IPC complexity so business developers just write standard Java code.

1. **Annotations:** Provides `@IcebergEntity` and `@IcebergId` to demarcate domain objects (POJOs) that should be ingested. These are in the `core` module and are framework-agnostic.

2. **Schema registration:** On startup, `SchemaRegistrar` sends one `REGISTER_SCHEMA` (0x01) JSON message per `@IcebergEntity` class, telling the engine to prepare the Iceberg table.
   - *Spring Boot*: scans the classpath automatically via `SpringSchemaRegistrar` on `ContextRefreshedEvent`; bounded by `micewriter.base-package`.
   - *Dropwizard*: entity classes are declared explicitly via `MicewriterBundle.entities(...)` because Dropwizard provides no classpath scanner.

3. **`IcebergStreamTemplate`:** Serializes the object to **JSON** bytes and sends it as an `INGEST_RECORD` (0x02) message over the Unix Domain Socket. The preferred path is the **bounded-async** `sendAsyncWithRetry(pojo)`, which pipelines records (returning a `CompletableFuture`) with backpressure enforced by an 8 MiB in-flight byte-budget `Semaphore` and exponential-backoff retry — this lifts the ~104 records/s ceiling of the old synchronous path. The blocking `send(pojo)` (ACK per record, typically microseconds) is now **`@Deprecated`** in favor of `sendAsyncWithRetry`. The template is:
   - A Spring `@Bean` in Spring Boot apps (injected with `@Autowired`).
   - Retrieved via `MicewriterBundle.getTemplate()` in Dropwizard apps.

4. **Lifecycle management:**
   - *Spring Boot*: `UdsConnection` is a bean managed by the Spring context; closed on context shutdown.
   - *Dropwizard*: connection open/close is handled by a `Managed` object registered by `MicewriterBundle`.
   - **Reconnect:** if the engine container restarts and drops the socket, `UdsConnection` reconnects lazily on the next send (`ensureConnected()`), and `SchemaRegistrar` automatically re-registers all known schemas to the restarted engine — so a sidecar restart no longer wedges the app pod.

   > **Append-only:** The SDK is designed exclusively for high-throughput, append-only telemetry. Row-level updates or deletes are not supported.

## 🔌 Wire Protocol

Every message over the UDS has this layout:

```
[4-byte big-endian length][1-byte msg type][payload bytes]
```

| Message | Type byte | Payload encoding |
|---|---|---|
| `REGISTER_SCHEMA` | `0x01` | JSON `{ table, namespace, fields }` |
| `INGEST_RECORD` | `0x02` | `[table_name_len u16][table_name UTF-8][JSON bytes]` |
| `FLUSH_NOW`       | `0x03` | `[Empty Payload]` |
| ACK (engine → SDK) | — | JSON `{ status: "ok"\|"error", msg? }` |

## 🚀 v2 Transport: gRPC + CBOR (design)

> The Wire Protocol above is **v1 (UDS)**. v2 keeps the same SDK surface — `@IcebergEntity`, `@IcebergId`, and `IcebergStreamTemplate.sendAsyncWithRetry(pojo)` — but changes how records leave the JVM. This section is **design-level**; see the [implementation-status note](#-branches-and-versioning) above for what is actually shipped. Full architecture: [system-overview.md §2](system-overview.md) and [per-table-pipelines.md §2–4](per-table-pipelines.md).

In v2 there is no per-pod sidecar and no Unix domain socket. The SDK **routes each record by `@IcebergEntity.table` to a per-table engine pipeline and publishes over gRPC (HTTP/2)**.

### Channels & routing
- The table name resolves to a pipeline endpoint via the `MICEWRITER_RESOLVER` template (default `engine-{table}.micewriter.svc:9090`), with a `MICEWRITER_RESOLVER_OVERRIDES` map for tables that don't fit the convention (legacy hyphenated names, cross-namespace pipelines).
- A `ManagedChannel` is **lazy-created per resolved endpoint and cached** for the SDK's lifetime. gRPC's native keepalive and reconnect replace the v1 `UdsConnection.ensureConnected()` reconnect logic — there is no app-side socket lifecycle to manage.

### RPCs
| RPC | Direction | Payload | Notes |
|---|---|---|---|
| `RegisterSchema` | SDK → Pipeline | JSON `{ table, namespace, fields }` | Unary; called once per `@IcebergEntity` class at startup; bounded retry on an unreachable pipeline. |
| `Ingest` | SDK → Pipeline | Streaming **CBOR** records | Bidi streaming over the long-lived channel; ACK per record (replaces the UDS `INGEST_RECORD 0x02` message). |
| `FlushNow` | SDK → Pipeline | Empty | Unary; honored only when `ENABLE_MANUAL_FLUSH=true` (non-production). |

### Serialization
- **Records (`Ingest`)** — the POJO is serialized to **CBOR** via Jackson `CBORFactory`, replacing v1's `ObjectMapper` JSON. The application-layer payload keeps the **same per-record shape** as v1; only the body encoding changes: `[u16 table_name_len][table_name UTF-8][CBOR bytes]`. gRPC supplies the message framing that v1's `[4-byte length]` prefix provided. Records are **opaque CBOR carried inside the gRPC stream** — they are *not* modeled as protobuf messages, so adopters never regenerate a proto when their POJOs change.
- **Schemas (`RegisterSchema`)** stay **JSON** — schema registration is off the hot path, so the lighter-weight CBOR is unnecessary there.
- **Payload cap** — 16 MB per record at both SDK and engine. (A 16 MB monolithic CBOR float array can expand into 200+ MB of `serde_json::Value` DOM in the engine's `arrow-json` parse step.) See [system-overview.md §2.3](system-overview.md).

### Config (v2)
There is no `socket-path` in v2 — the per-pod sidecar and its UDS are gone, and the v1 `micewriter-k8s-injector` admission webhook is sunset. Apps point at the resolver instead:

```yaml
# application.yml (Spring) / config.yml (Dropwizard)
micewriter:
  resolver: "engine-{table}.micewriter.svc:9090"
  resolverOverrides:
    legacy-orders-v1: "engine-legacy-orders.legacy.svc:9090"
    cross-ns-events:  "engine-events.shared-data.svc:9090"
  enabled: true
```

The `@IcebergEntity` / `@IcebergId` annotations and the `sendAsyncWithRetry` call site are **unchanged from v1** — migrating an app is a config + dependency-version change, not a code change.

## 🏗️ Spring Boot Usage

Add the starter dependency — it auto-configures everything via `META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports`. We recommend importing the BOM in your `<dependencyManagement>` so you don't have to specify version tags.

```xml
<dependencyManagement>
    <dependencies>
        <dependency>
            <groupId>com.micewriter</groupId>
            <artifactId>micewriter-sdk-bom</artifactId>
            <version>2.0.0</version> <!-- Use 1.x.x if using the v1 UDS architecture -->
            <type>pom</type>
            <scope>import</scope>
        </dependency>
    </dependencies>
</dependencyManagement>

<dependencies>
    <dependency>
        <groupId>com.micewriter</groupId>
        <artifactId>micewriter-sdk-java-spring</artifactId>
    </dependency>
</dependencies>
```

```java
@IcebergEntity(table = "telemetry_events", namespace = {"analytics"})
public class TelemetryEvent {
    @IcebergId private String id;
    private String source;
    private Instant occurredAt;
}

@Service
public class EventService {
    @Autowired IcebergStreamTemplate icebergTemplate;

    public void record(TelemetryEvent event) {
        icebergTemplate.sendAsyncWithRetry(event);   // bounded-async; send() is deprecated
    }
}
```

```yaml
# application.yml
micewriter:
  socket-path: /var/run/app/iceberg.sock
  base-package: com.example.events   # narrows @IcebergEntity classpath scan
  connect-timeout-ms: 5000
  ack-timeout-ms: 5000
  enabled: true
```

## 🏗️ Dropwizard Usage

Add the bundle dependency — entity classes must be listed explicitly. Again, we recommend using the BOM:

```xml
<dependencyManagement>
    <dependencies>
        <dependency>
            <groupId>com.micewriter</groupId>
            <artifactId>micewriter-sdk-bom</artifactId>
            <version>2.0.0</version> <!-- Use 1.x.x if using the v1 UDS architecture -->
            <type>pom</type>
            <scope>import</scope>
        </dependency>
    </dependencies>
</dependencyManagement>

<dependencies>
    <dependency>
        <groupId>com.micewriter</groupId>
        <artifactId>micewriter-sdk-java-dropwizard</artifactId>
    </dependency>
</dependencies>
```

```java
// 1. Add MicewriterConfig to your Configuration class
public class AppConfig extends Configuration {
    @Valid @NotNull
    private MicewriterConfig micewriter = new MicewriterConfig();

    @JsonProperty("micewriter")
    public MicewriterConfig getMicewriter() { return micewriter; }
}

// 2. Register the bundle and list entity classes explicitly
public class App extends Application<AppConfig> {

    private final MicewriterBundle<AppConfig> micewriter =
        new MicewriterBundle<>(AppConfig::getMicewriter)
            .entities(TelemetryEvent.class);

    @Override
    public void initialize(Bootstrap<AppConfig> bootstrap) {
        bootstrap.addBundle(micewriter);
    }

    @Override
    public void run(AppConfig config, Environment env) {
        env.jersey().register(new EventResource(micewriter.getTemplate()));
    }
}
```

```yaml
# config.yml
micewriter:
  socketPath: /var/run/app/iceberg.sock
  connectTimeoutMs: 5000
  ackTimeoutMs: 5000
```

## 📦 Output Artifacts
Five compiled `.jar` files released together at the same version, published to Maven Central, an internal Nexus/Artifactory, or Maven Local.

---
### 🔗 The mIceWriter Ecosystem

**🎯 Why:**
* [Motivation & target adopter](why.md)

**🛠️ What:**
* [System overview & wire protocol](system-overview.md)
* [v2: Per-table pipelines](per-table-pipelines.md)
* [v1 → v2 migration rationale](v1-to-v2-migration.md)
* [Rust engine internals](micewriter-engine.md)
* [Java SDK](micewriter-sdk-java.md)

**🔬 Is it viable?**
* [Feasibility evaluation](feasibility.md)
* [Getting started (local deploy)](getting-started.md)
* [Local infrastructure](micewriter-local-infra.md)
* [Reference sandbox app](micewriter-sandbox.md)
* [Load testing specification](load-testing-spec.md)

**📊 Use:**
* [Querying Iceberg tables](querying.md)
