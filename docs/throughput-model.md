# Micewriter Effective Throughput Model

Based on the architecture of the `micewriter-engine` and `micewriter-sdk`, the system behaves mathematically as a **Leaky Bucket** with a strictly capped payload size. 

Here is the formula to calculate the system's average effective throughput ($R_{eff}$) in messages per second.

## 1. Variables

### Workload Variables
* **$R_{in}$** : Input rate (attempted messages / second)
* **$S_{msg}$** : Average message payload size (bytes)
* **$T_{test}$** : Duration of the observation/load window (seconds)

### System Limit Variables
* **$L_{payload}$** : `MAX_PAYLOAD_BYTES` (16 MB limit per message)
* **$L_{flush}$** : `flush_size_bytes` (Target active CF rotation size, e.g., 32 MB)
* **$N_{frozen}$** : `MAX_RETAINED_FROZEN_CFS` (Max pending flushes, e.g., 3)
* **$R_{io}$** : **Background I/O Rate** (bytes / second). This is the speed at which the `flush_engine` can parse CBOR, compress Parquet, and upload to MinIO. Thanks to the new 4-stage multithreaded pipeline, parsing runs concurrently across the Tokio thread pool. However, this is heavily bounded by the engine pod's CPU limit (currently `500m`). Empirical load testing demonstrates $R_{io}$ converges to **~13.4 - 16 MB/sec** under a half-core constraint.

## 2. Buffer Capacity ($C_{max}$) & Jitter
Before backpressure is applied, the engine buffers data in local RocksDB column families. 

While there is a hard global bytes limit ($L_{flush} \times (1 + N_{frozen})$ = 128 MB), the code in `uds_server.rs` actually triggers backpressure the moment the number of frozen CFs reaches $N_{frozen}$ (`retained >= max_retained_frozen_cfs`). Because of this, the active CF is not allowed to fill up once $N_{frozen}$ is reached!

Furthermore, rotation sizes are subject to **Jitter** (`flush_size_jitter_bytes` = 8 MB). Each CF rotates at a uniformly random size between 24 MB and 40 MB. Because the true buffer capacity $C_{max}$ is the sum of $N_{frozen}$ random variables, it follows an Irwin-Hall distribution. However, for calculating *average* throughput over a time window, we use the expected value (mean):

$$ E[C_{max}] = L_{flush} \times N_{frozen} $$
*(With defaults: 32 MB * 3 = 96 MB)*

---

## 3. The Throughput Formula

The effective accepted throughput ($R_{eff}$) is defined by a piecewise function:

### Case A: Payload Exceeds Hard Limit
If the message size exceeds the SDK limit ($S_{msg} > L_{payload}$):
$$ R_{eff} = 0 $$
*(All messages are instantly rejected by the SDK before IPC).*

### Case B: Under-Capacity (Steady State, No Backpressure)
If the input byte rate is slower than the background engine can process ($R_{in} \times S_{msg} \le R_{io}$):
$$ R_{eff} = R_{in} $$
*(The buffer never fills. The system continuously flushes in the background. 100% of messages are accepted).*

### Case C: Over-Capacity (Burst & Backpressure)
If the input byte rate outpaces the background engine ($R_{in} \times S_{msg} > R_{io}$), the buffer fills up.

First, calculate the time it takes to fill the buffer ($t_{fill}$):
$$ t_{fill} = \frac{C_{max}}{(R_{in} \times S_{msg}) - R_{io}} $$

**If $T_{test} \le t_{fill}$ :**
The test ends before the buffer is exhausted. Backpressure never triggers.
$$ R_{eff} = R_{in} $$

**If $T_{test} > t_{fill}$ :**
The system accepts traffic freely for the first $t_{fill}$ seconds. Once the 3 retained CFs limit is hit (at expected ~96 MB), backpressure activates and the ingestion rate is strictly hard-capped to the background drain rate ($R_{io}$). 

The total bytes accepted over the entire window is the full buffer capacity ($E[C_{max}]$) plus whatever the background engine managed to process and drain during that time ($R_{io} \times T_{test}$). Dividing this by the time window and message size yields the average effective messages/sec:

$$ R_{eff} = \frac{R_{io} + \frac{L_{flush} \times N_{frozen}}{T_{test}}}{S_{msg}} $$

*(Note: If the math somehow yields a rate higher than $R_{in}$, $R_{eff}$ is capped at $R_{in}$.)*

---

## 4. Example Application (Cell 11: 1 MB @ 100/s)

Let's plug in the numbers for a 60-second high-throughput test:
* $R_{in} = 100$ ev/s
* $S_{msg} = 1$ MB
* $T_{test} = 60$ seconds (1 minute)
* $L_{flush} = 32$ MB, $N_{frozen} = 3$ $\rightarrow E[C_{max}] = 96$ MB
* $R_{io} \approx 13.5$ MB/s

Input byte rate ($100$ MB/s) > $R_{io}$ ($13.5$ MB/s), so this becomes **Case C**!

1. Calculate time to fill buffer:
$$ t_{fill} = \frac{96 \text{ MB}}{100 \text{ MB/s} - 13.5 \text{ MB/s}} \approx 1.1 \text{ seconds} $$

2. Because $T_{test}$ (60s) > $t_{fill}$ (1.1s), the system hits backpressure almost immediately.

3. Calculate average effective throughput:
$$ R_{eff} = \frac{13.5 + \frac{96}{60}}{1} = \frac{13.5 + 1.6}{1} = 15.1 \text{ ev/s} $$

**Conclusion:** The engine safely applies backpressure to shed the excess $85$ MB/s of load, completely preventing OOMKills. The system's effective throughput $R_{eff}$ gracefully degrades and strictly conforms to the empirical $R_{io}$ limits of its Kubernetes `500m` CPU allocation!
