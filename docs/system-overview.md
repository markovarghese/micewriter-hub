# System Overview

This document outlines the core architecture and data flows for the distributed Iceberg ingestion pipeline.

## 1. Global Architecture & Topology

The system operates entirely within the Kubernetes pod networking boundary, ensuring zero network latency for the business application during data emission. The architecture uses a sidecar pattern to decouple the application JVM from storage operations.

```mermaid
sequenceDiagram
    autonumber
    participant App as Spring Boot App (JVM)
    participant SDK as Iceberg JVM SDK
    participant UDS as Unix Domain Socket
    participant Sidecar as Rust Sidecar Engine
    participant RocksDB as Local RocksDB (PVC)
    participant Nessie as Iceberg Catalog (Nessie)
    participant MinIO as S3 Storage (MinIO)

    Note over App,SDK: Startup & Registration Phase
    SDK->>Sidecar: Register Schema (REGISTER_SCHEMA payload)
    Sidecar->>Nessie: Query/Create Iceberg Table
    Nessie-->>Sidecar: Table Ready / Exists

    Note over App,RocksDB: Hot-Path Ingestion Phase (Microsecond Latency)
    App->>SDK: icebergTemplate.send(pojo)
    SDK->>SDK: Serialize POJO to Protobuf/Bincode
    SDK->>UDS: Write serialized payload (length-prefixed)
    UDS->>Sidecar: Read payload bytes
    Sidecar->>RocksDB: Async zero-copy append to active Column Family
    Sidecar-->>SDK: Acknowledge IPC response

    Note over Sidecar,MinIO: Jittered 10-Minute Flush Cycle
    Sidecar->>Sidecar: Jitter timer fires, rotate RocksDB Column Family
    Sidecar->>RocksDB: Read frozen Column Family records
    Sidecar->>Sidecar: Compile records to Parquet & puffin deletion vectors
    Sidecar->>MinIO: Upload Parquet files (S3 API)
    Sidecar->>Nessie: Atomic commit append to Iceberg Table
    Sidecar->>RocksDB: Purge frozen Column Family
```

## 2. Unix Domain Socket (UDS) Protocol & IPC

Communication between the Spring Boot SDK and the Rust sidecar occurs over a shared Unix Domain Socket located at `/var/run/app/iceberg.sock`.

### 2.1 Packet Structure
All IPC messages use a standard 4-byte big-endian length prefix framing protocol to ensure the Rust Tokio runtime can efficiently read complete messages off the stream without blocking.
- **Bytes [0-3]:** Total Message Length `N` (Unsigned 32-bit Integer, Big Endian)
- **Bytes [4 to N+4]:** The serialized payload.

### 2.2 Serialization
- **Schemas:** Handshake messages (`REGISTER_SCHEMA`) are sent as JSON.
- **Telemetry Records:** Hot-path ingestion records (`INGEST_RECORD`) are serialized via Bincode or Protobuf before transmission to ensure maximum throughput and minimal allocation overhead.

## 3. The Flush Cycle & Graceful Shutdown

To consolidate small records into optimized Iceberg v3 Parquet files while protecting the Catalog API from rate limits (the "Thundering Herd" problem):

- **Jittered Column Family Swap:** The Rust cron thread wakes up on a randomized (jittered) schedule (e.g., 10 minutes ± 2 minutes). It swaps incoming traffic to a new RocksDB Column Family, freezing the old one.
- **Compilation:** The frozen records are compiled into Parquet and `.puffin` files.
- **Catalog Commit:** The sidecar uploads files to S3 (MinIO) and executes an atomic commit to Nessie. On `CommitFailedException` (optimistic locking failure), it uses an exponential backoff retry.
- **SIGTERM Emergency Flush:** If Kubernetes initiates pod termination, the sidecar intercepts the `SIGTERM` signal, pauses new ingestion, forces an immediate compilation/commit of remaining RocksDB data, and exits safely.
