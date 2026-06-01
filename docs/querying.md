# 🔍 Querying Iceberg Tables
> 🌐 Part of the **[mIceWriter Telemetry Ingestion Ecosystem](../README.md)**

[![Ecosystem: mIceWriter](https://img.shields.io/badge/Ecosystem-mIceWriter-blueviolet?style=flat-square)](../README.md)
[![Lens: Use](https://img.shields.io/badge/Lens-Use-yellow?style=flat-square)](#)
[![Component: Querying Guide](https://img.shields.io/badge/Component-Querying%20Guide-orange?style=flat-square)](#)

Once the mIceWriter engine has completed its first flush cycle, the Iceberg table is registered in the catalog and its Parquet files are in object storage — ready for SQL queries. This guide covers two paths depending on your environment.

> **Latency note:** Data becomes queryable ~10 minutes (or 192 MB) after ingestion, once the flush cycle completes and the Iceberg snapshot is committed to the catalog.

---

## 1. Cloud / Production — AWS Athena

Athena queries Iceberg tables natively via the AWS Glue catalog. Because the mIceWriter engine commits each flush atomically to Glue, **no manual DDL is required** — the table appears automatically after the first flush.

### Prerequisites

- mIceWriter engine configured with `CATALOG_TYPE=glue` and valid AWS credentials (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION`)
- At least one flush cycle completed (Parquet files visible in S3, snapshot committed to Glue)
- An Athena workgroup with an S3 query-results location configured

### Steps

1. Open the **AWS Athena console** → select your workgroup
2. In the left sidebar, select the Glue database that matches your engine's `CATALOG_NAMESPACE` (e.g. `micewriter`)
3. The table (e.g. `telemetry_events`) appears automatically — no `CREATE TABLE` needed

### Example SQL

```sql
-- Preview recent events
SELECT * FROM "micewriter"."telemetry_events"
ORDER BY event_time DESC
LIMIT 100;

-- Aggregate by source
SELECT source, COUNT(*) AS event_count
FROM "micewriter"."telemetry_events"
GROUP BY source
ORDER BY event_count DESC;

-- Iceberg time travel (query a previous snapshot)
SELECT * FROM "micewriter"."telemetry_events"
FOR SYSTEM_TIME AS OF TIMESTAMP '2025-01-01 00:00:00'
LIMIT 100;
```

---

## 2. Local / Dev — Superset via Trino

[Apache Superset](https://superset.apache.org/) is a SQL UI and dashboarding tool — it does **not** connect to Nessie or Iceberg directly. It delegates query execution to a backend engine. For the local k3s stack, that engine is **Trino**, which has a native Iceberg catalog connector with REST catalog support (compatible with Nessie's Iceberg REST endpoint).

```
Superset  →  Trino  →  Nessie Iceberg REST  →  MinIO (Parquet)
```

### Step 1 — Deploy Trino + Superset into the local cluster

Trino and Superset are included in `micewriter-local-infra` as an optional query stack. Deploy them with a single command from that repo:

```powershell
.\run.ps1 query-up
```

This builds a custom Superset image (with the Trino SQLAlchemy driver added), pushes it to the local registry, installs Trino (via the official [trinodb/trino](https://trinodb.github.io/charts/) Helm chart with the Iceberg/Nessie/MinIO catalog pre-configured), and deploys Superset (with its PostgreSQL and Redis dependencies) into the `micewriter-infra` namespace.

Verify Trino is healthy before proceeding:

```powershell
curl http://k8s-node-1.local:8080/v1/info
# → {"nodeVersion":{"version":"..."}, "starting":false, ...}
```

### Step 2 — Add Trino as a database connection in Superset

Open Superset at `http://k8s-node-1.local:8088` and log in with `admin` / `admin`.

Go to **Settings > Database Connections > + Database**, select **Trino**, and enter:

| Field | Value |
|---|---|
| **Display name** | `Trino Iceberg` (or any label) |
| **SQLAlchemy URI** | `trino://admin@trino.micewriter-infra.svc.cluster.local:8080/iceberg` |

Click **Test Connection** to verify, then **Connect**.

### Step 3 — Query in SQL Lab

Go to **SQL > SQL Lab**, select the `Trino Iceberg` database and `micewriter` schema, then run:

```sql
-- Preview recent events
SELECT * FROM iceberg.micewriter.telemetry_events
ORDER BY event_time DESC
LIMIT 100;

-- Aggregate by source
SELECT source, COUNT(*) AS event_count
FROM iceberg.micewriter.telemetry_events
GROUP BY source
ORDER BY event_count DESC;

-- List available tables in the namespace
SHOW TABLES FROM iceberg.micewriter;
```

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
