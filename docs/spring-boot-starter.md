# Repository 2: iceberg-spring-boot-starter

This repository contains the Library/SDK that product developers use to interface with the Sidecar Engine.

## Core Technology Stack
- **Language:** Java/Kotlin
- **Framework:** Spring Boot AutoConfiguration
- **Network IO:** Netty / Epoll (for UDS communication)

## Functionality
This library abstracts away the IPC complexity so business developers just write standard Java code.

1. **Annotations:** Provides `@IcebergEntity` and `@IcebergId` to demarcate domain objects (POJOs) that should be ingested.
2. **Auto-Configuration:** Scans the classpath for annotated entities on startup and sends `REGISTER_SCHEMA` requests over the socket to ensure the sidecar prepares the Iceberg tables.
3. **`IcebergStreamTemplate`:** A Spring Bean injected into the application context. It exposes a `.send(pojo)` method that serializes the object to Protobuf/Bincode and flushes it over the Unix Domain Socket with minimal latency.

## Output Artifact
A compiled `.jar` file published to Maven Central, an internal Nexus/Artifactory, or Maven Local.
