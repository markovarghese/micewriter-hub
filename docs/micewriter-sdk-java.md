# ☕ micewriter-sdk-java
> 🌐 Part of the **[mIceWriter Telemetry Ingestion Ecosystem](file:///c:/Users/marko/source/repos/mmicewriter_design/README.md)**

[![Ecosystem: mIceWriter](https://img.shields.io/badge/Ecosystem-mIceWriter-blueviolet?style=flat-square)](file:///c:/Users/marko/source/repos/mmicewriter_design/README.md)
[![Component: Java Starter SDK](https://img.shields.io/badge/Component-Java%20Starter%20SDK-blue?style=flat-square)](#)

This repository contains the Library/SDK that product developers use to interface with the `micewriter-engine` sidecar.

## 🛠️ Core Technology Stack
- **Language:** Java/Kotlin
- **Framework:** Spring Boot AutoConfiguration
- **Network IO:** Netty / Epoll (for UDS communication)

## ⚙️ Functionality
This library abstracts away the IPC complexity so business developers just write standard Java code.

1. **Annotations:** Provides `@IcebergEntity` and `@IcebergId` to demarcate domain objects (POJOs) that should be ingested.
2. **Auto-Configuration:** Scans the classpath for annotated entities on startup and sends `REGISTER_SCHEMA` requests over the socket to ensure the sidecar prepares the Iceberg tables.
3. **`IcebergStreamTemplate`:** A Spring Bean injected into the application context. It exposes a `.send(pojo)` method that serializes the object to Protobuf/Bincode and flushes it over the Unix Domain Socket with minimal latency.

## 📦 Output Artifact
A compiled `.jar` file published to Maven Central, an internal Nexus/Artifactory, or Maven Local.

---
### 🔗 The mIceWriter Ecosystem
* **Architecture Hub:** [micewriter-hub](file:///c:/Users/marko/source/repos/mmicewriter_design/README.md)
* **System Overview:** [system-overview](file:///c:/Users/marko/source/repos/mmicewriter_design/docs/system-overview.md)
* **Rust Sidecar Engine:** [micewriter-engine](file:///c:/Users/marko/source/repos/mmicewriter_design/docs/micewriter-engine.md)
* **Spring Boot SDK:** [micewriter-sdk-java](file:///c:/Users/marko/source/repos/mmicewriter_design/docs/micewriter-sdk-java.md)
* **Kubernetes Webhook:** [micewriter-k8s-injector](file:///c:/Users/marko/source/repos/mmicewriter_design/docs/micewriter-k8s-injector.md)
* **Local Data Lake Mock:** [micewriter-local-infra](file:///c:/Users/marko/source/repos/mmicewriter_design/docs/micewriter-local-infra.md)
* **Reference Testing App:** [micewriter-sandbox](file:///c:/Users/marko/source/repos/mmicewriter_design/docs/micewriter-sandbox.md)
