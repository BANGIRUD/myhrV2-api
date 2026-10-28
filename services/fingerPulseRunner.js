/**
 * Finger Pulse orchestrator — pull Biostar via linked server, stage, PROMOTE.
 * Shared by CLI (`scripts/hr/run_finger_pulse.js`) and POST /api/hr/finger-pulse/run.
 */
import { randomUUID } from 'crypto';
import { sql } from '../config/database.js';
import { qualifyProcedureName } from '../config/databaseSchema.js';

export const FINGER_PULSE_MODES = ['pulse', 'reconcile', 'backfill', 'status', 'purge'];
export const FINGER_PULSE_RUN_ACTIONS = ['pulse', 'reconcile', 'backfill'];

const MAX_BACKFILL_DAYS = 31;
/** mssql v12: use pool.request({ requestTimeout }) — assigning request.timeout is ignored. */
const PULSE_REQ_MS = 900000;
const PROMOTE_REQ_MS = 600000;
const STATUS_REQ_MS = 120000;

function pulseRequest(pool, requestTimeout = PULSE_REQ_MS) {
  return pool.request({ requestTimeout });
}

/** @type {{ mode: string, startedAt: string, batchId?: string } | null} */
let activeRun = null;

export function getFingerPulseRunLock() {
  return activeRun ? { ...activeRun } : null;
}

function ymd(d) {
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, '0');
  const day = String(d.getDate()).padStart(2, '0');
  return `${y}-${m}-${day}`;
}

/** Shift date: before 07:30 local → previous calendar day. */
export function fingerPulseShiftDate(now = new Date()) {
  const d = new Date(now);
  if (d.getHours() < 7 || (d.getHours() === 7 && d.getMinutes() < 30)) {
    d.setDate(d.getDate() - 1);
  }
  return ymd(d);
}

function eachDate(fromStr, toStr) {
  const out = [];
  const cur = new Date(`${fromStr}T00:00:00`);
  const end = new Date(`${toStr}T00:00:00`);
  while (cur <= end) {
    out.push(ymd(cur));
    cur.setDate(cur.getDate() + 1);
  }
  return out;
}

export function resolveFingerPulseWindow(mode, dateFrom, dateTo) {
  if (mode === 'backfill') {
    if (!dateFrom || !dateTo) {
      throw Object.assign(new Error('backfill requires date_from and date_to (YYYY-MM-DD)'), {
        code: 'BAD_WINDOW',
      });
    }
    if (!/^\d{4}-\d{2}-\d{2}$/.test(dateFrom) || !/^\d{4}-\d{2}-\d{2}$/.test(dateTo)) {
      throw Object.assign(new Error('Dates must be YYYY-MM-DD'), { code: 'BAD_WINDOW' });
    }
    if (dateFrom > dateTo) {
      throw Object.assign(new Error('date_from must be ≤ date_to'), { code: 'BAD_WINDOW' });
    }
    const days = eachDate(dateFrom, dateTo);
    if (days.length > MAX_BACKFILL_DAYS) {
      throw Object.assign(
        new Error(`backfill max ${MAX_BACKFILL_DAYS} days (got ${days.length})`),
        { code: 'BAD_WINDOW' },
      );
    }
    return { from: dateFrom, to: dateTo, days };
  }

  const today = fingerPulseShiftDate();
  if (mode === 'pulse') {
    return { from: today, to: today, days: [today] };
  }

  // reconcile: D-3 .. D-1
  const d1 = new Date(`${today}T00:00:00`);
  d1.setDate(d1.getDate() - 1);
  const d3 = new Date(`${today}T00:00:00`);
  d3.setDate(d3.getDate() - 3);
  const from = ymd(d3);
  const to = ymd(d1);
  return { from, to, days: eachDate(from, to) };
}

/**
 * Client timeout / killed session can leave finger_pulse_run stuck at RUNNING
 * (PROMOTE inserts RUNNING then never reaches SUCCESS/FAILED).
 * Only closes rows when the ingest applock is free (no live PROMOTE on SQL).
 */
export async function closeStaleFingerPulseRuns(pool, olderThanMinutes = 5) {
  const mins = Math.max(1, Number(olderThanMinutes) || 5);
  const r = await pulseRequest(pool, STATUS_REQ_MS)
    .input('mins', sql.Int, mins)
    .query(`
      DECLARE @lock INT;
      DECLARE @closed INT = 0;

      EXEC @lock = sp_getapplock
        @Resource = N'hr.finger_pulse.ingest',
        @LockMode = N'Exclusive',
        @LockOwner = N'Session',
        @LockTimeout = 0;

      IF @lock >= 0
      BEGIN
        UPDATE hr.finger_pulse_run
        SET finished_at = SYSUTCDATETIME(),
            status = N'FAILED',
            error_message = LEFT(
              N'Stale RUNNING: client timeout/abort before PROMOTE finished (auto-cleanup).',
              1000
            )
        WHERE status = N'RUNNING'
          AND started_at < DATEADD(MINUTE, -@mins, SYSUTCDATETIME());

        SET @closed = @@ROWCOUNT;

        EXEC sp_releaseapplock
          @Resource = N'hr.finger_pulse.ingest',
          @LockOwner = N'Session';
      END

      SELECT @closed AS closed, @lock AS lock_result;
    `);
  const row = r.recordset?.[0] ?? r.recordsets?.[0]?.[0];
  return Number(row?.closed ?? 0);
}

async function loadConfig(pool) {
  const r = await pulseRequest(pool, STATUS_REQ_MS).query(`
    SELECT linked_server, remote_database, by_jobsite, enabled
    FROM hr.finger_pulse_config WHERE id = 1
  `);
  const row = r.recordset?.[0];
  if (!row) throw new Error('hr.finger_pulse_config id=1 missing');
  const jobsiteEnv = process.env.FINGER_PULSE_JOBSITE
    ? Number(process.env.FINGER_PULSE_JOBSITE)
    : null;
  return {
    linkedServer: row.linked_server || 'BIOSTAR_131_100',
    remoteDb: row.remote_database || 'biostar2ac',
    byJobsite:
      jobsiteEnv != null && Number.isFinite(jobsiteEnv)
        ? jobsiteEnv
        : Number(row.by_jobsite) || 1,
    enabled: !!row.enabled,
  };
}

async function execRemote(pool, linkedServer, remoteDb, procName, day) {
  const safeServer = String(linkedServer).replace(/[^a-zA-Z0-9_]/g, '');
  const safeDb = String(remoteDb).replace(/[^a-zA-Z0-9_]/g, '');
  const safeProc = String(procName).replace(/[^a-zA-Z0-9_]/g, '');
  if (!/^\d{4}-\d{2}-\d{2}$/.test(day)) {
    throw new Error(`Invalid day: ${day}`);
  }
  const request = pulseRequest(pool, PULSE_REQ_MS);
  const sqlText = `EXEC [${safeServer}].[${safeDb}].dbo.[${safeProc}] N'${day}', N'${day}'`;
  const result = await request.query(sqlText);
  return result.recordset || [];
}

async function clearStage(pool, batchId) {
  await pulseRequest(pool, PROMOTE_REQ_MS)
    .input('batch', sql.UniqueIdentifier, batchId)
    .query(`
      DELETE FROM hr.finger_pulse_stage_non_oams WHERE batch_id = @batch;
      DELETE FROM hr.finger_pulse_stage_oams WHERE batch_id = @batch;
    `);
}

function toDateOnly(value) {
  if (value == null || value === '') return null;
  if (value instanceof Date && !Number.isNaN(value.getTime())) {
    return ymd(value);
  }
  const s = String(value);
  if (/^\d{4}-\d{2}-\d{2}/.test(s)) return s.slice(0, 10);
  const d = new Date(s);
  return Number.isNaN(d.getTime()) ? null : ymd(d);
}

function toDateTime(value) {
  if (value == null || value === '') return null;
  if (value instanceof Date && !Number.isNaN(value.getTime())) return value;
  const d = new Date(String(value).replace(' ', 'T'));
  return Number.isNaN(d.getTime()) ? null : d;
}

async function stageNonOams(pool, batchId, rows) {
  if (!rows.length) return 0;
  const table = new sql.Table('hr.finger_pulse_stage_non_oams');
  table.create = false;
  table.columns.add('batch_id', sql.UniqueIdentifier, { nullable: false });
  table.columns.add('nEventLogIdn', sql.BigInt, { nullable: true });
  table.columns.add('nDateTime', sql.DateTime2, { nullable: true });
  table.columns.add('TIME', sql.NVarChar(30), { nullable: true });
  table.columns.add('IP_ADDRESS', sql.NVarChar(50), { nullable: true });
  table.columns.add('sIP', sql.NVarChar(50), { nullable: true });
  table.columns.add('nUserID', sql.Int, { nullable: true });
  table.columns.add('nUserName', sql.NVarChar(250), { nullable: true });
  table.columns.add('nTnaEvent', sql.Int, { nullable: true });
  table.columns.add('SERVER_NAME', sql.NVarChar(50), { nullable: true });

  for (const row of rows) {
    table.rows.add(
      batchId,
      row.nEventLogIdn ?? null,
      toDateTime(row.nDateTime),
      row.TIME != null ? String(row.TIME) : null,
      row.IP_ADDRESS != null ? String(row.IP_ADDRESS) : null,
      row.sIP != null ? String(row.sIP) : null,
      row.nUserID ?? null,
      row.nUserName != null ? String(row.nUserName) : null,
      row.nTnaEvent ?? null,
      row.SERVER_NAME != null ? String(row.SERVER_NAME) : null,
    );
  }

  await pulseRequest(pool, PROMOTE_REQ_MS).bulk(table);
  return rows.length;
}

async function stageOams(pool, batchId, rows) {
  const filtered = rows.filter(
    (r) => r.FINGER_IN != null && r.FINGER_IN !== '' && r.AREA != null && r.AREA !== '',
  );
  if (!filtered.length) return 0;

  const table = new sql.Table('hr.finger_pulse_stage_oams');
  table.create = false;
  table.columns.add('batch_id', sql.UniqueIdentifier, { nullable: false });
  table.columns.add('TANGGAL', sql.Date, { nullable: true });
  table.columns.add('NRP', sql.VarChar(25), { nullable: true });
  table.columns.add('NAMA', sql.VarChar(55), { nullable: true });
  table.columns.add('shift', sql.VarChar(10), { nullable: true });
  table.columns.add('FINGER_IN', sql.DateTime, { nullable: true });
  table.columns.add('FINGER_OUT', sql.DateTime, { nullable: true });
  table.columns.add('UnitJigsaw', sql.VarChar(20), { nullable: true });
  table.columns.add('Excavator', sql.VarChar(35), { nullable: true });
  table.columns.add('Type', sql.VarChar(50), { nullable: true });
  table.columns.add('AREA', sql.VarChar(100), { nullable: true });
  table.columns.add('STATUS_UNIT', sql.VarChar(15), { nullable: true });
  table.columns.add('HASIL_BUGSEL', sql.VarChar(150), { nullable: true });
  table.columns.add('KESIMPULAN_BUGSEL', sql.VarChar(35), { nullable: true });

  for (const row of filtered) {
    table.rows.add(
      batchId,
      toDateOnly(row.TANGGAL),
      row.NRP != null ? String(row.NRP).slice(0, 25) : null,
      row.NAMA != null ? String(row.NAMA).slice(0, 55) : null,
      row.shift != null ? String(row.shift).slice(0, 10) : null,
      toDateTime(row.FINGER_IN),
      toDateTime(row.FINGER_OUT),
      row.UnitJigsaw != null ? String(row.UnitJigsaw).slice(0, 20) : null,
      row.Excavator != null ? String(row.Excavator).slice(0, 35) : null,
      row.Type != null ? String(row.Type).slice(0, 50) : null,
      row.AREA != null ? String(row.AREA).slice(0, 100) : null,
      row.STATUS_UNIT != null ? String(row.STATUS_UNIT).slice(0, 15) : null,
      row.HASIL_BUGSEL != null ? String(row.HASIL_BUGSEL).slice(0, 150) : null,
      row.KESIMPULAN_BUGSEL != null
        ? String(row.KESIMPULAN_BUGSEL).slice(0, 35)
        : null,
    );
  }

  await pulseRequest(pool, PROMOTE_REQ_MS).bulk(table);
  return filtered.length;
}

async function promote(pool, { batchId, modeName, dateFrom, dateTo, byJobsite }) {
  const request = pulseRequest(pool, PROMOTE_REQ_MS);
  request.input('ACTION_SP', sql.NVarChar, 'PROMOTE');
  request.input('BATCH_ID', sql.UniqueIdentifier, batchId);
  request.input('MODE', sql.NVarChar, modeName.toUpperCase());
  request.input('DATE_FROM', sql.Date, dateFrom);
  request.input('DATE_TO', sql.Date, dateTo);
  request.input('BY_JOBSITE', sql.Int, byJobsite);
  const proc = qualifyProcedureName('FINGER_PULSE_SP', 'hr');
  const result = await request.execute(proc);
  return result.recordset?.[0] || result.recordsets?.[0]?.[0] || null;
}

/**
 * STATUS / PURGE via FINGER_PULSE_SP (no Biostar pull).
 * @param {import('mssql').ConnectionPool} pool
 * @param {'status'|'purge'} mode
 */
export async function runFingerPulseSpAction(pool, mode) {
  if (mode === 'status') {
    await closeStaleFingerPulseRuns(pool, 5);
  }
  const action = mode === 'purge' ? 'PURGE' : 'STATUS';
  const request = pulseRequest(pool, STATUS_REQ_MS);
  request.input('ACTION_SP', sql.NVarChar, action);
  if (process.env.FINGER_PULSE_JOBSITE) {
    request.input('BY_JOBSITE', sql.Int, Number(process.env.FINGER_PULSE_JOBSITE));
  }
  const proc = qualifyProcedureName('FINGER_PULSE_SP', 'hr');
  const result = await request.execute(proc);
  const sets = result.recordsets || [];
  if (mode === 'status') {
    return {
      success: true,
      watermarks: sets[0] || [],
      recent_runs: sets[1] || [],
      config: sets[2]?.[0] || null,
    };
  }
  const row = sets[0]?.[0] || null;
  return {
    success: row?.success !== false,
    result: row,
  };
}

/**
 * Pull + stage + PROMOTE for pulse | reconcile | backfill.
 *
 * @param {import('mssql').ConnectionPool} pool
 * @param {{ mode: 'pulse'|'reconcile'|'backfill', dateFrom?: string|null, dateTo?: string|null, log?: (msg: string, extra?: unknown) => void }} opts
 */
export async function runFingerPulseIngest(pool, opts) {
  const mode = String(opts.mode || '').toLowerCase();
  if (!FINGER_PULSE_RUN_ACTIONS.includes(mode)) {
    throw Object.assign(new Error(`Unsupported ingest mode: ${mode}`), { code: 'BAD_MODE' });
  }

  if (activeRun) {
    const err = new Error(
      `Finger Pulse already running (${activeRun.mode} since ${activeRun.startedAt})`,
    );
    err.code = 'BUSY';
    err.lock = { ...activeRun };
    throw err;
  }

  const log = opts.log || (() => {});
  const window = resolveFingerPulseWindow(mode, opts.dateFrom || null, opts.dateTo || null);
  const staleClosed = await closeStaleFingerPulseRuns(pool, 5);
  if (staleClosed > 0) log(`closed ${staleClosed} stale RUNNING run(s)`);
  const cfg = await loadConfig(pool);

  if (!cfg.enabled) {
    throw Object.assign(new Error('Finger Pulse disabled in hr.finger_pulse_config'), {
      code: 'DISABLED',
    });
  }

  const batchId = randomUUID();
  activeRun = {
    mode,
    startedAt: new Date().toISOString(),
    batchId,
  };

  try {
    log(`Finger Pulse ${mode}`, {
      from: window.from,
      to: window.to,
      days: window.days.length,
      batchId,
      linked: `${cfg.linkedServer}.${cfg.remoteDb}`,
    });

    let stagedNo = 0;
    let stagedOa = 0;
    const dayLogs = [];

    for (const day of window.days) {
      log(`pull ${day} non_oams…`);
      const nonOams = await execRemote(
        pool,
        cfg.linkedServer,
        cfg.remoteDb,
        'SP_GET_DATA_FINGER',
        day,
      );
      const nNo = await stageNonOams(pool, batchId, nonOams);
      stagedNo += nNo;

      log(`pull ${day} oams…`);
      const oams = await execRemote(
        pool,
        cfg.linkedServer,
        cfg.remoteDb,
        'SP_GET_DATA_FINGER_OAMS',
        day,
      );
      const nOa = await stageOams(pool, batchId, oams);
      stagedOa += nOa;

      dayLogs.push({
        date: day,
        non_oams_pulled: nonOams.length,
        non_oams_staged: nNo,
        oams_pulled: oams.length,
        oams_staged: nOa,
      });
    }

    log('PROMOTE');
    const outcome = await promote(pool, {
      batchId,
      modeName: mode,
      dateFrom: window.from,
      dateTo: window.to,
      byJobsite: cfg.byJobsite,
    });

    const ok = !!outcome?.success;
    if (!ok) {
      try {
        await clearStage(pool, batchId);
      } catch {
        /* best-effort */
      }
    }

    return {
      success: ok,
      mode,
      date_from: window.from,
      date_to: window.to,
      batch_id: batchId,
      staged: { non_oams: stagedNo, oams: stagedOa },
      days: dayLogs,
      promote: outcome,
      message: ok
        ? `Finger Pulse ${mode} OK (${window.from} … ${window.to})`
        : outcome?.message || `Finger Pulse ${mode} failed`,
    };
  } catch (err) {
    try {
      await clearStage(pool, batchId);
      log('cleared stage for batch', batchId);
    } catch (cleanErr) {
      log('stage cleanup failed', cleanErr.message);
    }
    throw err;
  } finally {
    activeRun = null;
  }
}
