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
The SDK maintains two active release lines depending on your infrastructure:
- **`2.x.x` (main branch)**: Uses **gRPC over HTTP/2** for central per-table pipelines.
- **`1.x.x` (v1 branch)**: Uses **Unix Domain Sockets (UDS)** for per-pod sidecars.

## 🛠️ Core Technology Stack
- **Language:** Java 25
- **Framework support:** Spring Boot AutoConfiguration **and** Dropwizard 4.x Bundle
- **Serialization:** JSON via Jackson `ObjectMapper` (streamed directly into the UDS frame buffer)
- **Network IO:** Netty Epoll (UDS communication — Linux only)

## ⚙️ Functionality

This library abstracts away the IPC complexity so business developers just write standard Java code.

1. **Annotations:** Provides `@IcebergEntity` and `@IcebergId` to demarcate domain objects (POJOs) that should be ingested. These are in the `core` module and are framework-agnostic.

2. **Schema registration:** On startup, `SchemaRegistrar` sends one `REGISTER_SCHEMA` (0x01) JSON message per `@IcebergEntity` class, telling the engine to prepare the Iceberg table.
   - *Spring Boot*: scans the classpath automatically via `SpringSchemaRegistrar` on `ContextRefreshedEvent`; bounded by `micewriter.base-package`.
   - *Dropwizard*: entity classes are declared explicitly via `MicewriterBundle.entities(...)` because Dropwizard provides no classpath scanner.

3. **`IcebergStreamTemplate`:** The primary ingest API, with two send modes that both serialize the POJO to **JSON** streamed straight into the `INGEST_RECORD` (0x02) frame:
   - **`.send(pojo)`** — *blocking*. Waits for the engine ACK before returning, so a single calling thread keeps only one record in flight. Simple, but latency-bound: for 1 MB payloads a single thread tops out at **~100 records/s** regardless of the offered rate.
   - **`.sendAsync(pojo)`** — *pipelined*. Returns a `CompletableFuture<Void>` and keeps many frames in flight (ACK ordering preserved by a FIFO queue), lifting the single-caller ceiling well past the synchronous limit (**measured ~5×** for 1 MB payloads). Host memory is bounded by a configurable **in-flight byte budget** (`max-in-flight-bytes`, default **8 MiB**): the caller blocks only when the window is full — which is also how the SDK applies *client-side* backpressure. Errors (timeout, channel drop, engine rejection) complete the future exceptionally rather than throwing on the caller. See [System Limits and Backpressure](limits-and-backpressure.md).

   The template is:
   - A Spring `@Bean` in Spring Boot apps (injected with `@Autowired`).
   - Retrieved via `MicewriterBundle.getTemplate()` in Dropwizard apps.

4. **Lifecycle management:**
   - *Spring Boot*: `UdsConnection` is a bean managed by the Spring context; closed on context shutdown.
   - *Dropwizard*: connection open/close is handled by a `Managed` object registered by `MicewriterBundle`.

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
        icebergTemplate.send(event);
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
  max-in-flight-bytes: 8388608       # 8 MiB client-side in-flight window for sendAsync()
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
  maxInFlightBytes: 8388608   # 8 MiB client-side in-flight window for sendAsync()
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
