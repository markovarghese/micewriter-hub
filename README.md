# 📥 micewriter-hub
> 🌐 Architecture, motivation, and feasibility evaluation for the **mIceWriter Ingestion Ecosystem** — a sidecar that lets EKS-deployed apps persist to Apache Iceberg without blocking the hot path or burdening their JVM.

[![Ecosystem: mIceWriter](https://img.shields.io/badge/Ecosystem-mIceWriter-blueviolet?style=flat-square)](file:///c:/Users/marko/source/repos/micewriter-hub/README.md)
[![Component: Central Hub](https://img.shields.io/badge/Component-Central%20Hub-brightgreen?style=flat-square)](#)

mIceWriter is an **ingestion platform** for applications running on AWS EKS (or any Kubernetes cluster) that need to persist telemetry, audit, or model-payload data to Apache Iceberg tables — without paying S3 latency on the hot path, without buffering large payloads in their own JVM heap, and without flooding S3 with tiny files that ruin downstream query performance.

In **v2**, mIceWriter deploys **one engine `Deployment` + `Service` per Iceberg table**. Applications add the Java SDK as a Maven dependency, annotate domain objects with `@IcebergEntity(table = "...")`, and call `icebergTemplate.send(pojo)`. The SDK routes each record over gRPC to the right pipeline. Each pipeline absorbs writes with sub-millisecond ack and asynchronously consolidates them into Parquet files committed to the Iceberg catalog (AWS Glue in production, Apache Nessie locally).

> 📜 The v1 per-pod sidecar variant is an actively maintained release line on the `v1` branch of every `micewriter-*` repo (`v1.0.0` tags the original snapshot). v1 and v2 evolve independently. See [v1 → v2 migration rationale](docs/v1-to-v2-migration.md) for the pivot story.

---

## 🧭 How to read this hub

This repository is documentation-only. It answers three questions, in this order:

| Lens | Question | Start here |
|---|---|---|
| 🎯 **Why** | What problem does this solve, who is it for, and what are the non-goals? | **[docs/why.md](docs/why.md)** |
| 🛠️ **What** | How is it built — system architecture, components, wire protocol? | **[docs/system-overview.md](docs/system-overview.md)** |
| 🔬 **Is it viable?** | At what throughputs and payload sizes does the engine fit in a reasonable CPU/memory envelope per pod? | **[docs/feasibility.md](docs/feasibility.md)** |

If you are deciding whether to adopt the sidecar in your own application, start with **Why**. If you are implementing or reviewing the design, start with **What**. If you are deciding whether to recommend this to other teams, start with **Is it viable?**.

---

## 🗺️ System topology

In v2 the application writes to **per-table engine pipelines** over gRPC. Each pipeline is independent — its own `Deployment`, `Service`, `HorizontalPodAutoscaler`, and resource budget sized to that table's payload shape.

```mermaid
graph TD
    subgraph K8sCluster ["Kubernetes Cluster"]
        subgraph AppPod ["App Pod"]
            App["Spring Boot App<br/>(SDK as Maven dep)"]
        end

        subgraph Pipelines ["Per-Table Engine Pipelines"]
            PipeT["engine-telemetry<br/>(Deployment + HPA)"]
            PipeA["engine-audit<br/>(Deployment + HPA)"]
            PipeM["engine-model-eval<br/>(Deployment + HPA, large RAM)"]
        end

        App -->|gRPC :9090| PipeT
        App -->|gRPC :9090| PipeA
        App -->|gRPC :9090| PipeM
    end

    subgraph CloudOrLocal ["Catalog + Object Store"]
        Catalog[("Apache Nessie / AWS Glue")]
        ObjectStore[("MinIO / AWS S3")]
    end

    PipeT --> Catalog
    PipeT --> ObjectStore
    PipeA --> Catalog
    PipeA --> ObjectStore
    PipeM --> Catalog
    PipeM --> ObjectStore

    style AppPod fill:#f9f9f9,stroke:#333,stroke-width:2px
    style Pipelines fill:#e6f0fa,stroke:#4a5568,stroke-width:1px
    style CloudOrLocal fill:#f5f7fa,stroke:#4a5568,stroke-width:1px
```

---

## 📚 Component repositories

The system is broken down into six repositories along separation-of-concerns lines. Three are the runtime system (`engine`, `sdk-java`, `k8s-injector`). The other three exist to evaluate the runtime system locally before recommending it for production EKS (`local-infra`, `sandbox`, plus the load-testing spec hosted in this hub).

| Lens | Repository | Description | Stack | Doc |
|---|---|---|---|---|
| 🧭 Meta | 🌐 **`micewriter-hub`** *(this repo)* | Architecture, motivation, feasibility eval — introduces all three lenses | Markdown, Mermaid | [README.md](README.md) |
| 🛠️ What | 🦀 **`micewriter-engine`** | Memory-safe Rust engine managing RocksDB buffer and Iceberg commits; deployed as one `Deployment` per Iceberg table in v2 | Rust, Tokio, RocksDB, iceberg-rust, Tonic gRPC | [micewriter-engine.md](docs/micewriter-engine.md) |
| 🛠️ What | ☕ **`micewriter-sdk-java`** | Java SDK (Spring Boot + Dropwizard) with gRPC transport and table-name routing | Java, gRPC, CBOR | [micewriter-sdk-java.md](docs/micewriter-sdk-java.md) |
| 🔬 Viable? | 🐳 **`micewriter-local-infra`** | Local data-lake stand-in (MinIO + Nessie) on k3s; hosts the per-table pipeline Helm chart | Helm, Kubernetes | [micewriter-local-infra.md](docs/micewriter-local-infra.md) |
| 🔬 Viable? | 🧪 **`micewriter-sandbox`** | Reference Spring Boot app driving load against per-table pipelines | Spring Boot, Docker | [micewriter-sandbox.md](docs/micewriter-sandbox.md) |

---

## 💻 Local multi-root workspace

To streamline development across all repositories, a VS Code multi-root workspace file is provided.

1. Clone all `micewriter-` repositories into the same parent folder.
2. Open VS Code.
3. Select **File > Open Workspace from File...** and choose **[micewriter.code-workspace](micewriter.code-workspace)**.

This organizes all codebases into a unified explorer sidebar in your IDE.

---

### 🔗 The mIceWriter Ecosystem

**🎯 Why:**
* [Motivation & target adopter](docs/why.md)

**🛠️ What:**
* [System overview & wire protocol](docs/system-overview.md)
* [v2: Per-table pipelines](docs/per-table-pipelines.md)
* [v1 → v2 migration rationale](docs/v1-to-v2-migration.md)
* [Rust engine internals](docs/micewriter-engine.md)
* [Java SDK](docs/micewriter-sdk-java.md)

**🔬 Is it viable?**
* [Feasibility evaluation](docs/feasibility.md)
* [Getting started (local deploy)](docs/getting-started.md)
* [Local infrastructure](docs/micewriter-local-infra.md)
* [Reference sandbox app](docs/micewriter-sandbox.md)
* [Load testing specification](docs/load-testing-spec.md) — driven by the sandbox's `/loadtest/{start,sweep,{runId},{runId}/stop}` endpoints ([reference](../micewriter-sandbox/README.md#loadtest--in-process-load-generator))

**📊 Use:**
* [Querying Iceberg tables](docs/querying.md)
