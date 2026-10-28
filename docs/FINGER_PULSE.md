# Finger Pulse — Biostar ingest

Direct pull from Biostar linked server into schema `hr`, without the legacy PHP middleware (`192.168.211.22:5001`) and without truncate-staging every hour.

## Flow

```text
BIOSTAR_131_100.biostar2ac
  dbo.SP_GET_DATA_FINGER / SP_GET_DATA_FINGER_OAMS
        │  (Node: EXEC four-part name — no INSERT…EXEC / MSDTC)
        ▼
hr.finger_pulse_stage_non_oams / _oams   (bulk, per batch_id)
        │
        ▼
hr.FINGER_PULSE_SP @ACTION_SP=PROMOTE
        ├─► hr.finger_pulse_raw     (append-only, content_hash UNIQUE)
        ├─► hr.workers_finger_log   (canonical non-OAMS punches)
        ├─► hr.workers_finger_oams  (canonical OAMS IN/OUT)
        ├─► hr.finger_pulse_run
        └─► hr.finger_pulse_watermark
                │
                ▼
        hr.DASHBOARD_SP ATTENDANCE (unchanged contract)
```

Why Node pulls (not `INSERT…EXEC` inside the SP): on this host, linked-server `remote proc transaction promotion` is **on** and the app login cannot run `sp_serveroption` to turn it off. `INSERT…EXEC` remote then fails with MSDTC `0x80070057`. Pulling resultsets in Node and bulk-staging avoids DTC entirely.

## Prerequisites

1. Linked server **`BIOSTAR_131_100`** on the SQL Server that hosts MYHR / schema `hr`.
2. Remote database **`biostar2ac`** with:
   - `dbo.SP_GET_DATA_FINGER @from, @to`
   - `dbo.SP_GET_DATA_FINGER_OAMS @from, @to`
3. App/`DB_*` login can `EXECUTE` those remote SPs and write `hr.finger_pulse_*` / finger canonical tables.
4. Apply scripts: `node scripts/hr/run_migrate.js 92 93`
5. Config row: `hr.finger_pulse_config` (id = 1). Defaults:
   - `linked_server = BIOSTAR_131_100`
   - `remote_database = biostar2ac`
   - `by_jobsite = 1`
   - `raw_retain_days = 90`
   - `enabled = 1`

Disable without dropping objects: `UPDATE hr.finger_pulse_config SET enabled = 0 WHERE id = 1`.

Optional (DBA only): if you later set  
`EXEC sp_serveroption N'BIOSTAR_131_100', N'remote proc transaction promotion', N'false'`  
a pure-SQL pull becomes possible — current code still uses the Node path.

## Modes

| Mode | Window | Intent |
|------|--------|--------|
| **pulse** | shift-date today (before 07:30 local → yesterday) | Near-realtime (~every 15 min) |
| **reconcile** | D-1 … D-3 vs shift-date | Catch late device dumps |
| **backfill** | explicit dates | Manual repair / first load |
| **status** | — | Watermarks + last 20 runs + config |
| **purge** | raw older than `raw_retain_days` | Trim append-only ledger |

Idempotency:

- Raw: `content_hash` (SHA2-256). Duplicate events skipped.
- Log: insert if natural key `(jobsite, nuserid, ndatetime, time, ntnaevent)` missing.
- OAMS: `MERGE` on `(jobsite, nrp, tanggal)`; updates when IN/OUT/attrs change.

OAMS filter (same as legacy cron): keep rows with `FINGER_IN` and `AREA` set.

## Node runner (supported orchestrator)

```bash
node scripts/hr/run_finger_pulse.js status
node scripts/hr/run_finger_pulse.js pulse
node scripts/hr/run_finger_pulse.js reconcile
node scripts/hr/run_finger_pulse.js backfill 2026-10-20 2026-10-25
node scripts/hr/run_finger_pulse.js purge
```

Optional env: `FINGER_PULSE_JOBSITE=1`.

Probe Biostar shapes:

```bash
node scripts/hr/probe_biostar_finger.js 2026-10-25
```

## Scheduling

Prefer **Windows Task Scheduler** or **SQL Agent CmdExec** calling Node (not pure T-SQL `EXEC` of remote SPs):

**Every 15 minutes — pulse**

```text
node D:\path\to\myhr-backend\scripts\hr\run_finger_pulse.js pulse
```

**Daily ~23:00 — reconcile**

```text
node D:\path\to\myhr-backend\scripts\hr\run_finger_pulse.js reconcile
```

**Weekly — purge**

```text
node D:\path\to\myhr-backend\scripts\hr\run_finger_pulse.js purge
```

Template comments: `scripts/hr/94_finger_pulse_sqlagent.sql`.

## HTTP endpoints

| Method | Path | Role |
|--------|------|------|
| GET | `/api/hr/finger-pulse/status` | Watermarks + recent runs (`STATUS`) |
| GET | `/api/hr/finger-pulse?date=&q=&source=&completeness=&page=` | Person-day gabungan Non OAMS + OAMS (`SELECT`); `meta.summary` + `meta.by_structure` (KPI per dept/section) |
| GET | `/api/hr/finger-pulse/punches?date=&nrp=` | Timeline punch mesin (`PUNCHES`) |
| POST | `/api/hr/finger-pulse/run` | Manual ingest: same as CLI (`pulse` \| `reconcile` \| `backfill`) |

`POST /run` body:

```json
{ "action": "pulse" }
{ "action": "reconcile" }
{ "action": "backfill", "date_from": "2026-10-20", "date_to": "2026-10-25" }
```

- Auth: JWT + `superadmin` / `sa` / `hr_administrator` only.
- One run at a time (409 if busy). Backfill max 31 days. Can take several minutes (Biostar pull).
- Shared implementation: `services/fingerPulseRunner.js` (CLI + API). Cron on the server should still call the CLI / Task Scheduler — the UI is for manual trial.

UI: React page `/reconciliation/finger-pulse` (`hr_finger_pulse`). Viewer is read for all with `can_read`; the **Manual run** panel is only for the roles above.

`source`: `all` \| `machine` \| `oams` \| `both`  
`completeness`: `all` \| `complete` \| `missing_out` \| `machine_only` \| `oams_only`

## Scripts

| File | Role |
|------|------|
| `92_finger_pulse.sql` | DDL config / watermark / run / raw / stage |
| `93_finger_pulse_sp.sql` | `hr.FINGER_PULSE_SP` (`PROMOTE` / `STATUS` / `PURGE`) |
| `94_finger_pulse_sqlagent.sql` | Schedule templates (CmdExec Node) |
| `run_finger_pulse.js` | CLI wrapper → `services/fingerPulseRunner.js` |
| `services/fingerPulseRunner.js` | Pull + stage + PROMOTE (CLI + `POST /run`) |
| `probe_biostar_finger.js` | Sample remote SP shapes |

## Not in scope (phase 2)

Finger Signal anomaly hints (`missing_out`, etc.) for Personalia UI — do not auto-create finger-error submissions.
