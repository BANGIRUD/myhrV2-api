import { getConnection, sql } from '../config/database.js';
import { qualifyProcedureName } from '../config/databaseSchema.js';
import {
  parseIdList,
  resolveSectionScope,
  scopeToCsv,
} from '../services/hrDashboardScope.js';

const SHIFTS = new Set(['all', 'day', 'night']);

function jobsiteOf(req) {
  return Number(req.user?.by_jobsite) || 1;
}

/** Actor for audit columns — hr.users.id */
function actorOf(req) {
  const id = Number(req.user?.id);
  return Number.isFinite(id) && id > 0 ? id : null;
}

function pad(n) {
  return String(n).padStart(2, '0');
}

/**
 * Shift day (port of legacy get_date_shift): until 07:30 the night shift of the
 * previous calendar day is still "today". Returns YYYYMMDD (language-safe for DATETIME).
 */
function currentShiftDateCompact(now = new Date()) {
  const d = new Date(now);
  const minutes = d.getHours() * 60 + d.getMinutes();
  if (minutes <= 7 * 60 + 30) d.setDate(d.getDate() - 1);
  return `${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}`;
}

/** `YYYY-MM-DD` (or `YYYY-MM`) → `YYYYMMDD`; null when invalid. */
function compactDate(input, { monthOnly = false } = {}) {
  const raw = String(input ?? '').trim();
  const match = monthOnly
    ? /^(\d{4})-(\d{2})(?:-(\d{2}))?$/.exec(raw)
    : /^(\d{4})-(\d{2})-(\d{2})$/.exec(raw);
  if (!match) return null;
  const [, y, m, d] = match;
  const day = monthOnly ? '01' : d;
  const check = new Date(Number(y), Number(m) - 1, Number(day));
  if (
    check.getFullYear() !== Number(y) ||
    check.getMonth() !== Number(m) - 1 ||
    check.getDate() !== Number(day)
  ) {
    return null;
  }
  return `${y}${m}${day}`;
}

async function executeDashboardSp(req, action, params = {}) {
  const scope = await resolveSectionScope(req.user);
  const pool = await getConnection();
  const request = pool.request().input('ACTION_SP', sql.NVarChar, action);

  const inputs = {
    ...params,
    SCOPE_SECTIONS: scopeToCsv(scope),
    BY_USER: actorOf(req),
    BY_JOBSITE: jobsiteOf(req),
  };
  for (const [key, value] of Object.entries(inputs)) {
    if (value === undefined) continue;
    if (key === 'DATE') request.input(key, sql.VarChar(8), value);
    else if (key === 'BY_USER') request.input(key, sql.Int, value);
    else request.input(key, value);
  }

  const result = await request.execute(qualifyProcedureName('DASHBOARD_SP', 'hr'));
  return {
    rows: result.recordsets?.[0] || [],
    total: result.recordsets?.[1]?.[0]?.total_count ?? 0,
    scope,
  };
}

function structureFilters(req) {
  return {
    DEPARTMENT: parseIdList(req.query.department).join(','),
    SECTION: parseIdList(req.query.section).join(','),
  };
}

function handleError(res, error) {
  res.status(500).json({ success: false, message: 'Server error', error: error.message });
}

function badRequest(res, message) {
  res.status(400).json({ success: false, message });
}

function scopeMeta(scope, extra) {
  return {
    ...extra,
    scoped: !scope.unrestricted,
    scope_sections: scope.unrestricted ? null : scope.sectionIds.length,
  };
}

/** GET /api/dashboard/attendance?date=YYYY-MM-DD&shift=all|day|night&department=&section= */
export async function getAttendance(req, res) {
  try {
    const shift = String(req.query.shift || 'all').toLowerCase();
    if (!SHIFTS.has(shift)) return badRequest(res, 'shift must be all, day, or night');

    const date =
      req.query.date === undefined || req.query.date === ''
        ? currentShiftDateCompact()
        : compactDate(req.query.date);
    if (!date) return badRequest(res, 'date must be YYYY-MM-DD');

    const { rows, total, scope } = await executeDashboardSp(req, 'ATTENDANCE', {
      DATE: date,
      SHIFT: shift,
      ...structureFilters(req),
    });

    res.json({
      success: true,
      message: 'Fetched attendance',
      data: rows,
      meta: scopeMeta(scope, {
        total,
        date: `${date.slice(0, 4)}-${date.slice(4, 6)}-${date.slice(6, 8)}`,
        shift,
      }),
    });
  } catch (error) {
    handleError(res, error);
  }
}

/** GET /api/dashboard/work-pattern?month=YYYY-MM&department=&section= */
export async function getWorkPattern(req, res) {
  try {
    const month =
      req.query.month === undefined || req.query.month === ''
        ? compactDate(currentShiftDateCompact().replace(/^(\d{4})(\d{2}).*/, '$1-$2'), {
            monthOnly: true,
          })
        : compactDate(req.query.month, { monthOnly: true });
    if (!month) return badRequest(res, 'month must be YYYY-MM');

    const { rows, total, scope } = await executeDashboardSp(req, 'POLA_KERJA', {
      DATE: month,
      ...structureFilters(req),
    });

    res.json({
      success: true,
      message: 'Fetched pola kerja',
      data: rows,
      meta: scopeMeta(scope, { total, month: `${month.slice(0, 4)}-${month.slice(4, 6)}` }),
    });
  } catch (error) {
    handleError(res, error);
  }
}

/** GET /api/dashboard/employee-unfit?department=&section= */
export async function getEmployeeUnfit(req, res) {
  try {
    const { rows, total, scope } = await executeDashboardSp(req, 'UNFIT', {
      ...structureFilters(req),
    });
    res.json({
      success: true,
      message: 'Fetched employee unfit',
      data: rows,
      meta: scopeMeta(scope, { total }),
    });
  } catch (error) {
    handleError(res, error);
  }
}
