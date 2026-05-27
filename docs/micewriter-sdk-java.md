# ☕ micewriter-sdk-java
> 🌐 Part of the **[mIceWriter Telemetry Ingestion Ecosystem](file:///c:/Users/marko/source/repos/micewriter-hub/README.md)**

[![Ecosystem: mIceWriter](https://img.shields.io/badge/Ecosystem-mIceWriter-blueviolet?style=flat-square)](file:///c:/Users/marko/source/repos/micewriter-hub/README.md)
[![Component: Java SDK](https://img.shields.io/badge/Component-Java%20SDK-blue?style=flat-square)](#)

This repository contains the Library/SDK that product developers use to interface with the `micewriter-engine` sidecar.
It is a **Maven multi-module project** that ships three artifacts from a single repo:

| Module | Artifact | Use when |
|---|---|---|
| **core** | `micewriter-sdk-java-core` | Framework-agnostic base — used transitively by both starters |
| **spring** | `micewriter-sdk-java-spring` | Spring Boot applications |
| **dropwizard** | `micewriter-sdk-java-dropwizard` | Dropwizard applications |

## 🛠️ Core Technology Stack
- **Language:** Java 17
- **Framework support:** Spring Boot AutoConfiguration **and** Dropwizard 4.x Bundle
- **Serialization:** Apache Arrow IPC (RecordBatch stream format)
- **Network IO:** Netty Epoll (UDS communication — Linux only)

## ⚙️ Functionality

This library abstracts away the IPC complexity so business developers just write standard Java code.

1. **Annotations:** Provides `@IcebergEntity` and `@IcebergId` to demarcate domain objects (POJOs) that should be ingested. These are in the `core` module and are framework-agnostic.

2. **Schema registration:** On startup, `SchemaRegistrar` sends one `REGISTER_SCHEMA` (0x01) JSON message per `@IcebergEntity` class, telling the engine to prepare the Iceberg table.
   - *Spring Boot*: scans the classpath automatically via `SpringSchemaRegistrar` on `ContextRefreshedEvent`; bounded by `micewriter.base-package`.
   - *Dropwizard*: entity classes are declared explicitly via `MicewriterBundle.entities(...)` because Dropwizard provides no classpath scanner.

3. **`IcebergStreamTemplate`:** Exposes a `.send(pojo)` method that serializes the object into **Apache Arrow IPC RecordBatch** bytes and sends it as an `INGEST_RECORD` (0x02) message over the Unix Domain Socket. Blocks until the engine ACKs the RocksDB write (typically microseconds). The template is:
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
| `INGEST_RECORD` | `0x02` | `[table_name_len u16][table_name UTF-8][schema_id i32=0][Arrow IPC stream]` |
| ACK (engine → SDK) | — | JSON `{ status: "ok"\|"error", msg? }` |

## 🏗️ Spring Boot Usage

Add the starter dependency — it auto-configures everything via `META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports`:

```xml
<dependency>
    <groupId>com.micewriter</groupId>
    <artifactId>micewriter-sdk-java-spring</artifactId>
    <version>0.2.0</version>
</dependency>
```

```java
@IcebergEntity(table = "telemetry_events", namespace = "analytics")
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
  enabled: true
```

## 🏗️ Dropwizard Usage

Add the bundle dependency — entity classes must be listed explicitly:

```xml
<dependency>
    <groupId>com.micewriter</groupId>
    <artifactId>micewriter-sdk-java-dropwizard</artifactId>
    <version>0.2.0</version>
</dependency>
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
Three compiled `.jar` files released together at the same version, published to Maven Central, an internal Nexus/Artifactory, or Maven Local.

---
### 🔗 The mIceWriter Ecosystem
* **Architecture Hub:** [micewriter-hub](file:///c:/Users/marko/source/repos/micewriter-hub/README.md)
* **System Overview:** [system-overview](file:///c:/Users/marko/source/repos/micewriter-hub/docs/system-overview.md)
* **Rust Sidecar Engine:** [micewriter-engine](file:///c:/Users/marko/source/repos/micewriter-hub/docs/micewriter-engine.md)
* **Spring Boot SDK:** [micewriter-sdk-java](file:///c:/Users/marko/source/repos/micewriter-hub/docs/micewriter-sdk-java.md)
* **Kubernetes Webhook:** [micewriter-k8s-injector](file:///c:/Users/marko/source/repos/micewriter-hub/docs/micewriter-k8s-injector.md)
* **Local Data Lake Mock:** [micewriter-local-infra](file:///c:/Users/marko/source/repos/micewriter-hub/docs/micewriter-local-infra.md)
* **Reference Testing App:** [micewriter-sandbox](file:///c:/Users/marko/source/repos/micewriter-hub/docs/micewriter-sandbox.md)
