/**
 * Parity check for hr.DASHBOARD_SP: runs the same call with @SOURCE='dbo' and
 * @SOURCE='hr' on the LOCAL database and diffs the rows. Read-only.
 *
 * Usage:
 *   node scripts/hr/dashboard_parity.js UNFIT
 *   node scripts/hr/dashboard_parity.js POLA_KERJA 2026-06
 *   node scripts/hr/dashboard_parity.js ATTENDANCE 2026-06-15 all
 *   node scripts/hr/dashboard_parity.js ALL
 *
 * Args: ACTION [date|month] [shift]. Optional filters via env: PARITY_DEPT, PARITY_SECT (CSV ids).
 * Exit code 1 when any case differs.
 * Note: ATTENDANCE / POLA_KERJA take several seconds per call (legacy bridge).
 */
import { getConnection, sql } from '../../config/database.js';

const ACTIONS = ['UNFIT', 'POLA_KERJA', 'ATTENDANCE'];
const DEFAULT_DATE = '2026-06-15';

const [actionArg = 'ALL', dateArg = DEFAULT_DATE, shiftArg = 'all'] = process.argv.slice(2);
const actions = actionArg.toUpperCase() === 'ALL' ? ACTIONS : [actionArg.toUpperCase()];

function compactDate(input) {
  const m = /^(\d{4})-(\d{2})(?:-(\d{2}))?$/.exec(input);
  if (!m) throw new Error(`Bad date "${input}" (use YYYY-MM or YYYY-MM-DD)`);
  return `${m[1]}${m[2]}${m[3] || '01'}`;
}

async function run(pool, action, source, params) {
  const req = pool
    .request()
    .input('ACTION_SP', sql.NVarChar, action)
    .input('SOURCE', sql.NVarChar, source)
    .input('BY_USER', sql.Int, null)
    .input('BY_JOBSITE', sql.Int, 1)
    .input('SCOPE_SECTIONS', sql.NVarChar(sql.MAX), '')
    .input('DEPARTMENT', sql.NVarChar, process.env.PARITY_DEPT || '')
    .input('SECTION', sql.NVarChar, process.env.PARITY_SECT || '');
  if (params.date) req.input('DATE', sql.VarChar(8), params.date);
  if (params.shift) req.input('SHIFT', sql.NVarChar, params.shift);
  const t0 = Date.now();
  const result = await req.execute('hr.DASHBOARD_SP');
  return { rows: result.recordsets?.[0] || [], ms: Date.now() - t0 };
}

function normalise(value) {
  if (value instanceof Date) return value.toISOString().slice(0, 19);
  if (typeof value === 'string') return value.trim();
  return value ?? null;
}

function keyOf(row) {
  return JSON.stringify(
    Object.keys(row)
      .sort()
      .map((k) => [k, normalise(row[k])]),
  );
}

function diff(a, b) {
  const count = (rows) =>
    rows.reduce((m, r) => {
      const k = keyOf(r);
      m.set(k, (m.get(k) || 0) + 1);
      return m;
    }, new Map());
  const ca = count(a);
  const cb = count(b);
  const onlyA = [];
  const onlyB = [];
  for (const [k, n] of ca) if ((cb.get(k) || 0) < n) onlyA.push(k);
  for (const [k, n] of cb) if ((ca.get(k) || 0) < n) onlyB.push(k);
  return { onlyA, onlyB };
}

const pool = await getConnection();
let failed = false;

for (const action of actions) {
  const params = {};
  if (action === 'POLA_KERJA') params.date = compactDate(dateArg.slice(0, 7));
  if (action === 'ATTENDANCE') {
    params.date = compactDate(dateArg.length === 7 ? `${dateArg}-01` : dateArg);
    params.shift = shiftArg;
  }

  const dbo = await run(pool, action, 'dbo', params);
  const hr = await run(pool, action, 'hr', params);
  const { onlyA, onlyB } = diff(dbo.rows, hr.rows);
  const same = onlyA.length === 0 && onlyB.length === 0;
  if (!same) failed = true;

  console.log(
    `${same ? 'PASS' : 'FAIL'}  ${action.padEnd(10)} dbo=${dbo.rows.length} rows (${dbo.ms}ms)  hr=${hr.rows.length} rows (${hr.ms}ms)`,
  );
  if (!same) {
    console.log(`  only in dbo: ${onlyA.length}, only in hr: ${onlyB.length}`);
    for (const k of onlyA.slice(0, 5)) console.log('   dbo>', k);
    for (const k of onlyB.slice(0, 5)) console.log('   hr >', k);
  }
}

await sql.close();
process.exit(failed ? 1 : 0);
