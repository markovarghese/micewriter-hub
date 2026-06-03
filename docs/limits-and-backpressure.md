# System Limits and Backpressure

This document explains the limits applied by the `micewriter-sdk` and `micewriter-engine` as telemetry data flows from the host application to the Iceberg tables. It outlines the intentional constraints, the mechanisms for backpressure, and a critical flaw in the current backpressure implementation.

## 1. Intentional Limits

### SDK & IPC Payload Limit (16 MB)
Both the Java SDK and the Rust Engine enforce a strict `MAX_PAYLOAD_BYTES` limit of **16 MB** for any single IPC message (`INGEST_RECORD`). 
* If a single POJO serializes to > 16 MB, the SDK throws an `IllegalArgumentException` and drops the message before sending it over the Unix Domain Socket.
* If the Engine receives an IPC frame larger than 16 MB, it drops the connection to prevent memory exhaustion attacks.

### Engine Compilation Limits
During the flush cycle, the Engine reads the raw CBOR bytes from a frozen RocksDB column family and compiles them into Arrow/Parquet. To prevent out-of-memory (OOM) crashes on massive tables, it buffers data into chunks before writing to the `ArrowWriter`:
* **`flush_compile_batch_size`**: Default **1,000 records**.
* **`flush_compile_batch_bytes`**: Default **4 MB** (uncompressed CBOR).
Whichever limit is hit first forces the Engine to flush the current Arrow batch to Parquet and clear its memory buffers.

### Flush Intervals
Data is normally flushed based on a jittered cron loop to prevent all microservices from hitting the S3/Nessie catalog simultaneously.
* **Base Interval**: 10 minutes (`FLUSH_INTERVAL_SECS` = 600)
* **Jitter**: ± 2 minutes (`FLUSH_JITTER_SECS` = 120)
* A flush cycle rotates the active RocksDB column family, compiles all frozen CFs, uploads to MinIO, and commits to Nessie.

## 2. RocksDB Rotation & Backpressure Flaw

The Engine buffers incoming IPC messages in a durable local RocksDB "active" Column Family. To prevent this buffer from growing indefinitely between periodic flushes, the engine defines a size limit:
* **`flush_size_bytes`**: Default **32 MB**.
* **`flush_size_jitter_bytes`**: Default **8 MB**.

When the active CF size exceeds a randomized threshold between **24 MB** and **40 MB**, the engine rotates the CF (freezing it) and immediately triggers an asynchronous flush. 

However, there is a **catastrophic bug** in the backpressure logic (`uds_server.rs`). The engine is designed to reject incoming traffic if the total unflushed buffer grows too large. It checks if the `total_unflushed_bytes` (which includes *both* the active CF and all frozen CFs) exceeds `config.flush_size_bytes` (exactly 32 MB). 

Because the rotation limit and the backpressure limit are mathematically the same (around 32 MB), the system has **zero or negative headroom** to absorb traffic while the background flush task runs.

---

## 3. Scenarios Walkthrough

![Data Flow Architecture](./diagrams/data-flow.drawio.svg)

To understand the impact of the limits and the backpressure bug, let's explore two throughput scenarios.

### Scenario 1: Low Throughput (1 KB events at 10 events/sec)

* **Throughput**: 10 KB / sec (0.6 MB / minute).
* **Payload Limit**: 1 KB is well under the 16 MB limit.
* **Rotation**: In 10 minutes, the active CF accumulates ~6 MB of data. This is far below the 24–40 MB rotation limit, so size-based rotation never triggers.
* **Flush Phase**: The periodic timer wakes up every ~8–12 minutes, rotates the 6 MB active CF, and compiles it. The compile batch limits process 1000 records (1 MB) at a time, keeping memory low.
* **Backpressure**: During the flush, `total_unflushed_bytes` is 6 MB (frozen) + 0 MB (new active). This is well below the 32 MB backpressure limit. 
* **Result**: The system runs flawlessly, efficiently batching events and committing them to Iceberg without ever applying backpressure to the host app.

![Scenario 1 Sequence Diagram](./diagrams/scenario1.drawio.svg)

### Scenario 2: High Throughput (1 MB events at 100 MB/sec)

* **Throughput**: 100 MB / sec.
* **Payload Limit**: 1 MB is under the 16 MB limit.
* **The Reality (I/O Bottleneck)**:
  At 100 MB/sec, the active CF hits its 32 MB limit and rotates every ~0.3 seconds.
  However, the background `flush_engine` takes several seconds to compile 32 MB of CBOR into Parquet, upload it to MinIO, and commit it to Nessie.
* **Backpressure in Action**:
  1. The engine rapidly accumulates 3 frozen CFs (roughly 96 MB).
  2. As the new active CF fills, `total_unflushed_bytes` hits the 128 MB global backpressure limit (`32 MB * (1 + 3 frozen CFs)`).
  3. The Engine gracefully enters backpressure and rejects incoming IPC messages.
  4. The host application is throttled (receives IPC errors) but the sidecar's memory is perfectly protected from OOM-killing.
* **Result**: The engine sustainably flushes at its maximum possible I/O speed (~15-20 MB/sec depending on CPU/network) and safely rejects the excess 80 MB/sec of traffic.

![Scenario 2 Sequence Diagram](./diagrams/scenario2.drawio.svg)

---

## 4. Fix Implemented

The catastrophic deadlock bug in `uds_server.rs` has been patched. The Engine's `max_unflushed_bytes` limit is now properly decoupled from `flush_size_bytes` by factoring in the `MAX_RETAINED_FROZEN_CFS` setting (default 3). 

This safely raises the backpressure limit to 128 MB (for a 32 MB flush size), allowing the engine to comfortably hold one active CF and up to three frozen CFs. This grants it the headroom to absorb high-throughput spikes while background flush tasks execute, ensuring predictable throttling instead of deadlocks.
