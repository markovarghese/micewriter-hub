# Getting Started
> 🌐 Part of the **[mIceWriter Telemetry Ingestion Ecosystem](../README.md)**

[![Ecosystem: mIceWriter](https://img.shields.io/badge/Ecosystem-mIceWriter-blueviolet?style=flat-square)](../README.md)
[![Lens: Is it viable?](https://img.shields.io/badge/Lens-Is%20it%20viable%3F-blue?style=flat-square)](#)

> **Role in the [feasibility evaluation](feasibility.md):** the operational deploy flow that stands up the local stack before any load test runs. Steps 1–6 deploy infrastructure + engine + webhook + sandbox; Step 7 onward verifies the pipeline is ready to drive load against. Running the [load testing specification](load-testing-spec.md) assumes this guide has been completed once.

End-to-end guide for deploying the full mIceWriter stack onto the local k3s-on-Hyper-V
cluster provisioned by [k3sonhyperv](https://github.com/markovarghese/k3sonhyperv).

---

## Prerequisites

| Requirement | How to satisfy it |
|---|---|
| k3s cluster running | Follow the k3sonhyperv README through Step 4 (verify nodes) |
| `$HOME/.kube/config` exists | Produced automatically by `install-k3s.yml` (moved from repository) |
| Docker Desktop running | Start from the system tray |
| All micewriter repos cloned | Clone each sibling repo into the same parent folder |

---

## Step 1 — One-time: configure Docker Desktop

Add the in-cluster registry to Docker Desktop's insecure registries list
(**Settings → Docker Engine**) and restart Docker Desktop:

```json
{
  "insecure-registries": ["k8s-node-1.local:5000"]
}
```

This is required so `docker push` can reach the HTTP registry running inside k3s.

---

## Step 2 — One-time: configure k3s nodes to trust the registry

From the `k3sonhyperv` directory:

```powershell
powershell -ExecutionPolicy Bypass -File .\run-ansible.ps1 -Playbook install-local-registry.yml
```

This writes `/etc/rancher/k3s/registries.yaml` on all three nodes and restarts k3s so
containerd can pull images from `k8s-node-1.local:5000` over plain HTTP.

---

## Step 3 — Stand up infrastructure

From the `micewriter-local-infra` directory:

```powershell
powershell -ExecutionPolicy Bypass -File .\run.ps1 up
```

This single command installs, in order:

| Component | Purpose |
|---|---|
| **cert-manager** | Provides TLS certificates for the mutating webhook |
| **Local registry** (`registry:2`) | Image distribution endpoint at `k8s-node-1.local:5000` |
| **MinIO** | S3-compatible object store for Parquet files |
| **Apache Nessie** | Iceberg REST Catalog for atomic table commits |

Verify everything is healthy:

```powershell
powershell -ExecutionPolicy Bypass -File .\run.ps1 status
```

Expected endpoints once ready:

| Service | URL |
|---|---|
| Local registry | `http://k8s-node-1.local:5000` |
| MinIO console | `http://k8s-node-1.local:9001` (user: `micewriter` / `micewriter123`) |
| MinIO S3 API | `http://k8s-node-1.local:9000` |
| Nessie REST | `http://k8s-node-1.local:19120/api/v1` |
| Iceberg REST | `http://k8s-node-1.local:19120/iceberg/v1` |

---

## Step 4 — Push the engine image

From the `micewriter-engine` directory:

```powershell
powershell -ExecutionPolicy Bypass -File .\push.ps1
```

This builds the Rust sidecar Docker image and pushes it to the local registry. The
k8s-injector embeds this image reference in every annotated pod it mutates, so the image
must be available in the registry before any application pods are created.

---

## Step 5 — Deploy the mutating webhook

From the `micewriter-k8s-injector` directory:

```powershell
# Build and push the webhook image
powershell -ExecutionPolicy Bypass -File .\run.ps1 push

# Deploy the Helm chart (cert-manager must be ready from Step 3)
powershell -ExecutionPolicy Bypass -File .\run.ps1 deploy
```

> If `deploy` fails with "no kind Issuer", wait ~10 seconds and retry. cert-manager CRDs
> occasionally take a moment to be served after the pods become Available.

The webhook is now live. Any pod created with the annotation
`iceberg-stream.micewriter.io/inject: "true"` will automatically receive the engine
sidecar, the shared UDS socket volume, and a RocksDB PVC.

---

## Step 6 — Deploy the sandbox reference app

From the `micewriter-sandbox` directory:

```powershell
powershell -ExecutionPolicy Bypass -File .\run.ps1 deploy
```

This builds the Spring Boot image (using the parent directory as Docker build context so
both `micewriter-sdk-java` and `micewriter-sandbox` sources are compiled together),
pushes it to the local registry, and applies the k8s manifests. The mutating webhook
automatically injects the engine sidecar on pod creation.

---

## Step 7 — Verify the full pipeline

### Send traffic

```powershell
# Single event
curl -X POST http://k8s-node-1.local/events `
  -H 'Content-Type: application/json' `
  -d '{"source": "smoke-test", "payload": "hello", "severity": 1}'

# Load test (1 000 events)
curl -X POST "http://k8s-node-1.local/events/load?count=1000"
# → {"sent":1000,"elapsedMs":...,"throughputPerSec":...}
```

### Watch the engine flush

The sidecar flushes every ~5 minutes or when 128 MB of data is accumulated. Stream its logs to watch:

```powershell
kubectl logs -n micewriter-sandbox deploy/micewriter-sandbox -c micewriter-engine --follow
```

Look for log lines like:
```
flush_engine: rotating column family, frozen_cf=cf_1
iceberg_writer: committing snapshot to nessie, files=3, rows=1000
iceberg_writer: commit succeeded, snapshot_id=...
```

### Confirm data landed

1. **MinIO console** — `http://k8s-node-1.local:9001`
   Browse `iceberg/` → `micewriter/` → `telemetry_events/` — Parquet files appear after
   the first flush cycle.

2. **Nessie API** — confirm the Iceberg table exists:
   ```powershell
   curl http://k8s-node-1.local:19120/api/v1/trees/main/entries
   ```

---

## Step 8 — Query your data

Once the engine has completed its first flush cycle (watch for `iceberg_writer: commit succeeded` in the logs), the Iceberg table is ready to query.

👉 **[Querying Iceberg Tables — Athena & Superset guide](querying.md)**

---

## Teardown

```powershell
# Undeploy the sandbox app
# (from micewriter-sandbox)
powershell -ExecutionPolicy Bypass -File .\run.ps1 undeploy

# Undeploy the webhook
# (from micewriter-k8s-injector)
powershell -ExecutionPolicy Bypass -File .\run.ps1 undeploy

# Tear down infrastructure (keeps PVCs — MinIO data survives)
# (from micewriter-local-infra)
powershell -ExecutionPolicy Bypass -File .\run.ps1 down

# Full reset — purges the namespace and all PVCs
powershell -ExecutionPolicy Bypass -File .\run.ps1 clean
```

---

## Re-deploying after a code change

| What changed | Command |
|---|---|
| Engine Rust source | `powershell -ExecutionPolicy Bypass -File .\push.ps1` in `micewriter-engine`, then restart the sandbox pod |
| Webhook Go source | `powershell -ExecutionPolicy Bypass -File .\run.ps1 push` + `powershell -ExecutionPolicy Bypass -File .\run.ps1 deploy` in `micewriter-k8s-injector` |
| Sandbox Java source | `powershell -ExecutionPolicy Bypass -File .\run.ps1 deploy` in `micewriter-sandbox` (re-builds and re-pushes) |
| Infrastructure values | `powershell -ExecutionPolicy Bypass -File .\run.ps1 up` in `micewriter-local-infra` (Helm upgrade is idempotent) |

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
