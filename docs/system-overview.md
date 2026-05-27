# 🌐 System Overview
> 🌐 Part of the **[mIceWriter Telemetry Ingestion Ecosystem](file:///c:/Users/marko/source/repos/micewriter-hub/README.md)**

[![Ecosystem: mIceWriter](https://img.shields.io/badge/Ecosystem-mIceWriter-blueviolet?style=flat-square)](file:///c:/Users/marko/source/repos/micewriter-hub/README.md)
[![Component: System Overview](https://img.shields.io/badge/Component-System%20Overview-lightgrey?style=flat-square)](#)

This document outlines the core architecture and data flows for the distributed mIceWriter telemetry ingestion pipeline.

## 1. Global Architecture & Topology

The system operates entirely within the Kubernetes pod networking boundary, ensuring zero network latency for the business application during data emission. The architecture uses a sidecar pattern to decouple the application JVM from storage operations.

```mermaid
sequenceDiagram
    autonumber
    participant App as Java App (Spring Boot / Dropwizard)
    participant SDK as mIceWriter SDK (Java)
    participant UDS as Unix Domain Socket
    participant Engine as mIceWriter Engine (Rust)
    participant RocksDB as Local RocksDB (PVC)
    participant Catalog as Nessie / Glue Catalog (API)
    participant ObjectStore as S3 Storage (MinIO / AWS S3)

    Note over App,SDK: Startup & Registration Phase
    SDK->>Engine: Register Schema (REGISTER_SCHEMA payload)
    Engine->>Catalog: Query/Create Iceberg Table
    Catalog-->>Engine: Table Ready / Exists

    Note over App,RocksDB: Hot-Path Ingestion Phase (Microsecond Latency)
    App->>SDK: icebergTemplate.send(pojo)
    SDK->>SDK: Serialize POJO to Arrow IPC RecordBatch
    SDK->>UDS: Write Arrow IPC payload (length-prefixed)
    UDS->>Engine: Read payload bytes
    Engine->>RocksDB: Async zero-copy append to active Column Family
    Engine-->>SDK: Acknowledge IPC response

    Note over Engine,MinIO: Jittered 10-Minute Flush Cycle
    Engine->>Engine: Jitter timer fires, rotate RocksDB Column Family
    Engine->>RocksDB: Read frozen Column Family records
    Engine->>Engine: Compile records to Parquet
    Engine->>ObjectStore: Upload Parquet files (S3 API)
    Engine->>Catalog: Atomic commit append to Iceberg Table
    Engine->>RocksDB: Purge frozen Column Family
```

## 2. Unix Domain Socket (UDS) Protocol & IPC

Communication between the `micewriter-sdk-java` and the `micewriter-engine` occurs over a shared Unix Domain Socket located at `/var/run/app/iceberg.sock`.

### 2.1 Packet Structure
All IPC messages use a standard 4-byte big-endian length prefix framing protocol to ensure the Rust Tokio runtime can efficiently read complete messages off the stream without blocking.
- **Bytes [0-3]:** Total Message Length `N` (Unsigned 32-bit Integer, Big Endian)
- **Bytes [4 to N+4]:** The serialized payload.

### 2.2 Serialization
- **Schemas:** Handshake messages (`REGISTER_SCHEMA`) are sent as JSON.
- **Telemetry Records:** Hot-path ingestion records (`INGEST_RECORD`) are streamed as native **Apache Arrow IPC** bytes. This entirely eliminates JSON parsing overhead in the sidecar and guarantees perfect type fidelity. The payload size is capped at 128 MB to prevent OOM attacks.

## 3. The Flush Cycle & Graceful Shutdown

To consolidate small records into optimized Iceberg v3 Parquet files while protecting the Catalog API from rate limits (the "Thundering Herd" problem):

- **Jittered Column Family Swap:** The Rust cron thread wakes up on a randomized (jittered) schedule (e.g., 10 minutes ± 2 minutes). It swaps incoming traffic to a new RocksDB Column Family, freezing the old one.
- **Compilation:** The frozen records (Arrow IPC) are compiled into Parquet files. Note: The engine performs fast, append-only operations; Puffin deletion vectors and row-level updates are deferred to asynchronous Iceberg maintenance jobs.
- **Catalog Commit:** The sidecar uploads files to S3 (MinIO or AWS S3) and executes an atomic commit to the configured catalog (Nessie or AWS Glue). On `CommitFailedException` (optimistic locking failure), it uses an exponential backoff retry.
- **SIGTERM Emergency Flush:** If Kubernetes initiates pod termination, the sidecar intercepts the `SIGTERM` signal, pauses new ingestion, forces an immediate compilation/commit of remaining RocksDB data, and exits safely.

## 4. Downstream Analytics Readers

This architecture intentionally abstracts away **read-after-write** capabilities from the emitting Spring Boot application. The system is fundamentally split into two optimized domains:

1. **Write Optimization:** The application achieves microsecond write latency via UDS and local RocksDB caching, completely insulated from cloud API latency.
2. **Read Optimization:** Distributed query engines (e.g., **Trino, Querybook, Athena, Spark**) require large, columnar files to execute analytical queries efficiently. By delaying the Iceberg catalog commit until the sidecar has compiled 10 minutes worth of telemetry into large Parquet files, downstream analytics platforms are saved from the catastrophic performance degradation of scanning millions of tiny S3 files.

---
### 🔗 The mIceWriter Ecosystem
* **Architecture Hub:** [micewriter-hub](file:///c:/Users/marko/source/repos/micewriter-hub/README.md)
* **System Overview:** [system-overview](file:///c:/Users/marko/source/repos/micewriter-hub/docs/system-overview.md)
* **Rust Sidecar Engine:** [micewriter-engine](file:///c:/Users/marko/source/repos/micewriter-hub/docs/micewriter-engine.md)
* **Java SDK:** [micewriter-sdk-java](file:///c:/Users/marko/source/repos/micewriter-hub/docs/micewriter-sdk-java.md)
* **Kubernetes Webhook:** [micewriter-k8s-injector](file:///c:/Users/marko/source/repos/micewriter-hub/docs/micewriter-k8s-injector.md)
* **Local Data Lake Mock:** [micewriter-local-infra](file:///c:/Users/marko/source/repos/micewriter-hub/docs/micewriter-local-infra.md)
* **Reference Testing App:** [micewriter-sandbox](file:///c:/Users/marko/source/repos/micewriter-hub/docs/micewriter-sandbox.md)
