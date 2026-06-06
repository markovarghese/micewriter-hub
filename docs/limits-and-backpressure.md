# System Limits and Backpressure

This document explains the limits applied by the `micewriter-sdk` and `micewriter-engine` as telemetry data flows from the host application to the Iceberg tables. It outlines the intentional constraints and the mechanisms for backpressure.

> [!NOTE]
> For a mathematical derivation of how these limits translate into expected system throughput, see the [Effective Throughput Model](throughput-model.md).

## 1. Intentional Limits

### SDK & IPC Payload Limit (16 MB)
Both the Java SDK and the Rust Engine enforce a strict `MAX_PAYLOAD_BYTES` limit of **16 MB** for any single IPC message (`INGEST_RECORD`). 
* If a single POJO serializes to > 16 MB, the SDK throws an `IllegalArgumentException` and drops the message before sending it over the Unix Domain Socket.
* If the Engine receives an IPC frame larger than 16 MB, it drops the connection to prevent memory exhaustion attacks.

### RocksDB Write Batching Limits
To efficiently persist incoming IPC records, the UDS server opportunistically batches messages before appending them to the active RocksDB column family. A write batch is flushed to disk when it reaches either:
* **`WRITE_BATCH_MAX`**: **1,000 records**.
* **`MAX_PAYLOAD_SIZE`**: **16 MB** total payload bytes.
This maximizes RocksDB throughput while preventing OOM crashes on bursts of large payloads.

### Engine Compilation Limits
During the flush cycle, the Engine reads the raw JSON bytes from a frozen RocksDB column family and compiles them into Arrow/Parquet. To prevent out-of-memory (OOM) crashes on massive tables, it buffers data into chunks before writing to the `ArrowWriter`:
* **`flush_compile_batch_size`**: Default **1,000 records**.
* **`flush_compile_batch_bytes`**: Dynamically scaled to **~1% of the pod memory limit per CPU core** (e.g., ~1.28 MB per thread on a 512MiB, 4-thread pod).
Whichever limit is hit first forces the Engine to flush the current Arrow batch to Parquet and clear its memory buffers.

### Flush Intervals
Data is normally flushed based on a jittered cron loop to prevent all microservices from hitting the S3/Nessie catalog simultaneously.
* **Base Interval**: 5 minutes (`FLUSH_INTERVAL_SECS` = 300)
* **Jitter**: ± 1 minute (`FLUSH_JITTER_SECS` = 60)
* A flush cycle rotates the active RocksDB column family, compiles all frozen CFs, uploads to MinIO, and commits to Nessie.

## 2. RocksDB Rotation & Backpressure Limits

The Engine buffers incoming IPC messages in a durable local RocksDB "active" Column Family. To prevent this buffer from growing indefinitely between periodic flushes, the engine defines a size limit:
* **`flush_size_bytes`**: Default **32 MB**.
* **`flush_size_jitter_bytes`**: Default **8 MB**.

When the active CF size exceeds a randomized threshold between **24 MB** and **40 MB** (jitter), the engine rotates the CF (freezing it) and immediately triggers an asynchronous flush. 

To protect the Engine's memory without unnecessarily throttling the host application, the engine enforces two global backpressure limits:
* **Retained CF Count**: Reject traffic if the number of frozen CFs pending flush reaches `MAX_RETAINED_FROZEN_CFS` (default 8).
* **Total Unflushed Bytes**: Reject traffic if the exact byte size of all uncompiled records (active + frozen) exceeds `config.flush_size_bytes * (1 + MAX_RETAINED_FROZEN_CFS)` (e.g., 288 MB).

Because the Retained CF Count triggers the moment the 8th CF is frozen, the active CF is entirely blocked from accepting new data. Therefore, the system effectively hits backpressure at exactly the size of 8 frozen CFs (expected **~256 MB**), making the 288 MB limit a fallback shadow limit.

---

## 3. Scenarios Walkthrough

![Data Flow Architecture](./diagrams/data-flow.drawio.svg)

To understand the impact of the limits and the backpressure bug, let's explore two throughput scenarios.

### Scenario 1: Low Throughput (1 KB events at 10 events/sec)

* **Throughput**: 10 KB / sec (0.6 MB / minute).
* **Payload Limit**: 1 KB is well under the 16 MB limit.
* **Rotation**: In 5 minutes, the active CF accumulates ~3 MB of data. This is far below the 24–40 MB rotation limit, so size-based rotation never triggers.
* **Flush Phase**: The periodic timer wakes up every ~4–6 minutes, rotates the 3 MB active CF, and compiles it. The compile batch limits process records in dynamically sized batches, keeping memory safely bounded.
* **Backpressure**: During the flush, `total_unflushed_bytes` is 3 MB (frozen) + 0 MB (new active). This is well below the 288 MB backpressure limit. 
* **Result**: The system runs flawlessly, efficiently batching events and committing them to Iceberg without ever applying backpressure to the host app.

```mermaid
sequenceDiagram
    participant App as Host App
    participant SDK as micewriter-sdk
    participant UDS as UDS Server
    participant ActiveCF as RocksDB Active CF
    participant Flush as Flush Engine
    participant Iceberg
    App->>SDK: Send 1 KB event (10/sec)
    SDK->>UDS: IPC Message (1 KB)
    UDS->>ActiveCF: Append (Total unflushed under 32 MB)
    ActiveCF-->>UDS: OK
    UDS-->>SDK: AckResponse::ok()
    Note over ActiveCF,Flush: In 10 mins, Active CF reaches 6 MB
    Flush->>ActiveCF: Periodic 10 min Timer Fires
    Flush->>ActiveCF: Rotate Active CF -> Frozen CF
    Note over ActiveCF,Flush: Total unflushed = 6 MB. No backpressure.
    Flush->>Iceberg: Compile and Commit Parquet
    Iceberg-->>Flush: Success
    Flush->>ActiveCF: Drop Frozen CF
```

### Scenario 2: High Throughput (1 MB events at 100 MB/sec)

* **Throughput**: 100 MB / sec.
* **Payload Limit**: 1 MB is under the 16 MB limit.
* **The Reality (Dynamic Hardware-Aware Pipelining)**:
  At 100 MB/sec, the active CF hits its 32 MB limit and rotates every ~0.3 seconds. The background `flush_engine` uses a 4-stage pipelined architecture to parse the data and concurrently upload multiple Parquet chunks to MinIO via a `JoinSet`. The engine automatically scales its thread pool to saturate available CPU cores, dynamically sizing memory limits to prevent overflow. Even on highly-constrained pods, the pipeline reaches ~60-65 MB/s.
* **Healthy Backpressure in Action**:
  1. Because the host application generates data faster (100 MB/s) than the engine can process it (~62 MB/s), the engine begins accumulating frozen CFs.
  2. Within ~6.7 seconds, the `MAX_RETAINED_FROZEN_CFS` limit of 8 (and the 288 MB shadow limit) is hit.
  3. The engine begins rejecting IPC requests with a "backpressure" error. The SDK catches these and gracefully drops the excess events.
  4. The host application continues to run without experiencing OOM crashes or thread-pool exhaustion!
* **Result**: The engine smoothly sustains ~62 MB/s of ingestion without dropping the pod, gracefully shedding the excess 38 MB/s load via backpressure.

```mermaid
sequenceDiagram
    participant App as Host App
    participant SDK as micewriter-sdk
    participant UDS as UDS Server
    participant ActiveCF as RocksDB Active CF
    participant Flush as Flush Engine
    App->>SDK: Send 1 MB events (100 MB/s)
    SDK->>UDS: IPC Messages (1 MB)
    UDS->>ActiveCF: Append
    Note over ActiveCF,Flush: Active CF hits 32 MB and rotates
    Flush->>Flush: Dynamic Multi-Threaded Pipeline
    Note over ActiveCF,Flush: Pipeline drains data at ~62 MB/s
    App->>SDK: Send next 1 MB event
    SDK->>UDS: IPC Message
    Note over UDS: Retained CF limit is hit (288 MB backlog)!
    UDS-->>SDK: AckResponse::error(backpressure)
    SDK-->>App: Drop event (graceful degradation)
    Note over App,UDS: Host app avoids OOM.
    Flush->>Flush: Concurrent S3 uploads complete
    Flush->>ActiveCF: Drops oldest Frozen CF
    App->>SDK: Next event (Accepted)
```
