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
import { buildFingerErrorHrExportXlsx } from '../services/fingerErrorExport.js';
import {
  notifyFingerErrorCreated,
  notifyFingerErrorHr,
} from '../services/fingerErrorNotify.js';
import { logActivity } from '../services/activityLog.js';
import {
  applyReconAutoApprove,
  isReconAutoApproveLevel,
} from '../services/reconAutoApprove.js';
import {
  applyModeDefaults,
  buildFingerErrorExampleXlsx,
  normalizeImportMode,
  parseFingerErrorSpreadsheet,
} from '../services/fingerErrorImport.js';

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

/** Normalize datetime from form / JSON for DATETIME2. */
function isoDateTime(value) {
  if (value == null || value === '') return null;
  if (value instanceof Date && !Number.isNaN(value.getTime())) {
    const y = value.getFullYear();
    const m = String(value.getMonth() + 1).padStart(2, '0');
    const d = String(value.getDate()).padStart(2, '0');
    const hh = String(value.getHours()).padStart(2, '0');
    const mm = String(value.getMinutes()).padStart(2, '0');
    const ss = String(value.getSeconds()).padStart(2, '0');
    return `${y}-${m}-${d} ${hh}:${mm}:${ss}`;
  }
  const text = String(value).trim().replace('T', ' ');
  if (!text) return null;
  if (/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$/.test(text)) return `${text}:00`;
  if (/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}/.test(text)) return text.slice(0, 19);
  return text;
}

function levelCodeOf(req) {
  return String(req.user?.level_code || req.user?.level || '').trim().toLowerCase();
}

/** sis | ls | all for the Personalia queue. Superadmin sees both groups. */
function fingerWorkerScope(req) {
  const level = levelCodeOf(req);
  if (level === 'superadmin' || level === 'sa') return 'all';
  const scope = String(req.user?.worker_scope || '').trim().toLowerCase();
  if (scope === 'sis' || scope === 'ls' || scope === 'all') return scope;
  return 'none';
}

/** SIS/LS dropdown is only honored for accounts that already see both groups. */
function fingerHrStatusWorker(req) {
  if (fingerWorkerScope(req) !== 'all') return null;
  const raw = String(req.query.status_worker || '').trim().toLowerCase();
  if (raw === 'sis' || raw === 'vendor') return raw;
  return null;
}

function fingerStatusCounts(result) {
  return (result.recordsets?.[2] ?? [])
    .map((row) => ({
      label: String(row.progress || '').trim(),
      total: Number(row.total) || 0,
      people: String(row.people || '')
        .split(';;')
        .map((part) => {
          const [nrp = '', name = '', section = '', date = '', category = ''] =
            part.split('|');
          return {
            nrp: nrp.trim(),
            name: name.trim(),
            section: section.trim(),
            start_date: date.trim(),
            end_date: '',
            category: category.trim(),
          };
        })
        .filter((person) => person.nrp || person.name),
    }))
    .filter((row) => row.label && row.total > 0);
}

function fingerPayload(body = {}) {
  const category = String(body.category || '').trim();
  return {
    nrp: String(body.nrp || '')
      .trim()
      .toUpperCase(),
    fullName: body.full_name != null ? String(body.full_name).trim() : null,
    category,
    date: body.date ? String(body.date).trim().slice(0, 10) : null,
    fingerIn: isoDateTime(body.finger_in),
    fingerOut: isoDateTime(body.finger_out),
    location:
      body.location != null ? String(body.location).trim() || null : null,
    shift: body.shift != null ? String(body.shift).trim() || null : null,
    remark: body.remark != null ? String(body.remark).trim() || null : null,
    description:
      body.description != null ? String(body.description).trim() || null : null,
    note: body.note != null ? String(body.note).trim() || null : null,
  };
}

function fingerFieldsValid(payload) {
  const categoryId = Number(payload.category);
  return (
    payload.nrp &&
    Number.isInteger(categoryId) &&
    categoryId > 0 &&
    payload.date &&
    (payload.fingerIn || payload.fingerOut)
  );
}

async function insertFingerErrorPhotoRows(jobsite, refId, byUser, files, relDir) {
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
        INSERT INTO ${schema}.workers_finger_error_photos (
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

/** GET /api/hr/finger-error */
export async function listFingerError(req, res) {
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
    const result = await executeHrSp('FINGER_ERROR_SP', 'SELECT', {
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
      message: 'Fetched fingerprint',
      data: result.recordsets?.[0] ?? [],
      meta: {
        total: result.recordsets?.[1]?.[0]?.total_count ?? 0,
        month: monthRaw,
        scoped: !scope.unrestricted,
        scope_sections: scope.unrestricted ? null : scope.sectionIds.length,
        status_counts: fingerStatusCounts(result),
      },
    });
  } catch (error) {
    res.status(500).json({ success: false, message: 'Server error', error: error.message });
  }
}

export async function getFingerError(req, res) {
  if (!isValidId(req.params.id)) {
    return res.status(400).json({ success: false, message: 'Invalid fingerprint id.' });
  }

  try {
    const result = await executeHrSp('FINGER_ERROR_SP', 'GET', {
      ID: Number(req.params.id),
      BY_JOBSITE: jobsiteOf(req),
    });
    const row = result.recordset?.[0];
    if (!row) {
      return res.status(404).json({ success: false, message: 'Fingerprint not found.' });
    }
    return res.json({ success: true, message: 'Fetched fingerprint', data: row });
  } catch (error) {
    return res.status(500).json({
      success: false,
      message: 'Server error',
      error: error.message,
    });
  }
}

/** GET /api/hr/finger-error/section */
export async function listFingerErrorSection(req, res) {
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
    const result = await executeHrSp('FINGER_ERROR_SP', 'SELECT_SECTION', {
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
      message: 'Fetched fingerprint section queue',
      data: result.recordsets?.[0] ?? [],
      meta: {
        total: result.recordsets?.[1]?.[0]?.total_count ?? 0,
        month: monthRaw,
        scoped: !scope.unrestricted,
        scope_sections: scope.unrestricted ? null : scope.sectionIds.length,
        status_counts: fingerStatusCounts(result),
      },
    });
  } catch (error) {
    res.status(500).json({ success: false, message: 'Server error', error: error.message });
  }
}

async function decideFingerError(req, res, action) {
  if (!isValidId(req.params.id)) {
    return res.status(400).json({ success: false, message: 'Invalid fingerprint id.' });
  }
  try {
    const scope = await resolveSectionScope(req.user);
    const result = await executeHrSp('FINGER_ERROR_SP', action, {
      ID: Number(req.params.id),
      NOTE: req.body?.note != null ? String(req.body.note) : null,
      SCOPE_SECTIONS: scopeToCsv(scope),
      LEVEL_CODE: levelCodeOf(req),
      WORKER_SCOPE: fingerWorkerScope(req),
      BY_USER: actorOf(req),
      BY_JOBSITE: jobsiteOf(req),
    });
    const response = spResultRow(result);
    if (response?.success) {
      logActivity(req, {
        module: 'finger_error',
        action,
        recordId: Number(req.params.id),
        message: `${action} finger_error id=${req.params.id}`,
      });
    }
    if (
      response?.success &&
      (action === 'APPROVE_SECTION' ||
        action === 'APPROVE_GL' ||
        action === 'APPROVE_DEPT')
    ) {
      notifyFingerErrorHr(Number(req.params.id), jobsiteOf(req)).catch((notifyError) => {
        console.error('finger_error hr notify failed:', notifyError.message);
      });
    }
    return res.status(response?.success ? 200 : 400).json({
      success: Boolean(response?.success),
      message: response?.message || 'Failed to update fingerprint.',
    });
  } catch (error) {
    return res.status(500).json({
      success: false,
      message: 'Server error',
      error: error.message,
    });
  }
}

export function approveFingerErrorSection(req, res) {
  return decideFingerError(req, res, 'APPROVE_SECTION');
}

export function rejectFingerErrorSection(req, res) {
  return decideFingerError(req, res, 'REJECT_SECTION');
}

/** GET /api/hr/finger-error/group — Group Leader / Unit Head (LS) */
export async function listFingerErrorGroup(req, res) {
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
    const result = await executeHrSp('FINGER_ERROR_SP', 'SELECT_GL', {
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
      message: 'Fetched fingerprint group queue',
      data: result.recordsets?.[0] ?? [],
      meta: {
        total: result.recordsets?.[1]?.[0]?.total_count ?? 0,
        month: monthRaw,
        scoped: !scope.unrestricted,
        scope_sections: scope.unrestricted ? null : scope.sectionIds.length,
        status_counts: fingerStatusCounts(result),
      },
    });
  } catch (error) {
    res.status(500).json({ success: false, message: 'Server error', error: error.message });
  }
}

export function approveFingerErrorGroup(req, res) {
  return decideFingerError(req, res, 'APPROVE_GL');
}

export function rejectFingerErrorGroup(req, res) {
  return decideFingerError(req, res, 'REJECT_GL');
}

/** GET /api/hr/finger-error/department — Department Head */
export async function listFingerErrorDepartment(req, res) {
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
    const result = await executeHrSp('FINGER_ERROR_SP', 'SELECT_DEPT', {
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
      message: 'Fetched fingerprint department queue',
      data: result.recordsets?.[0] ?? [],
      meta: {
        total: result.recordsets?.[1]?.[0]?.total_count ?? 0,
        month: monthRaw,
        scoped: !scope.unrestricted,
        scope_sections: scope.unrestricted ? null : scope.sectionIds.length,
        status_counts: fingerStatusCounts(result),
      },
    });
  } catch (error) {
    res.status(500).json({ success: false, message: 'Server error', error: error.message });
  }
}

export function approveFingerErrorDepartment(req, res) {
  return decideFingerError(req, res, 'APPROVE_DEPT');
}

export function rejectFingerErrorDepartment(req, res) {
  return decideFingerError(req, res, 'REJECT_DEPT');
}

/** GET /api/hr/finger-error/department-exceptions */
export async function listFingerErrorDepartmentExceptions(req, res) {
  try {
    const result = await executeHrSp('FINGER_ERROR_SP', 'LIST_DEPT_EXCEPTION', {
      BY_USER: actorOf(req),
      BY_JOBSITE: jobsiteOf(req),
    });
    res.json({
      success: true,
      message: 'Fetched department fingerprint exceptions',
      data: result.recordsets?.[0] ?? [],
    });
  } catch (error) {
    res.status(500).json({ success: false, message: 'Server error', error: error.message });
  }
}

/** POST /api/hr/finger-error/department-exceptions */
export async function createFingerErrorDepartmentException(req, res) {
  try {
    const result = await executeHrSp('FINGER_ERROR_SP', 'INSERT_DEPT_EXCEPTION', {
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
    return res.status(500).json({
      success: false,
      message: 'Server error',
      error: error.message,
    });
  }
}

/** DELETE /api/hr/finger-error/department-exceptions/:id */
export async function deleteFingerErrorDepartmentException(req, res) {
  if (!isValidId(req.params.id)) {
    return res.status(400).json({ success: false, message: 'Invalid exception id.' });
  }
  try {
    const result = await executeHrSp('FINGER_ERROR_SP', 'DELETE_DEPT_EXCEPTION', {
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
    return res.status(500).json({
      success: false,
      message: 'Server error',
      error: error.message,
    });
  }
}

/** GET /api/hr/finger-error/hr */
export async function listFingerErrorHr(req, res) {
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

    const result = await executeHrSp('FINGER_ERROR_SP', 'SELECT_HR', {
      MONTH: monthRaw,
      DEPARTMENT: parseIdList(req.query.department).join(',') || null,
      SECTION: parseIdList(req.query.section).join(',') || null,
      JOB_RANK: req.query.job_rank?.trim() || null,
      PROGRESS: req.query.progress?.trim() || null,
      STATUS_WORKER: fingerHrStatusWorker(req),
      SEARCH: req.query.q?.trim() || null,
      PAGE: Number(req.query.page) || 1,
      PAGE_SIZE: Number(req.query.page_size) || 0,
      LEVEL_CODE: levelCodeOf(req),
      WORKER_SCOPE: fingerWorkerScope(req),
      BY_USER: actorOf(req),
      BY_JOBSITE: jobsiteOf(req),
    });

    res.json({
      success: true,
      message: 'Fetched fingerprint HR queue',
      data: result.recordsets?.[0] ?? [],
      meta: {
        total: result.recordsets?.[1]?.[0]?.total_count ?? 0,
        month: monthRaw,
        scoped: false,
        worker_scope: fingerWorkerScope(req),
        status_counts: fingerStatusCounts(result),
      },
    });
  } catch (error) {
    res.status(500).json({ success: false, message: 'Server error', error: error.message });
  }
}

/** GET /api/hr/finger-error/hr/export */
export async function exportFingerErrorHr(req, res) {
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

    const workerScope = fingerWorkerScope(req);
    const progress = req.query.progress?.trim() || null;
    const statusWorker = fingerHrStatusWorker(req);
    const result = await executeHrSp('FINGER_ERROR_SP', 'SELECT_HR', {
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
    const buffer = buildFingerErrorHrExportXlsx(rows, {
      month: monthRaw,
      workerScope,
      progress,
      statusWorker,
    });
    const filename = `fingerprint_personalia_${monthRaw}.xlsx`;
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

export function approveFingerErrorHr(req, res) {
  return decideFingerError(req, res, 'APPROVE_HR');
}

export function rejectFingerErrorHr(req, res) {
  return decideFingerError(req, res, 'REJECT_HR');
}

/** GET /api/hr/finger-error/lookup?nrp= — worker only (no active_submissions overlap). */
export async function lookupFingerErrorWorker(req, res) {
  try {
    const nrp = String(req.query.nrp || '').trim();
    if (!nrp) {
      return res.status(400).json({ success: false, message: 'nrp is required.' });
    }

    const scope = await resolveSectionScope(req.user);
    const result = await executeHrSp('FINGER_ERROR_SP', 'LOOKUP', {
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

/** POST /api/hr/finger-error — multipart fields + optional files[] */
export async function createFingerError(req, res) {
  const files = Array.isArray(req.files) ? req.files : [];
  try {
    const payload = fingerPayload(req.body);
    if (!fingerFieldsValid(payload)) {
      await cleanupUploadedFiles(files);
      return res.status(400).json({
        success: false,
        message:
          'nrp, category, date, and at least one of finger_in or finger_out are required.',
      });
    }

    const result = await executeHrSp('FINGER_ERROR_SP', 'INSERT', {
      NRP: payload.nrp,
      FULL_NAME: payload.fullName,
      CATEGORY: payload.category,
      DATE: payload.date,
      FINGER_IN: payload.fingerIn,
      FINGER_OUT: payload.fingerOut,
      LOCATION: payload.location,
      SHIFT: payload.shift,
      REMARK: payload.remark,
      DESCRIPTION: payload.description,
      NOTE: payload.note,
      LEVEL_CODE: levelCodeOf(req),
      BY_USER: actorOf(req),
      BY_JOBSITE: jobsiteOf(req),
    });

    const response = spResultRow(result);
    if (!response?.success) {
      await cleanupUploadedFiles(files);
      return res.status(400).json({
        success: false,
        message: response?.message || 'Failed to save fingerprint.',
      });
    }

    const newId = Number(response.id);
    logActivity(req, {
      module: 'finger_error',
      action: 'INSERT',
      recordId: newId,
      recordKey: payload.nrp,
      message: `Create finger_error NRP ${payload.nrp}`,
    });

    let reconApproved = false;
    if (isReconAutoApproveLevel(levelCodeOf(req))) {
      reconApproved = await applyReconAutoApprove(
        'finger_error',
        newId,
        actorOf(req),
        jobsiteOf(req),
      );
      if (reconApproved) {
        logActivity(req, {
          module: 'finger_error',
          action: 'RECON_AUTO_APPROVE',
          recordId: newId,
          recordKey: payload.nrp,
          message: `Recon auto-approve finger_error NRP ${payload.nrp} to HR`,
        });
      }
    }
    if (!reconApproved) {
      notifyFingerErrorCreated(newId, jobsiteOf(req)).catch((notifyError) => {
        console.error('finger_error notify failed:', notifyError.message);
      });
    }

    const relDir = req.fingerErrorUploadRelDir || 'finger-error';
    try {
      await insertFingerErrorPhotoRows(
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
        message: 'Fingerprint saved but evidence upload failed.',
        error: photoErr.message,
        data: { id: newId },
      });
    }

    return res.status(201).json({
      success: true,
      message: reconApproved
        ? 'Fingerprint saved and auto-approved to HR.'
        : response.message || 'Fingerprint saved successfully.',
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

/** PUT /api/hr/finger-error/:id — JSON only */
export async function updateFingerError(req, res) {
  if (!isValidId(req.params.id)) {
    return res.status(400).json({ success: false, message: 'Invalid fingerprint id.' });
  }

  try {
    const payload = fingerPayload(req.body);
    if (!fingerFieldsValid(payload)) {
      return res.status(400).json({
        success: false,
        message:
          'nrp, category, date, and at least one of finger_in or finger_out are required.',
      });
    }

    const result = await executeHrSp('FINGER_ERROR_SP', 'UPDATE', {
      ID: Number(req.params.id),
      NRP: payload.nrp,
      FULL_NAME: payload.fullName,
      CATEGORY: payload.category,
      DATE: payload.date,
      FINGER_IN: payload.fingerIn,
      FINGER_OUT: payload.fingerOut,
      LOCATION: payload.location,
      SHIFT: payload.shift,
      REMARK: payload.remark,
      DESCRIPTION: payload.description,
      NOTE: payload.note,
      LEVEL_CODE: levelCodeOf(req),
      BY_USER: actorOf(req),
      BY_JOBSITE: jobsiteOf(req),
    });

    const response = spResultRow(result);
    if (response?.success) {
      logActivity(req, {
        module: 'finger_error',
        action: 'UPDATE',
        recordId: Number(req.params.id),
        recordKey: payload.nrp,
        message: `Update finger_error id=${req.params.id} NRP ${payload.nrp}`,
      });
    }
    return res.status(response?.success ? 200 : 400).json({
      success: Boolean(response?.success),
      message: response?.message || 'Failed to update fingerprint.',
    });
  } catch (error) {
    return res.status(500).json({
      success: false,
      message: 'Server error',
      error: error.message,
    });
  }
}

/** POST /api/hr/finger-error/:id/cancel */
export async function cancelFingerError(req, res) {
  if (!isValidId(req.params.id)) {
    return res.status(400).json({ success: false, message: 'Invalid fingerprint id.' });
  }

  try {
    const result = await executeHrSp('FINGER_ERROR_SP', 'CANCEL', {
      ID: Number(req.params.id),
      LEVEL_CODE: levelCodeOf(req),
      BY_USER: actorOf(req),
      BY_JOBSITE: jobsiteOf(req),
    });
    const response = spResultRow(result);
    if (response?.success) {
      logActivity(req, {
        module: 'finger_error',
        action: 'CANCEL',
        recordId: Number(req.params.id),
        message: `Cancel finger_error id=${req.params.id}`,
      });
    }
    return res.status(response?.success ? 200 : 400).json({
      success: Boolean(response?.success),
      message: response?.message || 'Failed to cancel fingerprint.',
    });
  } catch (error) {
    return res.status(500).json({
      success: false,
      message: 'Server error',
      error: error.message,
    });
  }
}

function sendFingerErrorFile(res, relativePath, downloadName) {
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

/** GET /api/hr/finger-error/evidence?path= */
export async function getFingerErrorEvidenceByPath(req, res) {
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
        FROM ${schema}.workers_finger_error_photos
        WHERE deleted_at IS NULL
          AND by_jobsite = @BY_JOBSITE
          AND (fullpath = @FULLPATH OR [path] = @FULLPATH)
      `);
    const row = result.recordset?.[0];
    if (!row?.fullpath) {
      return res.status(404).json({ success: false, message: 'Evidence not found.' });
    }
    return sendFingerErrorFile(res, row.fullpath, row.name);
  } catch (error) {
    return res.status(500).json({
      success: false,
      message: 'Server error',
      error: error.message,
    });
  }
}

/** GET /api/hr/finger-error/evidence/:photoId */
export async function getFingerErrorEvidence(req, res) {
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
        FROM ${schema}.workers_finger_error_photos
        WHERE deleted_at IS NULL
          AND by_jobsite = @BY_JOBSITE
          AND id = @ID
      `);
    const row = result.recordset?.[0];
    if (!row?.fullpath) {
      return res.status(404).json({ success: false, message: 'Evidence not found.' });
    }
    return sendFingerErrorFile(res, row.fullpath, row.name);
  } catch (error) {
    return res.status(500).json({
      success: false,
      message: 'Server error',
      error: error.message,
    });
  }
}

/** GET /api/hr/finger-error/example — Excel template (category + mode chosen in modal) */
export async function downloadFingerErrorExample(_req, res) {
  const buffer = buildFingerErrorExampleXlsx();
  res.setHeader(
    'Content-Type',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  );
  res.setHeader(
    'Content-Disposition',
    'attachment; filename="example_fingerprint.xlsx"',
  );
  return res.status(200).send(buffer);
}

/**
 * POST /api/hr/finger-error/import — multipart `file` + form fields `category`, `mode`.
 * Mode: in | out | both. Category = workers_fingerprint enum id (same for all rows).
 */
export async function importFingerError(req, res) {
  try {
    if (!req.file?.buffer) {
      return res.status(400).json({
        success: false,
        message: 'Upload a spreadsheet file in field "file".',
      });
    }

    const categoryId = Number(String(req.body?.category || '').trim());
    if (!Number.isInteger(categoryId) || categoryId <= 0) {
      return res.status(400).json({
        success: false,
        message: 'category (enum id) is required on the import form.',
      });
    }

    const mode = normalizeImportMode(req.body?.mode);
    if (!mode) {
      return res.status(400).json({
        success: false,
        message: 'mode must be in, out, or both.',
      });
    }

    const byJobsite = jobsiteOf(req);
    const pool = await getConnection();
    const schema = schemaName();
    const catCheck = await pool
      .request()
      .input('ID', sql.Int, categoryId)
      .input('BY_JOBSITE', sql.Int, byJobsite)
      .query(`
        SELECT TOP 1 id
        FROM ${schema}.enums
        WHERE deleted_at IS NULL
          AND by_jobsite = @BY_JOBSITE
          AND id = @ID
          AND type = N'workers_fingerprint'
      `);
    if (!catCheck.recordset?.[0]) {
      return res.status(400).json({
        success: false,
        message: 'category is not a valid workers_fingerprint enum for this jobsite.',
      });
    }

    const parsed = parseFingerErrorSpreadsheet(
      req.file.buffer,
      req.file.originalname,
    );
    if (parsed.error) {
      return res.status(400).json({ success: false, message: parsed.error });
    }
    if (!parsed.rows.length) {
      return res.status(400).json({
        success: false,
        message: 'No data rows found after the header.',
      });
    }

    const byUser = actorOf(req);
    const levelCode = levelCodeOf(req);
    const reconEligible = isReconAutoApproveLevel(levelCode);
    let inserted = 0;
    /** @type {Array<{ row: number, nrp: string|null, date: string|null, shift: string|null, status: 'ok'|'error', id?: number|null, reason?: string|null }>} */
    const rowResults = [];

    const pushError = (raw, reason) => {
      rowResults.push({
        row: raw.excelRow,
        nrp: raw.nrp || null,
        date: raw.date || null,
        shift: raw.shift || raw.shift_raw || null,
        status: 'error',
        reason,
      });
    };

    for (const raw of parsed.rows) {
      if (!raw.date || !raw.nrp) {
        pushError(raw, 'date and nrp are required.');
        continue;
      }
      if (!raw.shift) {
        pushError(
          raw,
          raw.shift_raw
            ? `shift tidak valid ("${raw.shift_raw}"). Wajib tepat I atau II saja.`
            : 'shift wajib diisi: I (siang) atau II (malam).',
        );
        continue;
      }

      const row = applyModeDefaults(raw, mode);
      if (!row.finger_in && !row.finger_out) {
        pushError(
          raw,
          'Could not resolve finger_in / finger_out for this mode and shift.',
        );
        continue;
      }

      try {
        const result = await executeHrSp('FINGER_ERROR_SP', 'INSERT', {
          NRP: row.nrp,
          FULL_NAME: row.full_name,
          CATEGORY: String(categoryId),
          DATE: row.date,
          FINGER_IN: row.finger_in,
          FINGER_OUT: row.finger_out,
          LOCATION: row.location,
          SHIFT: row.shift,
          REMARK: row.remark,
          DESCRIPTION: row.description,
          NOTE: null,
          LEVEL_CODE: levelCode,
          BY_USER: byUser,
          BY_JOBSITE: byJobsite,
        });
        const outcome = spResultRow(result);
        if (!outcome?.success) {
          pushError(raw, outcome?.message || 'Insert failed.');
          continue;
        }

        inserted += 1;
        const newId = Number(outcome.id);
        rowResults.push({
          row: raw.excelRow,
          nrp: row.nrp,
          date: row.date,
          shift: row.shift,
          status: 'ok',
          id: Number.isInteger(newId) ? newId : null,
          reason: null,
        });

        logActivity(req, {
          module: 'finger_error',
          action: 'IMPORT',
          recordId: newId,
          recordKey: row.nrp,
          message: `Import fingerprint NRP ${row.nrp} mode=${mode}`,
        });

        if (reconEligible && Number.isInteger(newId) && newId > 0) {
          try {
            const applied = await applyReconAutoApprove(
              'finger_error',
              newId,
              byUser,
              byJobsite,
            );
            if (applied) {
              logActivity(req, {
                module: 'finger_error',
                action: 'RECON_AUTO_APPROVE',
                recordId: newId,
                recordKey: row.nrp,
                message: `Recon auto-approve import NRP ${row.nrp}`,
              });
            } else {
              notifyFingerErrorCreated(newId, byJobsite).catch((notifyError) => {
                console.error('finger_error notify failed:', notifyError.message);
              });
            }
          } catch (reconErr) {
            console.error('finger_error recon auto-approve failed:', reconErr.message);
            notifyFingerErrorCreated(newId, byJobsite).catch((notifyError) => {
              console.error('finger_error notify failed:', notifyError.message);
            });
          }
        } else {
          notifyFingerErrorCreated(newId, byJobsite).catch((notifyError) => {
            console.error('finger_error notify failed:', notifyError.message);
          });
        }
      } catch (err) {
        pushError(raw, err.message || 'Insert failed.');
      }
    }

    const errors = rowResults.filter((r) => r.status === 'error');
    const skipped = errors.length;
    const ok = inserted > 0;
    return res.status(ok ? 200 : 400).json({
      success: ok,
      message: ok
        ? `Imported ${inserted} row(s)${skipped ? `, skipped ${skipped}` : ''}.`
        : `No rows imported${skipped ? ` (${skipped} skipped)` : ''}.`,
      data: {
        inserted,
        skipped,
        total: parsed.rows.length,
        rows: rowResults,
        errors: errors.slice(0, 50),
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
