# 🔍 Querying Iceberg Tables
> 🌐 Part of the **[mIceWriter Telemetry Ingestion Ecosystem](../README.md)**

[![Ecosystem: mIceWriter](https://img.shields.io/badge/Ecosystem-mIceWriter-blueviolet?style=flat-square)](../README.md)
[![Component: Querying Guide](https://img.shields.io/badge/Component-Querying%20Guide-orange?style=flat-square)](#)

Once the mIceWriter engine has completed its first flush cycle, the Iceberg table is registered in the catalog and its Parquet files are in object storage — ready for SQL queries. This guide covers two paths depending on your environment.

> **Latency note:** Data becomes queryable ~10 minutes after ingestion, once the jittered flush cycle completes and the Iceberg snapshot is committed to the catalog.

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

## 2. Local / Dev — Querybook via Trino

[Querybook](https://www.querybook.org/) is a SQL notebook UI — it does **not** connect to Nessie or Iceberg directly. It delegates query execution to a backend engine. For the local k3s stack, that engine is **Trino**, which has a native Iceberg catalog connector with REST catalog support (compatible with Nessie's Iceberg REST endpoint).

```
Querybook  →  Trino  →  Nessie Iceberg REST  →  MinIO (Parquet)
```

### Step 1 — Deploy Trino into the local cluster

Trino is not included in `micewriter-local-infra` by default and must be added. Add a Helm release using the official [trinodb/trino](https://trinodb.github.io/charts/) chart with the following catalog configuration:

```yaml
# values-trino.yaml (add to micewriter-local-infra)
additionalCatalogs:
  iceberg: |
    connector.name=iceberg
    iceberg.catalog.type=rest
    iceberg.rest-catalog.uri=http://nessie.micewriter-infra.svc.cluster.local:19120/iceberg/v1
    fs.native-s3.enabled=true
    s3.endpoint=http://minio.micewriter-infra.svc.cluster.local:9000
    s3.region=us-east-1
    s3.aws-access-key=micewriter
    s3.aws-secret-key=micewriter123
    s3.path-style-access=true

service:
  type: NodePort
```

Install the chart and expose the coordinator externally (NodePort or Ingress) so Querybook can reach it:

```powershell
helm repo add trino https://trinodb.github.io/charts
helm upgrade --install trino trino/trino \
  --namespace micewriter-infra \
  --values values-trino.yaml
```

Verify Trino is healthy before proceeding:

```powershell
curl http://k8s-node-1.local:<trino-port>/v1/info
# → {"nodeVersion":{"version":"..."}, "starting":false, ...}
```

### Step 2 — Add Trino as a query engine in Querybook

In the Querybook **Admin UI** (`/admin/query_engine/`):

| Field | Value |
|---|---|
| **Name** | `trino-local` (or any label) |
| **Language** | `trino` |
| **Host** | `k8s-node-1.local` |
| **Port** | `<trino NodePort>` |
| **Catalog** | `iceberg` |
| **Schema** | `micewriter` (matches `CATALOG_NAMESPACE` in the engine config) |

### Step 3 — Query in a Querybook DataDoc

Open a new DataDoc, select the `trino-local` engine, and run:

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
* **Architecture Hub:** [micewriter-hub](../README.md)
* **System Overview:** [system-overview](system-overview.md)
* **Rust Sidecar Engine:** [micewriter-engine](micewriter-engine.md)
* **Java SDK:** [micewriter-sdk-java](micewriter-sdk-java.md)
* **Kubernetes Webhook:** [micewriter-k8s-injector](micewriter-k8s-injector.md)
* **Local Data Lake:** [micewriter-local-infra](micewriter-local-infra.md)
* **Reference Testing App:** [micewriter-sandbox](micewriter-sandbox.md)
