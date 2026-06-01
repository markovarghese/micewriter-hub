# 🧪 micewriter-sandbox
> 🌐 Part of the **[mIceWriter Telemetry Ingestion Ecosystem](file:///c:/Users/marko/source/repos/micewriter-hub/README.md)**

[![Ecosystem: mIceWriter](https://img.shields.io/badge/Ecosystem-mIceWriter-blueviolet?style=flat-square)](file:///c:/Users/marko/source/repos/micewriter-hub/README.md)
[![Lens: Is it viable?](https://img.shields.io/badge/Lens-Is%20it%20viable%3F-blue?style=flat-square)](#)
[![Component: Testing Sandbox](https://img.shields.io/badge/Component-Testing%20Sandbox-yellow?style=flat-square)](#)

> **Role in the [feasibility evaluation](feasibility.md):** stands in for "another team's application" — a Spring Boot microservice with the Java SDK wired in. Receives HTTP load on a test endpoint and emits records through UDS to the engine sidecar so resource cost can be measured under controlled traffic.

This repository acts as the Reference Implementation and the primary testing ground for the entire pipeline. It simulates a standard enterprise microservice.

## 🛠️ Core Technology Stack
- **Language/Framework:** Java 17, Spring Boot
- **Deployment:** Docker, Skaffold, Kubernetes Manifests

## ⚙️ Functionality
Serves as "documentation-by-code" for product teams wanting to adopt the mIceWriter ingestion pipeline.
1. **Mock Endpoints:** Uses standard Spring Boot `@RestController`s to receive dummy traffic.
2. **SDK Consumption:** Maps incoming JSON to `@IcebergEntity` annotated POJOs and calls the `icebergTemplate.send()` SDK method.
3. **K8s Integration:** Contains a deployment manifest demonstrating the critical `iceberg-stream.micewriter.io/inject: "true"` pod annotation required to trigger the Mutating Webhook.

## 🏃 Workflow
Developers can run this app locally, hit its mock endpoints with an HTTP load generator, and then open the local MinIO UI to watch the telemetry successfully materialize as Parquet files every 10 minutes.

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
