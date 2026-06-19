# 🧪 micewriter-sandbox
> 🌐 Part of the **[mIceWriter Telemetry Ingestion Ecosystem](../README.md)**

[![Ecosystem: mIceWriter](https://img.shields.io/badge/Ecosystem-mIceWriter-blueviolet?style=flat-square)](../README.md)
[![Lens: Is it viable?](https://img.shields.io/badge/Lens-Is%20it%20viable%3F-blue?style=flat-square)](#)
[![Component: Testing Sandbox](https://img.shields.io/badge/Component-Testing%20Sandbox-yellow?style=flat-square)](#)

> **Role in the [feasibility evaluation](feasibility.md):** stands in for "another team's application" — a Spring Boot microservice with the Java SDK wired in. Receives HTTP load on a test endpoint and emits records over **gRPC** to the per-table engine pipeline so resource cost can be measured under controlled traffic.

This repository acts as the Reference Implementation and the primary testing ground for the entire pipeline. It simulates a standard enterprise microservice.

## 🛠️ Core Technology Stack
- **Language/Framework:** Java 17, Spring Boot
- **Transport:** mIceWriter Java SDK → per-table engine pipeline over **gRPC (HTTP/2)**, records serialized as **CBOR**
- **Deployment:** Docker, Skaffold, Kubernetes Manifests

## ⚙️ Functionality
Serves as "documentation-by-code" for product teams wanting to adopt the mIceWriter ingestion pipeline.
1. **Mock Endpoints:** Uses standard Spring Boot `@RestController`s to receive dummy traffic (`POST /events`, `POST /events/load`, and the in-process `/loadtest/*` generator).
2. **SDK Consumption:** Maps incoming JSON request bodies to `@IcebergEntity`-annotated POJOs (the `load_test_events` table in the `micewriter` namespace) and streams them with `icebergTemplate.sendAsyncWithRetry()`. The SDK serializes each record as CBOR and routes it **by table** to the pipeline endpoint.
3. **Pipeline Routing:** App config points the SDK at the resolver — there is no sidecar to inject and no per-pod RocksDB PVC to provision. The v1 `micewriter-k8s-injector` mutating webhook is **sunset** in v2.
   ```yaml
   micewriter:
     resolver: "engine-{table}.micewriter.svc:9090"
     base-package: com.micewriter.sandbox.model   # narrows the @IcebergEntity classpath scan
   ```

## 🏃 Workflow
Developers can run this app locally, hit its mock endpoints with an HTTP load generator, and then open the local MinIO UI to watch the telemetry materialize as Parquet files after the pipeline's hybrid flush cycle (jittered ~10 min ± 2 min, or sooner if the active RocksDB column family crosses 32 MB). For deterministic end-to-end tests, the engine's `FlushNow` RPC (`ENABLE_MANUAL_FLUSH=true`, non-production only) forces an immediate compile-and-commit instead of waiting for the timer.

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
