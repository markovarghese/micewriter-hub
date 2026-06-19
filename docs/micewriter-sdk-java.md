# ☕ micewriter-sdk-java
> 🌐 Part of the **[mIceWriter Telemetry Ingestion Ecosystem](../README.md)**

[![Ecosystem: mIceWriter](https://img.shields.io/badge/Ecosystem-mIceWriter-blueviolet?style=flat-square)](../README.md)
[![Lens: What](https://img.shields.io/badge/Lens-What-green?style=flat-square)](#)
[![Component: Java SDK](https://img.shields.io/badge/Component-Java%20SDK-blue?style=flat-square)](#)

This repository contains the Library/SDK that product developers use to publish records to the `micewriter-engine` per-table pipelines.
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
- **`2.x.x` (main branch)**: **gRPC over HTTP/2** to central per-table pipelines; serializes records as **CBOR** (Jackson `CBORFactory`).
- **`1.x.x` (v1 branch)**: **Unix Domain Sockets (UDS)** for per-pod sidecars; serializes records as **JSON** (Jackson `ObjectMapper`). The v1 line keeps JSON on the wire to stay lean on host CPU.

The sections below describe the **v2 (gRPC) SDK**; v1 differences are called out inline, and the v1 UDS wire protocol is preserved in its own section: [v1 Transport: UDS + JSON](#-v1-transport-uds--json). Full architecture: [system-overview.md §2](system-overview.md) and [per-table-pipelines.md §2–4](per-table-pipelines.md).

## 🛠️ Core Technology Stack
- **Language:** Java 17
- **Framework support:** Spring Boot AutoConfiguration **and** Dropwizard 4.x Bundle
- **Serialization:** CBOR via Jackson `CBORFactory`. *(v1 uses JSON via `ObjectMapper`.)*
- **Network IO:** gRPC over HTTP/2 (`ManagedChannel` per pipeline endpoint). *(v1 uses Netty Epoll over a UDS — Linux only.)*

## ⚙️ Functionality

This library abstracts away the transport complexity so business developers just write standard Java code.

1. **Annotations:** Provides `@IcebergEntity` and `@IcebergId` to demarcate domain objects (POJOs) that should be ingested. These are in the `api` module and are framework-agnostic.

2. **Schema registration:** On startup, `SchemaRegistrar` sends one `RegisterSchema` RPC (unary gRPC, JSON `{ table, namespace, fields }`) per `@IcebergEntity` class, telling the pipeline to prepare the Iceberg table. Schema registration stays **JSON** — it is off the hot path, so the lighter-weight CBOR is unnecessary there.
   - *Spring Boot*: scans the classpath automatically via `SpringSchemaRegistrar` on `ContextRefreshedEvent`; bounded by `micewriter.base-package`.
   - *Dropwizard*: entity classes are declared explicitly via `MicewriterBundle.entities(...)` because Dropwizard provides no classpath scanner.

3. **`IcebergStreamTemplate`:** Serializes the object to **CBOR** bytes, **routes it by `@IcebergEntity.table`** to the correct pipeline endpoint, and streams it over the `Ingest` RPC. The preferred path is the **bounded-async** `sendAsyncWithRetry(pojo)`, which pipelines records (returning a `CompletableFuture`) with backpressure enforced by an in-flight byte-budget `Semaphore` and exponential-backoff retry — this lifts the ~104 records/s ceiling of the old synchronous path. The blocking `send(pojo)` (ACK per record) is **`@Deprecated`** in favor of `sendAsyncWithRetry`. The template is:
   - A Spring `@Bean` in Spring Boot apps (injected with `@Autowired`).
   - Retrieved via `MicewriterBundle.getTemplate()` in Dropwizard apps.

   > **Records are opaque CBOR carried inside the gRPC stream** — they are *not* modeled as protobuf messages, so adopters never regenerate a `.proto` when their POJOs change. The `.proto` defines only the RPC envelope, never the record schema.

4. **Lifecycle management:**
   - *Spring Boot*: `ManagedChannel`s are managed by the Spring context; closed on context shutdown.
   - *Dropwizard*: channel open/close is handled by a `Managed` object registered by `MicewriterBundle`.
   - **Reconnect:** A `ManagedChannel` is lazy-created per resolved endpoint and cached for the SDK's lifetime. gRPC's native keepalive and reconnect handle transport blips — there is no app-side socket lifecycle to manage. On app restart, `SchemaRegistrar` re-registers all schemas with each pipeline.

   > **Append-only:** The SDK is designed exclusively for high-throughput, append-only telemetry. Row-level updates or deletes are not supported.

## 🔌 Transport: gRPC + CBOR

In v2 there is no per-pod sidecar and no Unix domain socket. The SDK **routes each record by `@IcebergEntity.table` to a per-table engine pipeline and publishes over gRPC (HTTP/2)**.

### Channels & routing
- The table name resolves to a pipeline endpoint via the `MICEWRITER_RESOLVER` template (default `engine-{table}.micewriter.svc:9090`), with a `MICEWRITER_RESOLVER_OVERRIDES` map for tables that don't fit the convention (legacy hyphenated names, cross-namespace pipelines).
- A `ManagedChannel` is **lazy-created per resolved endpoint and cached** for the SDK's lifetime. gRPC's native keepalive and reconnect replace the v1 `UdsConnection.ensureConnected()` reconnect logic.

### RPCs
| RPC | Direction | Payload | Notes |
|---|---|---|---|
| `RegisterSchema` | SDK → Pipeline | JSON `{ table, namespace, fields }` | Unary; called once per `@IcebergEntity` class at startup; bounded retry on an unreachable pipeline. |
| `Ingest` | SDK → Pipeline | Streaming **CBOR** records | Bidi streaming over the long-lived channel; ACK per record. |
| `FlushNow` | SDK → Pipeline | Empty | Unary; honored only when `ENABLE_MANUAL_FLUSH=true` (non-production). |

### Serialization & framing
- **Records (`Ingest`)** — the POJO is serialized to **CBOR** via Jackson `CBORFactory`. The application-layer payload keeps the per-record shape `[u16 table_name_len][table_name UTF-8][CBOR bytes]`; gRPC supplies the message framing that v1's `[4-byte length]` prefix provided.
- **Schemas (`RegisterSchema`)** stay **JSON** — off the hot path.
- **Payload cap** — 16 MB per record at both SDK and engine. (A 16 MB monolithic CBOR float array can expand into 200+ MB of `serde_json::Value` DOM in the engine's `arrow-json` parse step.) See [system-overview.md §2.3](system-overview.md).

### Lifecycle & failure modes
- **Pipeline unreachable at startup:** `RegisterSchema` retries with exponential backoff for `MICEWRITER_REGISTER_RETRY_SECONDS` (default 30s), then proceeds; the first `sendAsyncWithRetry()` per affected table retries registration before its first record.
- **Pipeline unreachable during a send:** bounded retry with exponential backoff for `MICEWRITER_SEND_RETRY_SECONDS` (default 30s), then the future completes exceptionally with the unresolvable table named. **No unbounded SDK buffering** (preserves the JVM-heap-pressure guarantee).
- **Whole-pipeline outage:** sends to that table fail fast after the retry budget; other tables' pipelines are unaffected.

### Auth
Default: **plain gRPC over the cluster network** — the chart ships with no auth requirement. For zero-trust adopters, mTLS is added as a service-mesh overlay (Istio / Linkerd `PeerAuthentication` + `DestinationRule`) **without SDK changes**.

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

### Timestamp serialization
Fields mapped to Iceberg `timestamptz` columns are encoded as ISO-8601 strings (Jackson is configured with `WRITE_DATES_AS_TIMESTAMPS=false`). The engine transpiles CBOR → NDJSON and parses with `arrow-json`, which accepts numeric UTC offsets (`Z` or `+HH:MM`) but rejects named timezones like `"UTC"` or bracketed zone suffixes like `2026-05-30T07:30Z[UTC]`. Safe field types: `java.time.Instant` (always `...Z`) and `java.time.OffsetDateTime` (numeric offset). Avoid `java.time.ZonedDateTime` for `timestamptz` columns — convert to `Instant`/`OffsetDateTime` at the entity boundary.

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
  resolver: "engine-{table}.micewriter.svc:9090"
  base-package: com.example.events   # narrows @IcebergEntity classpath scan
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
  resolver: "engine-{table}.micewriter.svc:9090"
```

## 🕰️ v1 Transport: UDS + JSON

> This section documents the **v1 (`1.x.x`)** publish path for adopters still on per-pod sidecars. v2 keeps the same SDK surface — `@IcebergEntity`, `@IcebergId`, and `IcebergStreamTemplate.sendAsyncWithRetry(pojo)` — but changes how records leave the JVM (gRPC + CBOR instead of UDS + JSON).

In v1, `IcebergStreamTemplate` serializes the POJO to **JSON** and sends it as an `INGEST_RECORD` over a **Unix Domain Socket** managed by `UdsConnection` (Netty Epoll, Linux only). If the engine sidecar restarts and drops the socket, `UdsConnection` reconnects lazily on the next send (`ensureConnected()`) and `SchemaRegistrar` re-registers all known schemas.

Every message over the v1 UDS has this layout:

```
[4-byte big-endian length][1-byte msg type][payload bytes]
```

| Message | Type byte | Payload encoding |
|---|---|---|
| `REGISTER_SCHEMA` | `0x01` | JSON `{ table, namespace, fields }` |
| `INGEST_RECORD` | `0x02` | `[table_name_len u16][table_name UTF-8][JSON bytes]` |
| `FLUSH_NOW`       | `0x03` | `[Empty Payload]` |
| ACK (engine → SDK) | — | JSON `{ status: "ok"\|"error", msg? }` |

v1 apps configure a `socket-path` (Spring `socket-path` / Dropwizard `socketPath`, e.g. `/var/run/app/iceberg.sock`) plus `connect-timeout-ms` and `ack-timeout-ms`, instead of the v2 `resolver`.

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
