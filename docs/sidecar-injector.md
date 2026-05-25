# Repository 5: iceberg-sidecar-injector

This repository provides the "Service Mesh" style auto-injection. It is the Mutating Webhook that provides the gold standard Developer Experience by hiding all infrastructure boilerplate from the application engineers.

## Core Technology Stack
- **Language:** Go (Kubernetes controller-runtime) or Python (Kopf/FastAPI)
- **K8s Feature:** Mutating Admission Webhooks, TLS Certificates

## Functionality
Intersects the Kubernetes API during Pod creation. If it detects a deployment labeled with `iceberg-stream.yourcompany.com/inject: "true"`, it alters the PodSpec on the fly.

### Injections Performed
1. **The Sidecar:** Injects the Rust Sidecar container image into the pod.
2. **Environment Linking:** Injects environment variables (e.g., `MINIO_URL`, `NESSIE_URI`) that route the sidecar to the catalog and storage buckets.
3. **IPC Socket:** Mounts an `emptyDir` shared volume to allow the Java container and Rust container to communicate over the Unix Domain Socket (`/var/run/app`).
4. **RocksDB Cache:** Dynamically provisions a Generic Ephemeral Volume to attach a high-IOPS Persistent Volume Claim (PVC) exclusively for RocksDB caching, tied 1-to-1 to the pod's lifecycle.

## Output Artifact
A Docker image containing the controller, and a Helm chart deploying the `MutatingWebhookConfiguration` and the web server.
