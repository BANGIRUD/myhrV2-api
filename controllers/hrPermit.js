import { unlink } from 'fs/promises';
import { basename, resolve as pathResolve, sep } from 'path';
import { getConnection, sql } from '../config/database.js';
import {
  getHrSchema,
  quoteSchemaName,
  qualifyProcedureName,
} from '../config/databaseSchema.js';
import { uploadDirectoryPath } from '../middleware/attachmentUpload.js';
import {
  parseIdList,
  resolveSectionScope,
  scopeToCsv,
} from '../services/hrDashboardScope.js';
import { buildPermitHrExportXlsx } from '../services/permitExport.js';
import { notifyPermitCreated, notifyPermitHr } from '../services/permitNotify.js';
import { logActivity } from '../services/activityLog.js';
import {
  applyReconAutoApprove,
  isReconAutoApproveLevel,
} from '../services/reconAutoApprove.js';

function schemaName() {
  return quoteSchemaName(getHrSchema());
}

function jobsiteOf(req) {
  const id = Number(req.user?.by_jobsite);
  return Number.isInteger(id) && id > 0 ? id : 1;
}

function actorOf(req) {
  const id = Number(req.user?.id);
  return Number.isInteger(id) && id > 0 ? id : null;
}

function isValidId(value) {
  const id = Number(value);
  return Number.isInteger(id) && id > 0;
}

function spResultRow(result) {
  return result.recordset?.[0] ?? null;
}

async function executeHrSp(procedureName, action, params = {}) {
  const pool = await getConnection();
  const request = pool.request().input('ACTION_SP', sql.NVarChar, action);
  for (const [key, value] of Object.entries(params)) {
    if (value === undefined) continue;
    if (key === 'BY_USER') {
      request.input(key, sql.Int, value);
      continue;
    }
    request.input(key, value);
  }
  return request.execute(qualifyProcedureName(procedureName, 'hr'));
}

function isoDate(value) {
  if (value == null || value === '') return null;
  if (value instanceof Date && !Number.isNaN(value.getTime())) {
    const y = value.getFullYear();
    const m = String(value.getMonth() + 1).padStart(2, '0');
    const d = String(value.getDate()).padStart(2, '0');
    return `${y}-${m}-${d}`;
  }
  const text = String(value).trim();
  return text ? text.slice(0, 10) : null;
}

function mapActiveRows(rows) {
  return (rows ?? []).map((row) => ({
    id: row.id,
    start_date: isoDate(row.start_date),
    end_date: isoDate(row.end_date),
    progress: row.progress ?? '',
    entered_by: row.entered_by || null,
    kind: row.kind || 'permit',
  }));
}

function activeSubmissions(result) {
  const rows = [...mapActiveRows(result?.recordsets?.[1]), ...mapActiveRows(result?.recordsets?.[2])]
    .sort((a, b) => String(b.start_date || '').localeCompare(String(a.start_date || '')))
    .slice(0, 5);
  const total = Number(result?.recordsets?.[3]?.[0]?.total_count ?? rows.length);
  return { rows, total: Number.isFinite(total) ? total : rows.length };
}

function levelCodeOf(req) {
  return String(req.user?.level_code || req.user?.level || '').trim().toLowerCase();
}

/** sis | ls | all for the Personalia queue. Superadmin sees both groups. */
function ijinWorkerScope(req) {
  const level = levelCodeOf(req);
  if (level === 'superadmin' || level === 'sa') return 'all';
  const scope = String(req.user?.worker_scope || '').trim().toLowerCase();
  if (scope === 'sis' || scope === 'ls' || scope === 'all') return scope;
  return 'none';
}

/** SIS/LS dropdown is only honored for accounts that already see both groups. */
function ijinHrStatusWorker(req) {
  if (ijinWorkerScope(req) !== 'all') return null;
  const raw = String(req.query.status_worker || '').trim().toLowerCase();
  if (raw === 'sis' || raw === 'vendor') return raw;
  return null;
}

/** GET /api/hr/roster/edit-policy — H-n window from hr.roster_edit_policy */
export async function getRosterEditPolicy(req, res) {
  try {
    const levelCode = levelCodeOf(req);
    if (!levelCode) {
      return res.status(400).json({
        success: false,
        message: 'level_code is required on the session user.',
      });
    }

    const result = await executeHrSp('ROSTER_SP', 'GET_EDIT_POLICY', {
      LEVEL_CODE: levelCode,
      BY_USER: actorOf(req),
      BY_JOBSITE: jobsiteOf(req),
    });
    const row = spResultRow(result);
    if (!row?.success) {
      return res.status(400).json({
        success: false,
        message: row?.message || 'Failed to load roster edit policy.',
      });
    }

    return res.json({
      success: true,
      message: row.message || 'Fetched roster edit policy',
      data: {
        level_code: row.level_code ?? levelCode,
        can_edit: Boolean(row.can_edit),
        allow_past: Boolean(row.allow_past),
        past_days: Number(row.past_days) || 0,
        min_editable_date: row.min_editable_date ?? null,
      },
    });
  } catch (error) {
    return res.status(500).json({
      success: false,
      message: 'Server error',
      error: error.message,
    });
  }
}

/** PUT /api/hr/roster/:id — update remark (Status Absen) only */
export async function updateRoster(req, res) {
  if (!isValidId(req.params.id)) {
    return res.status(400).json({ success: false, message: 'Invalid roster kerja id.' });
  }

  try {
    const remark = String(req.body?.remark ?? '').trim().toUpperCase();
    if (!['D', 'N', 'OFF'].includes(remark)) {
      return res.status(400).json({
        success: false,
        message: 'remark must be D, N, or OFF.',
      });
    }

    const levelCode = levelCodeOf(req);
    if (!levelCode) {
      return res.status(400).json({
        success: false,
        message: 'level_code is required on the session user.',
      });
    }

    const result = await executeHrSp('ROSTER_SP', 'UPDATE', {
      ID: Number(req.params.id),
      REMARK: remark,
      LEVEL_CODE: levelCode,
      BY_USER: actorOf(req),
      BY_JOBSITE: jobsiteOf(req),
    });

    const response = spResultRow(result);
    return res.status(response?.success ? 200 : 400).json({
      success: Boolean(response?.success),
      message: response?.message || 'Failed to update roster kerja.',
    });
  } catch (error) {
    return res.status(500).json({
      success: false,
      message: 'Server error',
      error: error.message,
    });
  }
}

/** GET /api/hr/roster/export — Excel of filtered list */
export async function exportRoster(req, res) {
  try {
    const now = new Date();
    const defaultMonth = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}`;
    const monthRaw = String(req.query.month ?? '').trim() || defaultMonth;
    if (!/^\d{4}-\d{2}$/.test(monthRaw)) {
      return res.status(400).json({
        success: false,
        message: 'month must be YYYY-MM',
      });
    }

    const scope = await resolveSectionScope(req.user);
    const result = await executeHrSp('ROSTER_SP', 'SELECT', {
      MONTH: monthRaw,
      DEPARTMENT: parseIdList(req.query.department).join(',') || null,
      SECTION: parseIdList(req.query.section).join(',') || null,
      JOB_RANK: req.query.job_rank?.trim() || null,
      SEARCH: req.query.q?.trim() || null,
      PAGE: 1,
      PAGE_SIZE: 0,
      SCOPE_SECTIONS: scopeToCsv(scope),
      BY_USER: actorOf(req),
      BY_JOBSITE: jobsiteOf(req),
    });

    const rows = result.recordsets?.[0] ?? [];
    const buffer = buildRosterExportXlsx(rows);
    const filename = `roster_${monthRaw}.xlsx`;
    res.setHeader(
      'Content-Type',
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    );
    res.setHeader('Content-Disposition', `attachment; filename="${filename}"`);
    return res.status(200).send(Buffer.from(buffer));
  } catch (error) {
    return res.status(500).json({
      success: false,
      message: 'Server error',
      error: error.message,
    });
  }
}

/** GET /api/hr/permit?month=YYYY-MM&department=&section=&job_rank=&progress=&status_worker=&q=&page=&page_size= */
export async function listPermit(req, res) {
  try {
    const now = new Date();
    const defaultMonth = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}`;
    const monthRaw = String(req.query.month ?? '').trim() || defaultMonth;
    if (!/^\d{4}-\d{2}$/.test(monthRaw)) {
      return res.status(400).json({
        success: false,
        message: 'month must be YYYY-MM',
      });
    }

    const scope = await resolveSectionScope(req.user);
    const result = await executeHrSp('PERMIT_SP', 'SELECT', {
      MONTH: monthRaw,
      DEPARTMENT: parseIdList(req.query.department).join(',') || null,
      SECTION: parseIdList(req.query.section).join(',') || null,
      JOB_RANK: req.query.job_rank?.trim() || null,
      PROGRESS: req.query.progress?.trim() || null,
      STATUS_WORKER: req.query.status_worker?.trim() || null,
      SEARCH: req.query.q?.trim() || null,
      PAGE: Number(req.query.page) || 1,
      PAGE_SIZE: Number(req.query.page_size) || 0,
      SCOPE_SECTIONS: scopeToCsv(scope),
      LEVEL_CODE: levelCodeOf(req),
      BY_USER: actorOf(req),
      BY_JOBSITE: jobsiteOf(req),
    });

    res.json({
      success: true,
      message: 'Fetched ijin',
      data: result.recordsets?.[0] ?? [],
      meta: {
        total: result.recordsets?.[1]?.[0]?.total_count ?? 0,
        month: monthRaw,
        scoped: !scope.unrestricted,
        scope_sections: scope.unrestricted ? null : scope.sectionIds.length,
        status_counts: ijinStatusCounts(result),
      },
    });
  } catch (error) {
    res.status(500).json({ success: false, message: 'Server error', error: error.message });
  }
}

export async function getPermit(req, res) {
  if (!isValidId(req.params.id)) {
    return res.status(400).json({ success: false, message: 'Invalid ijin id.' });
  }

  try {
    const result = await executeHrSp('PERMIT_SP', 'GET', {
      ID: Number(req.params.id),
      BY_JOBSITE: jobsiteOf(req),
    });
    const row = result.recordset?.[0];
    if (!row) {
      return res.status(404).json({ success: false, message: 'Permit not found.' });
    }
    return res.json({ success: true, message: 'Fetched ijin', data: row });
  } catch (error) {
    return res.status(500).json({
      success: false,
      message: 'Server error',
      error: error.message,
    });
  }
}

function ijinPayload(body = {}) {
  const category = String(body.category || '').trim();
  const endRaw = body.end_date;
  const endDate =
    endRaw === undefined || endRaw === null || String(endRaw).trim() === ''
      ? null
      : String(endRaw).trim().slice(0, 10);
  return {
    nrp: String(body.nrp || '')
      .trim()
      .toUpperCase(),
    fullName: body.full_name != null ? String(body.full_name).trim() : null,
    category,
    startDate: body.start_date
      ? String(body.start_date).trim().slice(0, 10)
      : null,
    endDate,
    description:
      body.description != null ? String(body.description).trim() : null,
  };
}

function ijinFieldsValid(payload) {
  const categoryId = Number(payload.category);
  return payload.nrp && Number.isInteger(categoryId) && categoryId > 0 && payload.startDate;
}

async function insertPermitPhotoRows(jobsite, refId, byUser, files, relDir) {
  if (!files?.length) return;
  const pool = await getConnection();
  const schema = schemaName();
  for (const file of files) {
    const relative = `${relDir}/${file.filename}`.replace(/\\/g, '/');
    const mime = String(file.mimetype || '');
    const type = mime.includes('pdf')
      ? 'pdf'
      : mime.includes('png')
        ? 'png'
        : mime.includes('gif')
          ? 'gif'
          : 'jpg';
    await pool
      .request()
      .input('BY_JOBSITE', sql.Int, jobsite)
      .input('REF_ID', sql.BigInt, refId)
      .input('PATH', sql.NVarChar(250), relative)
      .input('NAME', sql.NVarChar(250), String(file.originalname || file.filename).slice(0, 250))
      .input('FULLPATH', sql.NVarChar(250), relative)
      .input('TYPE', sql.NVarChar(25), type)
      .input('META_KEY', sql.NVarChar(50), 'evidence')
      .input('META_VALUES', sql.NVarChar(sql.MAX), mime || type)
      .input('BY_USER', sql.Int, byUser)
      .query(`
        INSERT INTO ${schema}.workers_permit_photos (
          by_jobsite, ref_id, [path], name, fullpath, [type],
          meta_key, meta_values,
          created_by, updated_at, updated_by
        )
        VALUES (
          @BY_JOBSITE, @REF_ID, @PATH, @NAME, @FULLPATH, @TYPE,
          @META_KEY, @META_VALUES,
          @BY_USER, SYSUTCDATETIME(), @BY_USER
        )
      `);
  }
}

async function cleanupUploadedFiles(files) {
  if (!files?.length) return;
  await Promise.all(
    files.map(async (file) => {
      try {
        if (file.path) await unlink(file.path);
      } catch {
        /* ignore */
      }
    }),
  );
}

/** GET /api/hr/permit/section — approval queue for Section Head / acting Unit Head */
export async function listPermitSection(req, res) {
  try {
    const now = new Date();
    const defaultMonth = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}`;
    const monthRaw = String(req.query.month ?? '').trim() || defaultMonth;
    if (!/^\d{4}-\d{2}$/.test(monthRaw)) {
      return res.status(400).json({
        success: false,
        message: 'month must be YYYY-MM',
      });
    }

    const scope = await resolveSectionScope(req.user);
    const result = await executeHrSp('PERMIT_SP', 'SELECT_SECTION', {
      MONTH: monthRaw,
      DEPARTMENT: parseIdList(req.query.department).join(',') || null,
      SECTION: parseIdList(req.query.section).join(',') || null,
      JOB_RANK: req.query.job_rank?.trim() || null,
      PROGRESS: req.query.progress?.trim() || null,
      STATUS_WORKER: req.query.status_worker?.trim() || null,
      SEARCH: req.query.q?.trim() || null,
      PAGE: Number(req.query.page) || 1,
      PAGE_SIZE: Number(req.query.page_size) || 0,
      SCOPE_SECTIONS: scopeToCsv(scope),
      BY_USER: actorOf(req),
      BY_JOBSITE: jobsiteOf(req),
    });

    res.json({
      success: true,
      message: 'Fetched ijin section queue',
      data: result.recordsets?.[0] ?? [],
      meta: {
        total: result.recordsets?.[1]?.[0]?.total_count ?? 0,
        month: monthRaw,
        scoped: !scope.unrestricted,
        scope_sections: scope.unrestricted ? null : scope.sectionIds.length,
        status_counts: ijinStatusCounts(result),
      },
    });
  } catch (error) {
    res.status(500).json({ success: false, message: 'Server error', error: error.message });
  }
}

function ijinStatusCounts(result) {
  return (result.recordsets?.[2] ?? [])
    .map((row) => ({
      label: String(row.progress || '').trim(),
      total: Number(row.total) || 0,
      people: String(row.people || '')
        .split(';;')
        .map((part) => {
          const [nrp = '', name = '', section = '', start = '', end = '', category = ''] = part.split('|');
          return {
            nrp: nrp.trim(),
            name: name.trim(),
            section: section.trim(),
            start_date: start.trim(),
            end_date: end.trim(),
            category: category.trim(),
          };
        })
        .filter((person) => person.nrp || person.name),
    }))
    .filter((row) => row.label && row.total > 0);
}

async function decidePermit(req, res, action) {
  if (!isValidId(req.params.id)) {
    return res.status(400).json({ success: false, message: 'Invalid ijin id.' });
  }
  try {
    const scope = await resolveSectionScope(req.user);
    const result = await executeHrSp('PERMIT_SP', action, {
      ID: Number(req.params.id),
      NOTE: req.body?.note != null ? String(req.body.note) : null,
      SCOPE_SECTIONS: scopeToCsv(scope),
      LEVEL_CODE: levelCodeOf(req),
      WORKER_SCOPE: ijinWorkerScope(req),
      BY_USER: actorOf(req),
      BY_JOBSITE: jobsiteOf(req),
    });
    const response = spResultRow(result);
    if (response?.success) {
      logActivity(req, {
        module: 'permit',
        action,
        recordId: Number(req.params.id),
        message: `${action} permit id=${req.params.id}`,
      });
    }
    if (response?.success && ['APPROVE_SECTION', 'APPROVE_GL', 'APPROVE_DEPT'].includes(action)) {
      notifyPermitHr(Number(req.params.id), jobsiteOf(req)).catch((notifyError) => {
        console.error('ijin hr notify failed:', notifyError.message);
      });
    }
    return res.status(response?.success ? 200 : 400).json({
      success: Boolean(response?.success),
      message: response?.message || 'Failed to update ijin.',
    });
  } catch (error) {
    return res.status(500).json({
      success: false,
      message: 'Server error',
      error: error.message,
    });
  }
}

/** POST /api/hr/permit/:id/approve-section */
export function approvePermitSection(req, res) {
  return decidePermit(req, res, 'APPROVE_SECTION');
}

/** POST /api/hr/permit/:id/reject-section */
export function rejectPermitSection(req, res) {
  return decidePermit(req, res, 'REJECT_SECTION');
}

/** GET /api/hr/permit/group — LS queue for Group Leader / Unit Head */
export async function listPermitGroup(req, res) {
  try {
    const now = new Date();
    const defaultMonth = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}`;
    const monthRaw = String(req.query.month ?? '').trim() || defaultMonth;
    if (!/^\d{4}-\d{2}$/.test(monthRaw)) {
      return res.status(400).json({
        success: false,
        message: 'month must be YYYY-MM',
      });
    }

    const scope = await resolveSectionScope(req.user);
    const result = await executeHrSp('PERMIT_SP', 'SELECT_GL', {
      MONTH: monthRaw,
      DEPARTMENT: parseIdList(req.query.department).join(',') || null,
      SECTION: parseIdList(req.query.section).join(',') || null,
      JOB_RANK: req.query.job_rank?.trim() || null,
      PROGRESS: req.query.progress?.trim() || null,
      STATUS_WORKER: req.query.status_worker?.trim() || null,
      SEARCH: req.query.q?.trim() || null,
      PAGE: Number(req.query.page) || 1,
      PAGE_SIZE: Number(req.query.page_size) || 0,
      SCOPE_SECTIONS: scopeToCsv(scope),
      BY_USER: actorOf(req),
      BY_JOBSITE: jobsiteOf(req),
    });

    res.json({
      success: true,
      message: 'Fetched ijin group queue',
      data: result.recordsets?.[0] ?? [],
      meta: {
        total: result.recordsets?.[1]?.[0]?.total_count ?? 0,
        month: monthRaw,
        scoped: !scope.unrestricted,
        scope_sections: scope.unrestricted ? null : scope.sectionIds.length,
        status_counts: ijinStatusCounts(result),
      },
    });
  } catch (error) {
    res.status(500).json({ success: false, message: 'Server error', error: error.message });
  }
}

/** POST /api/hr/permit/:id/approve-group */
export function approvePermitGroup(req, res) {
  return decidePermit(req, res, 'APPROVE_GL');
}

/** POST /api/hr/permit/:id/reject-group */
export function rejectPermitGroup(req, res) {
  return decidePermit(req, res, 'REJECT_GL');
}

/** GET /api/hr/permit/department — queue for Department Head */
export async function listPermitDepartment(req, res) {
  try {
    const now = new Date();
    const defaultMonth = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}`;
    const monthRaw = String(req.query.month ?? '').trim() || defaultMonth;
    if (!/^\d{4}-\d{2}$/.test(monthRaw)) {
      return res.status(400).json({
        success: false,
        message: 'month must be YYYY-MM',
      });
    }

    const scope = await resolveSectionScope(req.user);
    const result = await executeHrSp('PERMIT_SP', 'SELECT_DEPT', {
      MONTH: monthRaw,
      DEPARTMENT: parseIdList(req.query.department).join(',') || null,
      SECTION: parseIdList(req.query.section).join(',') || null,
      JOB_RANK: req.query.job_rank?.trim() || null,
      PROGRESS: req.query.progress?.trim() || null,
      STATUS_WORKER: req.query.status_worker?.trim() || null,
      SEARCH: req.query.q?.trim() || null,
      PAGE: Number(req.query.page) || 1,
      PAGE_SIZE: Number(req.query.page_size) || 0,
      SCOPE_SECTIONS: scopeToCsv(scope),
      BY_USER: actorOf(req),
      BY_JOBSITE: jobsiteOf(req),
    });

    res.json({
      success: true,
      message: 'Fetched ijin department queue',
      data: result.recordsets?.[0] ?? [],
      meta: {
        total: result.recordsets?.[1]?.[0]?.total_count ?? 0,
        month: monthRaw,
        scoped: !scope.unrestricted,
        scope_sections: scope.unrestricted ? null : scope.sectionIds.length,
        status_counts: ijinStatusCounts(result),
      },
    });
  } catch (error) {
    res.status(500).json({ success: false, message: 'Server error', error: error.message });
  }
}

/** GET /api/hr/permit/hr — final queue for Personalia, split by worker_scope */
export async function listPermitHr(req, res) {
  try {
    const now = new Date();
    const defaultMonth = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}`;
    const monthRaw = String(req.query.month ?? '').trim() || defaultMonth;
    if (!/^\d{4}-\d{2}$/.test(monthRaw)) {
      return res.status(400).json({
        success: false,
        message: 'month must be YYYY-MM',
      });
    }

    const result = await executeHrSp('PERMIT_SP', 'SELECT_HR', {
      MONTH: monthRaw,
      DEPARTMENT: parseIdList(req.query.department).join(',') || null,
      SECTION: parseIdList(req.query.section).join(',') || null,
      JOB_RANK: req.query.job_rank?.trim() || null,
      PROGRESS: req.query.progress?.trim() || null,
      STATUS_WORKER: ijinHrStatusWorker(req),
      SEARCH: req.query.q?.trim() || null,
      PAGE: Number(req.query.page) || 1,
      PAGE_SIZE: Number(req.query.page_size) || 0,
      LEVEL_CODE: levelCodeOf(req),
      WORKER_SCOPE: ijinWorkerScope(req),
      BY_USER: actorOf(req),
      BY_JOBSITE: jobsiteOf(req),
    });

    res.json({
      success: true,
      message: 'Fetched ijin HR queue',
      data: result.recordsets?.[0] ?? [],
      meta: {
        total: result.recordsets?.[1]?.[0]?.total_count ?? 0,
        month: monthRaw,
        scoped: false,
        worker_scope: ijinWorkerScope(req),
        status_counts: ijinStatusCounts(result),
      },
    });
  } catch (error) {
    res.status(500).json({ success: false, message: 'Server error', error: error.message });
  }
}

/** GET /api/hr/permit/hr/export — same filters as the Personalia list, all rows. */
export async function exportPermitHr(req, res) {
  try {
    const now = new Date();
    const defaultMonth = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}`;
    const monthRaw = String(req.query.month ?? '').trim() || defaultMonth;
    if (!/^\d{4}-\d{2}$/.test(monthRaw)) {
      return res.status(400).json({
        success: false,
        message: 'month must be YYYY-MM',
      });
    }

    const workerScope = ijinWorkerScope(req);
    const progress = req.query.progress?.trim() || null;
    const statusWorker = ijinHrStatusWorker(req);
    const result = await executeHrSp('PERMIT_SP', 'SELECT_HR', {
      MONTH: monthRaw,
      DEPARTMENT: parseIdList(req.query.department).join(',') || null,
      SECTION: parseIdList(req.query.section).join(',') || null,
      JOB_RANK: req.query.job_rank?.trim() || null,
      PROGRESS: progress,
      STATUS_WORKER: statusWorker,
      SEARCH: req.query.q?.trim() || null,
      PAGE: 1,
      PAGE_SIZE: 0,
      LEVEL_CODE: levelCodeOf(req),
      WORKER_SCOPE: workerScope,
      BY_USER: actorOf(req),
      BY_JOBSITE: jobsiteOf(req),
    });

    const rows = result.recordsets?.[0] ?? [];
    const buffer = buildPermitHrExportXlsx(rows, {
      month: monthRaw,
      workerScope,
      progress,
      statusWorker,
    });
    const filename = `permit_personalia_${monthRaw}.xlsx`;
    res.setHeader(
      'Content-Type',
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    );
    res.setHeader('Content-Disposition', `attachment; filename="${filename}"`);
    return res.status(200).send(Buffer.from(buffer));
  } catch (error) {
    return res.status(500).json({
      success: false,
      message: 'Server error',
      error: error.message,
    });
  }
}

/** POST /api/hr/permit/:id/approve-hr */
export function approvePermitHr(req, res) {
  return decidePermit(req, res, 'APPROVE_HR');
}

/** POST /api/hr/permit/:id/reject-hr */
export function rejectPermitHr(req, res) {
  return decidePermit(req, res, 'REJECT_HR');
}

/** POST /api/hr/permit/:id/approve-department */
export function approvePermitDepartment(req, res) {
  return decidePermit(req, res, 'APPROVE_DEPT');
}

/** POST /api/hr/permit/:id/reject-department */
export function rejectPermitDepartment(req, res) {
  return decidePermit(req, res, 'REJECT_DEPT');
}

/** GET /api/hr/permit/department-exceptions */
export async function listPermitDepartmentExceptions(req, res) {
  try {
    const result = await executeHrSp('PERMIT_SP', 'LIST_DEPT_EXCEPTION', {
      BY_USER: actorOf(req),
      BY_JOBSITE: jobsiteOf(req),
    });
    res.json({
      success: true,
      message: 'Fetched department ijin exceptions',
      data: result.recordsets?.[0] ?? [],
    });
  } catch (error) {
    res.status(500).json({ success: false, message: 'Server error', error: error.message });
  }
}

/** POST /api/hr/permit/department-exceptions */
export async function createPermitDepartmentException(req, res) {
  try {
    const result = await executeHrSp('PERMIT_SP', 'INSERT_DEPT_EXCEPTION', {
      SECTION: req.body?.section_id != null ? String(req.body.section_id) : null,
      JOB_RANK: req.body?.job_rank != null ? String(req.body.job_rank) : null,
      BY_USER: actorOf(req),
      BY_JOBSITE: jobsiteOf(req),
    });
    const response = spResultRow(result);
    return res.status(response?.success ? 201 : 400).json({
      success: Boolean(response?.success),
      message: response?.message || 'Failed to add exception.',
      data: response?.id != null ? { id: response.id } : null,
    });
  } catch (error) {
    return res.status(500).json({ success: false, message: 'Server error', error: error.message });
  }
}

/** DELETE /api/hr/permit/department-exceptions/:id */
export async function deletePermitDepartmentException(req, res) {
  if (!isValidId(req.params.id)) {
    return res.status(400).json({ success: false, message: 'Invalid exception id.' });
  }
  try {
    const result = await executeHrSp('PERMIT_SP', 'DELETE_DEPT_EXCEPTION', {
      ID: Number(req.params.id),
      BY_USER: actorOf(req),
      BY_JOBSITE: jobsiteOf(req),
    });
    const response = spResultRow(result);
    return res.status(response?.success ? 200 : 400).json({
      success: Boolean(response?.success),
      message: response?.message || 'Failed to delete exception.',
    });
  } catch (error) {
    return res.status(500).json({ success: false, message: 'Server error', error: error.message });
  }
}

/** GET /api/hr/permit/lookup?nrp= */
export async function lookupPermitWorker(req, res) {
  try {
    const nrp = String(req.query.nrp || '').trim();
    if (!nrp) {
      return res.status(400).json({ success: false, message: 'nrp is required.' });
    }

    const scope = await resolveSectionScope(req.user);
    const result = await executeHrSp('PERMIT_SP', 'LOOKUP', {
      NRP: nrp,
      SCOPE_SECTIONS: scopeToCsv(scope),
      BY_USER: actorOf(req),
      BY_JOBSITE: jobsiteOf(req),
    });
    const row = spResultRow(result);
    if (!row?.success) {
      return res.status(404).json({
        success: false,
        message: row?.message || 'Worker not found.',
      });
    }

    const active = activeSubmissions(result);
    return res.json({
      success: true,
      message: row.message || 'Worker found.',
      data: {
        nrp: row.nrp,
        full_name: row.full_name,
        jabatan: row.jabatan,
        department: row.department,
        department_name: row.department_name,
        section: row.section,
        section_name: row.section_name,
        active_submissions: active.rows,
        active_submissions_total: active.total,
      },
    });
  } catch (error) {
    return res.status(500).json({
      success: false,
      message: 'Server error',
      error: error.message,
    });
  }
}

/** POST /api/hr/permit — multipart fields + optional files[] */
export async function createPermit(req, res) {
  const files = Array.isArray(req.files) ? req.files : [];
  try {
    const payload = ijinPayload(req.body);
    if (!ijinFieldsValid(payload)) {
      await cleanupUploadedFiles(files);
      return res.status(400).json({
        success: false,
        message:
          'nrp, category, and start_date are required.',
      });
    }

    const result = await executeHrSp('PERMIT_SP', 'INSERT', {
      NRP: payload.nrp,
      FULL_NAME: payload.fullName,
      CATEGORY: payload.category,
      START_DATE: payload.startDate,
      END_DATE: payload.endDate,
      DESCRIPTION: payload.description,
      BY_USER: actorOf(req),
      BY_JOBSITE: jobsiteOf(req),
    });

    const response = spResultRow(result);
    if (!response?.success) {
      await cleanupUploadedFiles(files);
      return res.status(400).json({
        success: false,
        message: response?.message || 'Failed to save ijin.',
      });
    }

    const newId = Number(response.id);
    logActivity(req, {
      module: 'permit',
      action: 'INSERT',
      recordId: newId,
      recordKey: payload.nrp,
      message: `Create permit NRP ${payload.nrp}`,
    });

    let reconApproved = false;
    if (isReconAutoApproveLevel(levelCodeOf(req))) {
      reconApproved = await applyReconAutoApprove(
        'permit',
        newId,
        actorOf(req),
        jobsiteOf(req),
      );
      if (reconApproved) {
        logActivity(req, {
          module: 'permit',
          action: 'RECON_AUTO_APPROVE',
          recordId: newId,
          recordKey: payload.nrp,
          message: `Recon auto-approve permit NRP ${payload.nrp} to HR`,
        });
      }
    }
    if (!reconApproved) {
      notifyPermitCreated(newId, jobsiteOf(req)).catch((notifyError) => {
        console.error('ijin notify failed:', notifyError.message);
      });
    }

    const relDir = req.ijinUploadRelDir || 'ijin';
    try {
      await insertPermitPhotoRows(
        jobsiteOf(req),
        newId,
        actorOf(req),
        files,
        relDir,
      );
    } catch (photoErr) {
      await cleanupUploadedFiles(files);
      return res.status(500).json({
        success: false,
        message: 'Permit saved but evidence upload failed.',
        error: photoErr.message,
        data: { id: newId },
      });
    }

    return res.status(201).json({
      success: true,
      message: reconApproved
        ? 'Permit saved and auto-approved to HR.'
        : response.message || 'Permit saved successfully.',
      data: { id: newId, evidence_count: files.length, recon_approved: reconApproved },
    });
  } catch (error) {
    await cleanupUploadedFiles(files);
    return res.status(500).json({
      success: false,
      message: 'Server error',
      error: error.message,
    });
  }
}

/** PUT /api/hr/permit/:id — JSON only (no photo on edit) */
export async function updatePermit(req, res) {
  if (!isValidId(req.params.id)) {
    return res.status(400).json({ success: false, message: 'Invalid ijin id.' });
  }

  try {
    const payload = ijinPayload(req.body);
    if (!ijinFieldsValid(payload)) {
      return res.status(400).json({
        success: false,
        message:
          'nrp, category, and start_date are required.',
      });
    }

    const result = await executeHrSp('PERMIT_SP', 'UPDATE', {
      ID: Number(req.params.id),
      NRP: payload.nrp,
      FULL_NAME: payload.fullName,
      CATEGORY: payload.category,
      START_DATE: payload.startDate,
      END_DATE: payload.endDate,
      DESCRIPTION: payload.description,
      LEVEL_CODE: levelCodeOf(req),
      BY_USER: actorOf(req),
      BY_JOBSITE: jobsiteOf(req),
    });

    const response = spResultRow(result);
    if (response?.success) {
      logActivity(req, {
        module: 'permit',
        action: 'UPDATE',
        recordId: Number(req.params.id),
        recordKey: payload.nrp,
        message: `Update permit id=${req.params.id} NRP ${payload.nrp}`,
      });
    }
    return res.status(response?.success ? 200 : 400).json({
      success: Boolean(response?.success),
      message: response?.message || 'Failed to update ijin.',
    });
  } catch (error) {
    return res.status(500).json({
      success: false,
      message: 'Server error',
      error: error.message,
    });
  }
}

/** POST /api/hr/permit/:id/cancel */
export async function cancelPermit(req, res) {
  if (!isValidId(req.params.id)) {
    return res.status(400).json({ success: false, message: 'Invalid ijin id.' });
  }

  try {
    const result = await executeHrSp('PERMIT_SP', 'CANCEL', {
      ID: Number(req.params.id),
      LEVEL_CODE: levelCodeOf(req),
      BY_USER: actorOf(req),
      BY_JOBSITE: jobsiteOf(req),
    });
    const response = spResultRow(result);
    if (response?.success) {
      logActivity(req, {
        module: 'permit',
        action: 'CANCEL',
        recordId: Number(req.params.id),
        message: `Cancel permit id=${req.params.id}`,
      });
    }
    return res.status(response?.success ? 200 : 400).json({
      success: Boolean(response?.success),
      message: response?.message || 'Failed to cancel ijin.',
    });
  } catch (error) {
    return res.status(500).json({
      success: false,
      message: 'Server error',
      error: error.message,
    });
  }
}

function sendPermitFile(res, relativePath, downloadName) {
  const root = pathResolve(uploadDirectoryPath);
  const cleaned = String(relativePath || '')
    .replace(/^[/\\]+/, '')
    .replace(/\\/g, '/');
  if (!cleaned || cleaned.includes('..')) {
    return res.status(400).json({ success: false, message: 'Invalid evidence path.' });
  }
  const candidate = pathResolve(root, cleaned);
  const rootWithSep = root.endsWith(sep) ? root : root + sep;
  if (candidate !== root && !candidate.startsWith(rootWithSep)) {
    return res.status(400).json({ success: false, message: 'Invalid evidence path.' });
  }
  return res.sendFile(candidate, {
    headers: {
      'Content-Disposition': `inline; filename="${basename(String(downloadName || candidate))}"`,
    },
  });
}

/** GET /api/hr/permit/evidence?path=ijin/yyyy/mm/file.jpg — auth-gated by relative path */
export async function getPermitEvidenceByPath(req, res) {
  try {
    const relative = String(req.query.path || '').trim();
    if (!relative) {
      return res.status(400).json({ success: false, message: 'path is required.' });
    }

    const pool = await getConnection();
    const schema = schemaName();
    const result = await pool
      .request()
      .input('FULLPATH', sql.NVarChar(250), relative.replace(/\\/g, '/'))
      .input('BY_JOBSITE', sql.Int, jobsiteOf(req))
      .query(`
        SELECT TOP 1 id, fullpath, name
        FROM ${schema}.workers_permit_photos
        WHERE deleted_at IS NULL
          AND by_jobsite = @BY_JOBSITE
          AND (fullpath = @FULLPATH OR [path] = @FULLPATH)
      `);
    const row = result.recordset?.[0];
    if (!row?.fullpath) {
      return res.status(404).json({ success: false, message: 'Evidence not found.' });
    }
    return sendPermitFile(res, row.fullpath, row.name);
  } catch (error) {
    return res.status(500).json({
      success: false,
      message: 'Server error',
      error: error.message,
    });
  }
}

/** GET /api/hr/permit/evidence/:photoId — auth-gated file serve */
export async function getPermitEvidence(req, res) {
  if (!isValidId(req.params.photoId)) {
    return res.status(400).json({ success: false, message: 'Invalid photo id.' });
  }

  try {
    const pool = await getConnection();
    const schema = schemaName();
    const result = await pool
      .request()
      .input('ID', sql.Int, Number(req.params.photoId))
      .input('BY_JOBSITE', sql.Int, jobsiteOf(req))
      .query(`
        SELECT id, fullpath, name, [type]
        FROM ${schema}.workers_permit_photos
        WHERE deleted_at IS NULL
          AND by_jobsite = @BY_JOBSITE
          AND id = @ID
      `);
    const row = result.recordset?.[0];
    if (!row?.fullpath) {
      return res.status(404).json({ success: false, message: 'Evidence not found.' });
    }
    return sendPermitFile(res, row.fullpath, row.name);
  } catch (error) {
    return res.status(500).json({
      success: false,
      message: 'Server error',
      error: error.message,
    });
  }
}
