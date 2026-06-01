# 🔀 v1 → v2 Migration Rationale
> 🌐 Part of the **[mIceWriter Telemetry Ingestion Ecosystem](file:///c:/Users/marko/source/repos/micewriter-hub/README.md)**

[![Ecosystem: mIceWriter](https://img.shields.io/badge/Ecosystem-mIceWriter-blueviolet?style=flat-square)](file:///c:/Users/marko/source/repos/micewriter-hub/README.md)
[![Lens: What](https://img.shields.io/badge/Lens-What-green?style=flat-square)](#)
[![Component: Migration Notes](https://img.shields.io/badge/Component-Migration%20Notes-yellow?style=flat-square)](#)

This document captures **why** the mIceWriter architecture pivoted from v1 (per-pod sidecar) to v2 (per-table pipelines). It exists so future readers understand the design constraints that drove the move — not as user-facing migration instructions (there is no installed base of v1 to migrate).

## TL;DR

v1 worked but had three properties that compounded as adoption grew:
1. **Engine RAM was bound to the 512 MiB sidecar envelope**, capping the size of compiled Parquet files
2. **Catalog commit pressure scaled linearly with adopter pod count** — every app pod was a committing pod
3. **Engine lifecycle was bound to app pod lifecycle** — bug fixes, upgrades, and resource changes required recycling app pods

v2 addresses all three by deploying engines as **one `Deployment` + `Service` per Iceberg table**, with the SDK routing via the existing `@IcebergEntity(table = "...")` annotation over gRPC.

## Driver 1: Parquet file size is gated by engine RAM

The v1 sidecar compiles each flush window's records in memory via `CBOR → NDJSON → Arrow → Parquet`. The JSON DOM hop amplifies payload size (a 16 MB CBOR payload of floats expands to 200+ MB of `serde_json::Value`), and the whole batch must live in memory until the Parquet write completes. The 32 MB CF flush ceiling and 16 MB per-payload cap are both reverse-engineered from the 512 MiB sidecar limit ([system-overview.md §2](system-overview.md)).

Downstream analytics engines (Trino, Athena, Spark) want larger Parquet files. The structural answer is more RAM per engine — which the sidecar pattern cannot give without raising the limit for every adopting pod regardless of payload mix.

In v2 each pipeline is sized for the table's payload shape: small audit-event tables get small pods; large model-evaluation tables get a 4 GiB envelope.

## Driver 2: Catalog commit pressure scales with adopter pod count

v1's component map noted, but did not measure: "Catalog commit pressure grows with N" — where N is the count of app pods writing to the same Iceberg table. With 100 app replicas, 100 sidecars produce 100 flush commits per window against the same table. `FastAppendAction`'s optimistic-locking retry absorbs small N but the retry cost is super-linear.

v2 bounds commit count per table to the pipeline's pod count, which is set by HPA from write metrics rather than coupled to the app's replica count. A pipeline with 3 pods produces 3 commits per window regardless of how many apps are writing to it.

## Driver 3: Engine lifecycle was bound to app pod lifecycle

In v1, every engine bug fix required recycling every adopting app pod. The SDK had no UDS reconnect (`micewriter-sdk-java#1`), so engine container restarts left the app pod in a `2/2 Ready` but broken state — the only recovery was deleting the whole pod.

v2 deploys engines as their own `Deployment` per table:
- Engine bug fixes roll independently per pipeline
- gRPC's native reconnect handles transport blips without app-side awareness — the v1 reconnect bug is moot
- Vertical scaling is a DaemonSet/Deployment spec edit, not an app Pod spec edit
- Per-table blast radius — a schema bug in one pipeline can't OOM engines serving other tables

## Why not other shapes considered

The conversation that drove v2 weighed several alternatives:

| Considered | Why not |
|---|---|
| **DaemonSet engine (one per node)** | Engine count tied to node count, not write load. Cleaner than v1 but doesn't give true HPA on write metrics. Per-node multi-tenant routing reintroduces the noisy-neighbor concern. |
| **Single freely-scaled engine pool** | Bin-packs efficiently but a noisy or large-payload table impacts every other table sharing the pool. Catalog-commit contention is global across all tables. No per-table resource sizing. |
| **Per-tier pools (small/large/audit)** | Defeated by heterogeneity in the target workload — adopter profile is "many heterogeneous tables, infrequent new ones," not "many similar-shaped tables." Tiering only buys isolation when tables cluster cleanly into shape buckets. |
| **Per-table with operator/CRD** | Operator complexity isn't justified when new tables arrive infrequently. Helm provisioning is acceptable for the table-creation cadence. |

## What the move costs

Honest about the price:

- **SDK transport rewrite.** Netty UDS → gRPC client. The public API (`@IcebergEntity`, `icebergTemplate.send(pojo)`) is unchanged, but the transport layer is the largest single piece of v2 work.
- **Helm release per Iceberg table.** Adding a table now requires `helm install`, not just a catalog operation. Acceptable for the "infrequent new tables" profile that drove the choice.
- **No more single-annotation adoption.** v1 was one annotation; v2 is one env var + a Maven dep + the per-table Helm release (done by the platform team, not the adopter). Still vastly less than implementing buffering yourself, but no longer "one annotation."
- **Sub-millisecond instead of microsecond latency.** gRPC over the cluster network is ~1 ms p50 instead of UDS's ~10 µs. For Spring Boot / Dropwizard request handlers (the intended adopter), this is well under the request-budget noise floor.

## v1 is preserved

The v1 architecture lives on every `micewriter-*` repo at two equivalent refs:

- **`v1` branch** — the ergonomic checkout target. `git clone -b v1 ...` works; sits next to `main` in GitHub's UI so v1 is visible as a maintained alternative, not buried metadata.
- **`v1.0.0` tag** — the immutable canonical reference. Use it to verify "this is exactly v1" or to script reproducible checkouts.

To redeploy v1:

```sh
for d in micewriter-hub micewriter-engine micewriter-sdk-java \
         micewriter-k8s-injector micewriter-sandbox micewriter-local-infra; do
  git -C "$d" checkout v1   # or 'v1.0.0' for the tag
done
```

The local-infra `run.ps1` can deploy either variant by checking out matching refs across repos. The `v1` branch is protected against direct pushes (PR-only) once published — it stays frozen by default; any future v1 fixes would land as deliberate backport PRs.

## Related

- [per-table-pipelines.md](per-table-pipelines.md) — the v2 design itself
- [system-overview.md](system-overview.md) — current architecture (v2)
- [feasibility.md](feasibility.md) — load-testing rationale that surfaced the v1 limits

---
### 🔗 The mIceWriter Ecosystem

**🎯 Why:**
* [Motivation & target adopter](why.md)

**🛠️ What:**
* [System overview & wire protocol](system-overview.md)
* [v2: Per-table pipelines](per-table-pipelines.md)
* [v1 → v2 migration rationale](v1-to-v2-migration.md) — *this doc*

**🔬 Is it viable?**
* [Feasibility evaluation](feasibility.md)
