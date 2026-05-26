# 🧪 micewriter-sandbox
> 🌐 Part of the **[mIceWriter Telemetry Ingestion Ecosystem](file:///c:/Users/marko/source/repos/micewriter-hub/README.md)**

[![Ecosystem: mIceWriter](https://img.shields.io/badge/Ecosystem-mIceWriter-blueviolet?style=flat-square)](file:///c:/Users/marko/source/repos/micewriter-hub/README.md)
[![Component: Testing Sandbox](https://img.shields.io/badge/Component-Testing%20Sandbox-yellow?style=flat-square)](#)

This repository acts as the Reference Implementation and the primary testing ground for the entire pipeline. It simulates a standard enterprise microservice.

## 🛠️ Core Technology Stack
- **Language/Framework:** Java/Kotlin, Spring Boot
- **Deployment:** Docker, Skaffold, Kubernetes Manifests

## ⚙️ Functionality
Serves as "documentation-by-code" for product teams wanting to adopt the mIceWriter ingestion pipeline.
1. **Mock Endpoints:** Uses standard Spring Boot `@RestController`s to receive dummy traffic.
2. **SDK Consumption:** Maps incoming JSON to `@IcebergEntity` annotated POJOs and calls the `icebergTemplate.send()` SDK method.
3. **K8s Integration:** Contains a deployment manifest demonstrating the critical `iceberg-stream.yourcompany.com/inject: "true"` pod annotation required to trigger the Mutating Webhook.

## 🏃 Workflow
Developers can run this app locally, hit its mock endpoints with an HTTP load generator, and then open the local MinIO UI to watch the telemetry successfully materialize as Parquet files every 10 minutes.

---
### 🔗 The mIceWriter Ecosystem
* **Architecture Hub:** [micewriter-hub](file:///c:/Users/marko/source/repos/micewriter-hub/README.md)
* **System Overview:** [system-overview](file:///c:/Users/marko/source/repos/micewriter-hub/docs/system-overview.md)
* **Rust Sidecar Engine:** [micewriter-engine](file:///c:/Users/marko/source/repos/micewriter-hub/docs/micewriter-engine.md)
* **Spring Boot SDK:** [micewriter-sdk-java](file:///c:/Users/marko/source/repos/micewriter-hub/docs/micewriter-sdk-java.md)
* **Kubernetes Webhook:** [micewriter-k8s-injector](file:///c:/Users/marko/source/repos/micewriter-hub/docs/micewriter-k8s-injector.md)
* **Local Data Lake Mock:** [micewriter-local-infra](file:///c:/Users/marko/source/repos/micewriter-hub/docs/micewriter-local-infra.md)
* **Reference Testing App:** [micewriter-sandbox](file:///c:/Users/marko/source/repos/micewriter-hub/docs/micewriter-sandbox.md)
