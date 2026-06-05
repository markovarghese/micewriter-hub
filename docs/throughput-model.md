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
* **$R_{io}$** : **Background I/O Rate** (bytes / second). This is the speed at which the `flush_engine` can compile CBOR into Parquet, upload to MinIO, and commit to Nessie. 

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

## 4. Example Application (Scenario 2)

Let's plug in the numbers for a 15-minute high-throughput test:
* $R_{in} = 100$ ev/s
* $S_{msg} = 1$ MB
* $T_{test} = 900$ seconds (15 minutes)
* $L_{flush} = 32$ MB, $N_{frozen} = 3$ $\rightarrow E[C_{max}] = 96$ MB
* $R_{io} \approx 20$ MB/s

Input byte rate ($100$ MB/s) > $R_{io}$ ($20$ MB/s), so this is **Case C**.

1. **Calculate $t_{fill}$**:
   $t_{fill} = \frac{96 \text{ MB}}{100 \text{ MB/s} - 20 \text{ MB/s}} = 1.2 \text{ seconds}$
2. **Calculate Average Throughput**:
   Since $900s > 1.2s$, backpressure applies for 99.8% of the test.
   $R_{eff} = \frac{20 \text{ MB/s} + \frac{96 \text{ MB}}{900s}}{1 \text{ MB}} = \frac{20 + 0.106}{1} \approx \textbf{20.10 ev/s}$

**Conclusion:** Over a 15-minute window, the 96 MB buffer provides a tiny fractional bump (+0.10 ev/s). The system's jitter means the exact capacity for any given run will vary between 72 MB and 120 MB, but the *average* effective throughput overwhelmingly converges to the exact speed of the background I/O flush rate ($R_{io}$).
