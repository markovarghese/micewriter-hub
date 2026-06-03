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
* **The Catastrophic Failure**:
  At 100 MB/sec, the active CF fills up incredibly fast. Depending on what random rotation limit was generated (between 24 MB and 40 MB), the system will fail in one of two ways:
  
  **Outcome A: The Deadlock (Rotation limit > 32 MB, e.g., 36 MB)**
  1. The active CF reaches 32 MB in 0.32 seconds.
  2. The `total_unflushed_bytes` hits 32 MB. The backpressure logic kicks in, rejecting all incoming IPC messages.
  3. Because the active CF is only 32 MB, it hasn't reached its 36 MB rotation limit. It never triggers a flush!
  4. The engine completely deadlocks. It rejects all traffic for up to 10 minutes until the periodic timer wakes up to flush the stuck buffer.

  **Outcome B: Severe Throttling (Rotation limit < 32 MB, e.g., 24 MB)**
  1. The active CF hits 24 MB in 0.24 seconds. The Engine rotates the CF and triggers a background flush.
  2. The active CF is now 0 MB, but the frozen CF is 24 MB. `total_unflushed_bytes` = 24 MB.
  3. The Engine has only 8 MB of "headroom" left. 0.08 seconds later, the new active CF hits 8 MB. `total_unflushed_bytes` hits 32 MB.
  4. Backpressure kicks in, rejecting all traffic. The host app is completely blocked while the Engine spends seconds compiling, uploading to S3, and committing the 24 MB frozen CF.
  5. Once the flush finishes, the frozen CF is dropped, and 24 MB of buffer frees up, only to be filled and throttled again a quarter-second later.

![Scenario 2 Sequence Diagram](./diagrams/scenario2.drawio.svg)

---

## 4. Proposed Fix

To resolve the backpressure flaw, the Engine's `max_unflushed_bytes` limit in `uds_server.rs` must be decoupled from `flush_size_bytes`. By setting the backpressure limit to something like `config.flush_size_bytes * 4` (e.g., 128 MB), the Engine can comfortably hold one active CF and up to three frozen CFs (`MAX_RETAINED_FROZEN_CFS`), allowing it to absorb high-throughput spikes while background flush tasks execute.
