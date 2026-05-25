# Repository 4: telemetry-sandbox-app

This repository acts as the Reference Implementation and the primary testing ground for the entire pipeline. It simulates a standard enterprise microservice.

## Core Technology Stack
- **Language/Framework:** Java/Kotlin, Spring Boot
- **Deployment:** Docker, Skaffold, Kubernetes Manifests

## Functionality
Serves as "documentation-by-code" for product teams wanting to adopt the Iceberg Sidecar ingestion pipeline.
1. **Mock Endpoints:** Uses standard Spring Boot `@RestController`s to receive dummy traffic.
2. **SDK Consumption:** Maps incoming JSON to `@IcebergEntity` annotated POJOs and calls the `icebergTemplate.send()` SDK method.
3. **K8s Integration:** Contains a deployment manifest demonstrating the critical `iceberg-stream.yourcompany.com/inject: "true"` pod annotation required to trigger the Mutating Webhook.

## Workflow
Developers can run this app locally, hit its mock endpoints with an HTTP load generator, and then open the local MinIO UI to watch the telemetry successfully materialize as Parquet files every 10 minutes.
