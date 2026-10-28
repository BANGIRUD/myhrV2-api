import bcrypt from 'bcrypt';
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
import {
  buildWorkPatternExampleCsv,
  buildWorkPatternExportXlsx,
  buildRosterExportXlsx,
  parseWorkPatternSpreadsheet,
} from '../services/workPatternImport.js';
import {
  buildWorkersExampleXlsx,
  parseWorkersSpreadsheet,
} from '../services/workersImport.js';
import { buildWorkersExportXlsx } from '../services/workersExport.js';
import { buildSicknessHrExportXlsx } from '../services/sicknessExport.js';
import { notifySicknessCreated, notifySicknessHr } from '../services/sicknessNotify.js';
import { logActivity } from '../services/activityLog.js';
import {
  applyReconAutoApprove,
  isReconAutoApproveLevel,
} from '../services/reconAutoApprove.js';
import {
  closeStaleFingerPulseRuns,
  getFingerPulseRunLock,
  runFingerPulseIngest,
} from '../services/fingerPulseRunner.js';
const BCRYPT_ROUNDS = 10;

function schemaName() {
  return quoteSchemaName(getHrSchema());
}

function jobsiteOf(req) {
  return Number(req.user?.by_jobsite) || 1;
}

/** Actor for audit columns (created_by / updated_by / deleted_by) — hr.users.id */
function actorOf(req) {
  const id = Number(req.user?.id);
  return Number.isFinite(id) && id > 0 ? id : null;
}

function isValidId(value) {
  return /^\d+$/.test(String(value));
}

function spResultRow(result) {
  return result?.recordset?.[0] || null;
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
    kind: row.kind || 'sickness',
  }));
}

function activeSubmissions(result) {
  const rows = [...mapActiveRows(result?.recordsets?.[1]), ...mapActiveRows(result?.recordsets?.[2])]
    .sort((a, b) => String(b.start_date || '').localeCompare(String(a.start_date || '')))
    .slice(0, 5);
  const total = Number(result?.recordsets?.[3]?.[0]?.total_count ?? rows.length);
  return { rows, total: Number.isFinite(total) ? total : rows.length };
}

async function listQuery(sqlText, byJobsite) {
  const pool = await getConnection();
  const request = pool.request();
  if (byJobsite != null) {
    request.input('BY_JOBSITE', byJobsite);
  }
  const result = await request.query(sqlText);
  return result.recordset || [];
}

async function executeHrSp(procedureName, action, params = {}, options = {}) {
  const pool = await getConnection();
  // mssql v12: per-request timeout via request({ requestTimeout }) — request.timeout is ignored.
  const request =
    options.timeout != null
      ? pool.request({ requestTimeout: Number(options.timeout) })
      : pool.request();
  request.input('ACTION_SP', sql.NVarChar, action);

  for (const [key, value] of Object.entries(params)) {
    if (value === undefined) continue;
    // Audit actor is hr.users.id (INT NULL); explicit type avoids mssql null inference issues.
    if (key === 'BY_USER') {
      request.input(key, sql.Int, value);
      continue;
    }
    request.input(key, value);
  }

  return request.execute(qualifyProcedureName(procedureName, 'hr'));
}

const executeUsersSp = (action, params) =>
  executeHrSp('USERS_SP', action, params);

const executeMenusSp = (action, params) =>
  executeHrSp('MENUS_SP', action, params);

export async function listJobsites(_req, res) {
  try {
    const schema = schemaName();
    const data = await listQuery(`
      SELECT id, code, name, description, is_active, created_at, updated_at
      FROM ${schema}.jobsites
      WHERE deleted_at IS NULL
      ORDER BY id
    `);
    res.json({ success: true, message: 'Fetched jobsites', data });
  } catch (error) {
    res.status(500).json({ success: false, message: 'Server error', error: error.message });
  }
}

export async function listLevels(req, res) {
  try {
    const schema = schemaName();
    const byJobsite = jobsiteOf(req);
    const data = await listQuery(
      `
      SELECT id, by_jobsite, code, name, description, approval_stage,
             structure_scoped, sort_order, is_active, created_at, updated_at
      FROM ${schema}.levels
      WHERE by_jobsite = @BY_JOBSITE AND deleted_at IS NULL
      ORDER BY sort_order, code
    `,
      byJobsite,
    );
    res.json({ success: true, message: 'Fetched levels', data });
  } catch (error) {
    res.status(500).json({ success: false, message: 'Server error', error: error.message });
  }
}

function canListAllSubmissions(req) {
  const level = String(req.user?.level_code || req.user?.level || '').trim().toLowerCase();
  return level === 'superadmin' || level === 'sa' || level === 'hr_administrator';
}

/** GET /api/hr/submissions — every pengajuan parent, HR administrator and superadmin. */
export async function listSubmissions(req, res) {
  try {
    if (!canListAllSubmissions(req)) {
      return res.status(403).json({
        success: false,
        message: 'Only HR administrator or superadmin can view all submissions.',
      });
    }

    const page = Math.max(1, Number(req.query.page) || 1);
    const pageSize = Math.min(100, Math.max(1, Number(req.query.page_size) || 20));
    const search = String(req.query.q || '').trim();
    const nrpExact = /^[0-9]+$/.test(search) ? search : '';
    const moduleCode = String(req.query.module || '').trim().toLowerCase();
    const schema = schemaName();
    const pool = await getConnection();
    const request = pool.request();
    request.input('BY_JOBSITE', jobsiteOf(req));
    request.input('SEARCH', search);
    request.input('NRP_EXACT', nrpExact);
    request.input('MODULE_CODE', moduleCode);
    request.input('OFFSET', (page - 1) * pageSize);
    request.input('PAGE_SIZE', pageSize);
    const where = `
      WHERE s.by_jobsite = @BY_JOBSITE
        AND s.deleted_at IS NULL
        AND s.ref_id IS NULL
        AND (@MODULE_CODE = N'' OR s.module_code = @MODULE_CODE)
        AND (
          @SEARCH = N''
          OR (@NRP_EXACT <> N'' AND s.nrp = @NRP_EXACT)
          OR (
            @NRP_EXACT = N''
            AND (
              s.nrp LIKE @SEARCH + N'%'
              OR ISNULL(wa.full_name, N'') LIKE N'%' + @SEARCH + N'%'
              OR ISNULL(s.progress, N'') LIKE N'%' + @SEARCH + N'%'
              OR ISNULL(s.entered_by, N'') LIKE N'%' + @SEARCH + N'%'
            )
          )
        )`;
    const result = await request.query(`
      SELECT
        s.id,
        s.module_code,
        CASE s.module_code
          WHEN N'sickness' THEN N'Sakit'
          WHEN N'permit' THEN N'Ijin'
          ELSE s.module_code
        END AS module_name,
        s.nrp,
        ISNULL(wa.full_name, N'') AS full_name,
        ISNULL(wa.department_name, N'') AS department_name,
        ISNULL(wa.section_name, N'') AS section_name,
        s.start_date,
        s.end_date,
        s.progress,
        ISNULL(s.entered_by, N'') AS entered_by
      FROM ${schema}.v_active_submissions s
      LEFT JOIN ${schema}.v_workers_active wa
        ON wa.by_jobsite = s.by_jobsite AND wa.nrp = s.nrp
      ${where}
      ORDER BY s.start_date DESC, s.id DESC
      OFFSET @OFFSET ROWS FETCH NEXT @PAGE_SIZE ROWS ONLY;

      SELECT COUNT(*) AS total_count
      FROM ${schema}.v_active_submissions s
      LEFT JOIN ${schema}.v_workers_active wa
        ON wa.by_jobsite = s.by_jobsite AND wa.nrp = s.nrp
      ${where};
    `);
    const data = (result.recordsets?.[0] ?? []).map((row) => ({
      ...row,
      start_date: isoDate(row.start_date),
      end_date: isoDate(row.end_date),
    }));
    return res.json({
      success: true,
      message: 'Fetched submissions',
      data,
      meta: { total: result.recordsets?.[1]?.[0]?.total_count ?? 0 },
    });
  } catch (error) {
    return res.status(500).json({ success: false, message: 'Server error', error: error.message });
  }
}

export async function listStructure(req, res) {
  try {
    const schema = schemaName();
    const byJobsite = jobsiteOf(req);
    const type = String(req.query.type || '').trim().toLowerCase();
    const refId =
      req.query.ref_id === undefined || req.query.ref_id === ''
        ? null
        : Number(req.query.ref_id);

    const pool = await getConnection();
    const request = pool
      .request()
      .input('BY_JOBSITE', sql.Int, byJobsite);

    let typeClause = '';
    if (type === 'department' || type === 'section') {
      request.input('TYPE', sql.NVarChar, type);
      typeClause = 'AND s.type = @TYPE';
    }

    let refClause = '';
    if (refId != null && Number.isFinite(refId)) {
      request.input('REF_ID', sql.BigInt, refId);
      refClause = 'AND s.ref_id = @REF_ID';
    }

    const result = await request.query(`
      SELECT
        s.id,
        s.by_jobsite,
        s.key_id,
        s.code,
        s.name,
        s.type,
        s.ref_id,
        s.by_order
      FROM ${schema}.structure s
      WHERE s.by_jobsite = @BY_JOBSITE
        AND s.deleted_at IS NULL
        ${typeClause}
        ${refClause}
      ORDER BY s.by_order, s.name
    `);

    res.json({
      success: true,
      message: 'Fetched structure',
      data: result.recordset || [],
    });
  } catch (error) {
    res.status(500).json({ success: false, message: 'Server error', error: error.message });
  }
}

export async function listUsers(req, res) {
  try {
    const result = await executeUsersSp('SELECT', {
      BY_JOBSITE: jobsiteOf(req),
      SEARCH: req.query.q?.trim() || null,
      PAGE: Number(req.query.page) || 1,
      PAGE_SIZE: Number(req.query.page_size) || 0,
      LEVEL_ID: req.query.level_id ? Number(req.query.level_id) : null,
      DEPARTMENT: req.query.department?.trim() || null,
      SECTION: req.query.section?.trim() || null,
      IS_ACTIVE:
        req.query.is_active === undefined || req.query.is_active === ''
          ? null
          : Number(req.query.is_active) === 1,
    });

    res.json({
      success: true,
      message: 'Fetched users',
      data: result.recordsets?.[0] ?? [],
      meta: { total: result.recordsets?.[1]?.[0]?.total_count ?? 0 },
    });
  } catch (error) {
    res.status(500).json({ success: false, message: 'Server error', error: error.message });
  }
}

export async function getUser(req, res) {
  if (!isValidId(req.params.id)) {
    return res.status(400).json({ success: false, message: 'Invalid user id.' });
  }

  try {
    const result = await executeUsersSp('GET', {
      ID: Number(req.params.id),
      BY_JOBSITE: jobsiteOf(req),
    });
    const row = result.recordset?.[0];
    if (!row) {
      return res.status(404).json({ success: false, message: 'User not found.' });
    }
    return res.json({ success: true, message: 'Fetched user', data: row });
  } catch (error) {
    return res.status(500).json({
      success: false,
      message: 'Server error',
      error: error.message,
    });
  }
}

export async function createUser(req, res) {
  try {
    const body = req.body || {};
    const username = String(body.username || '').trim();
    const fullName = String(body.full_name || '').trim();
    const levelId = body.level_id != null ? Number(body.level_id) : null;
    const level = body.level != null ? String(body.level).trim() : null;

    if (!username || !fullName || (!levelId && !level)) {
      return res.status(400).json({
        success: false,
        message: 'Username, full_name, and level_id (or level) are required.',
      });
    }

    const plainPassword =
      body.password != null && String(body.password).trim() !== ''
        ? String(body.password)
        : username;
    const hashed = await bcrypt.hash(plainPassword, BCRYPT_ROUNDS);

    const result = await executeUsersSp('INSERT', {
      USERNAME: username,
      PASSWORD: hashed,
      FULL_NAME: fullName,
      EMAIL: body.email ?? null,
      PHONE: body.phone ?? null,
      DEPARTMENT: body.department ?? null,
      SECTION: body.section ?? null,
      DESCRIPTION: body.description ?? null,
      LEVEL: level || null,
      LEVEL_ID: Number.isFinite(levelId) ? levelId : null,
      WORKER_SCOPE: body.worker_scope ?? null,
      MODULE: body.module ?? null,
      PRIVILEGE_MENU: body.privilege_menu ?? null,
      IS_ACTIVE: body.is_active === undefined ? 1 : body.is_active ? 1 : 0,
      BY_USER: actorOf(req),
      BY_JOBSITE: jobsiteOf(req),
    });

    const response = spResultRow(result);
    if (response?.success) {
      logActivity(req, {
        module: 'users',
        action: 'INSERT',
        recordId: response.id,
        recordKey: username,
        message: `Create user ${username}`,
      });
    }
    return res.status(response?.success ? 201 : 400).json({
      success: Boolean(response?.success),
      message: response?.message || 'Failed to save user.',
      ...(response?.success && { data: { id: response.id } }),
    });
  } catch (error) {
    return res.status(500).json({
      success: false,
      message: 'Server error',
      error: error.message,
    });
  }
}

export async function updateUser(req, res) {
  if (!isValidId(req.params.id)) {
    return res.status(400).json({ success: false, message: 'Invalid user id.' });
  }

  try {
    const body = req.body || {};
    let hashed = null;
    if (body.password != null && String(body.password).trim() !== '') {
      hashed = await bcrypt.hash(String(body.password), BCRYPT_ROUNDS);
    }

    const levelId =
      body.level_id === undefined || body.level_id === null || body.level_id === ''
        ? null
        : Number(body.level_id);

    const result = await executeUsersSp('UPDATE', {
      ID: Number(req.params.id),
      USERNAME: body.username ?? null,
      PASSWORD: hashed,
      FULL_NAME: body.full_name ?? null,
      EMAIL: body.email ?? null,
      PHONE: body.phone ?? null,
      DEPARTMENT: body.department ?? null,
      SECTION: body.section ?? null,
      DESCRIPTION: body.description ?? null,
      LEVEL: body.level ?? null,
      LEVEL_ID: Number.isFinite(levelId) ? levelId : null,
      WORKER_SCOPE: body.worker_scope ?? null,
      MODULE: body.module ?? null,
      PRIVILEGE_MENU: body.privilege_menu ?? null,
      IS_ACTIVE:
        body.is_active === undefined || body.is_active === null
          ? null
          : body.is_active
            ? 1
            : 0,
      BY_USER: actorOf(req),
      BY_JOBSITE: jobsiteOf(req),
    });

    const response = spResultRow(result);
    if (response?.success) {
      logActivity(req, {
        module: 'users',
        action: 'UPDATE',
        recordId: Number(req.params.id),
        recordKey: body.username ? String(body.username).trim() : null,
        message: `Update user id=${req.params.id}`,
      });
    }
    return res.status(response?.success ? 200 : 400).json({
      success: Boolean(response?.success),
      message: response?.message || 'Failed to update user.',
    });
  } catch (error) {
    return res.status(500).json({
      success: false,
      message: 'Server error',
      error: error.message,
    });
  }
}

export async function deleteUser(req, res) {
  if (!isValidId(req.params.id)) {
    return res.status(400).json({ success: false, message: 'Invalid user id.' });
  }

  try {
    const result = await executeUsersSp('DELETE', {
      ID: Number(req.params.id),
      BY_USER: actorOf(req),
      BY_JOBSITE: jobsiteOf(req),
    });
    const response = spResultRow(result);
    if (response?.success) {
      logActivity(req, {
        module: 'users',
        action: 'DELETE',
        recordId: Number(req.params.id),
        message: `Delete user id=${req.params.id}`,
      });
    }
    return res.status(response?.success ? 200 : 400).json({
      success: Boolean(response?.success),
      message: response?.message || 'Failed to delete user.',
    });
  } catch (error) {
    return res.status(500).json({
      success: false,
      message: 'Server error',
      error: error.message,
    });
  }
}

/**
 * Admin reset: set password hash to bcrypt(username), same pattern as CI reset_password.
 * Scoped to the caller's jobsite.
 */
export async function resetUserPassword(req, res) {
  try {
    const id = Number(req.params.id);
    if (!Number.isFinite(id) || id <= 0) {
      return res.status(400).json({
        success: false,
        message: 'Valid user id is required.',
      });
    }

    const byJobsite = jobsiteOf(req);
    const getResult = await executeUsersSp('GET', {
      ID: id,
      BY_JOBSITE: byJobsite,
    });
    const row = getResult.recordset?.[0];
    if (!row) {
      return res.status(404).json({
        success: false,
        message: 'User not found.',
      });
    }

    const username = String(row.username || '').trim();
    if (!username) {
      return res.status(400).json({
        success: false,
        message: 'User has no username to use as default password.',
      });
    }

    const hashed = await bcrypt.hash(username, BCRYPT_ROUNDS);
    const result = await executeUsersSp('RESET_PASSWORD', {
      ID: id,
      PASSWORD: hashed,
      BY_USER: actorOf(req),
      BY_JOBSITE: byJobsite,
    });
    const response = spResultRow(result);
    if (response?.success) {
      logActivity(req, {
        module: 'users',
        action: 'RESET_PASSWORD',
        recordId: id,
        recordKey: username,
        message: `Reset password user ${username}`,
      });
    }

    return res.status(response?.success ? 200 : 400).json({
      success: Boolean(response?.success),
      message:
        response?.message ||
        'Password reset successfully. Default password is the username.',
    });
  } catch (error) {
    return res.status(500).json({
      success: false,
      message: 'Server error',
      error: error.message,
    });
  }
}

export async function listMenus(req, res) {
  try {
    const result = await executeMenusSp('SELECT', {
      BY_JOBSITE: jobsiteOf(req),
      SEARCH: req.query.q?.trim() || null,
      PAGE: Number(req.query.page) || 1,
      PAGE_SIZE: Number(req.query.page_size) || 0,
      IS_ACTIVE:
        req.query.is_active === undefined || req.query.is_active === ''
          ? null
          : Number(req.query.is_active) === 1,
    });

    res.json({
      success: true,
      message: 'Fetched menus',
      data: result.recordsets?.[0] ?? [],
      meta: { total: result.recordsets?.[1]?.[0]?.total_count ?? 0 },
    });
  } catch (error) {
    res.status(500).json({ success: false, message: 'Server error', error: error.message });
  }
}

export async function getMenu(req, res) {
  if (!isValidId(req.params.id)) {
    return res.status(400).json({ success: false, message: 'Invalid menu id.' });
  }

  try {
    const result = await executeMenusSp('GET', {
      ID: Number(req.params.id),
      BY_JOBSITE: jobsiteOf(req),
    });
    const row = result.recordset?.[0];
    if (!row) {
      return res.status(404).json({ success: false, message: 'Menu not found.' });
    }
    return res.json({ success: true, message: 'Fetched menu', data: row });
  } catch (error) {
    return res.status(500).json({
      success: false,
      message: 'Server error',
      error: error.message,
    });
  }
}

export async function createMenu(req, res) {
  try {
    const body = req.body || {};
    const menuCode = String(body.menu_code || '').trim();
    const menuName = String(body.menu_name || '').trim();

    if (!menuCode || !menuName) {
      return res.status(400).json({
        success: false,
        message: 'menu_code and menu_name are required.',
      });
    }

    const parentId =
      body.parent_id === undefined || body.parent_id === null || body.parent_id === ''
        ? null
        : Number(body.parent_id);

    const result = await executeMenusSp('INSERT', {
      MENU_CODE: menuCode,
      MENU_NAME: menuName,
      MENU_URL: body.menu_url ?? null,
      ICON: body.icon ?? null,
      MENU_TYPE: body.menu_type ?? null,
      PARENT_ID: Number.isFinite(parentId) ? parentId : null,
      SORT_ORDER: body.sort_order != null ? Number(body.sort_order) : 0,
      SHOW_SIDEBAR:
        body.show_sidebar === undefined ? 1 : body.show_sidebar ? 1 : 0,
      IS_ACTIVE: body.is_active === undefined ? 1 : body.is_active ? 1 : 0,
      DESCRIPTION: body.description ?? null,
      BY_USER: actorOf(req),
      BY_JOBSITE: jobsiteOf(req),
    });

    const response = spResultRow(result);
    return res.status(response?.success ? 201 : 400).json({
      success: Boolean(response?.success),
      message: response?.message || 'Failed to save menu.',
      ...(response?.success && { data: { id: response.id } }),
    });
  } catch (error) {
    return res.status(500).json({
      success: false,
      message: 'Server error',
      error: error.message,
    });
  }
}

export async function updateMenu(req, res) {
  if (!isValidId(req.params.id)) {
    return res.status(400).json({ success: false, message: 'Invalid menu id.' });
  }

  try {
    const body = req.body || {};
    let parentId = null;
    if (body.parent_id === null || body.parent_id === '') {
      parentId = -1; // SP clears parent
    } else if (body.parent_id !== undefined) {
      parentId = Number(body.parent_id);
    }

    const result = await executeMenusSp('UPDATE', {
      ID: Number(req.params.id),
      MENU_CODE: body.menu_code ?? null,
      MENU_NAME: body.menu_name ?? null,
      MENU_URL: body.menu_url ?? null,
      ICON: body.icon ?? null,
      MENU_TYPE: body.menu_type ?? null,
      PARENT_ID: parentId,
      SORT_ORDER:
        body.sort_order === undefined || body.sort_order === null
          ? null
          : Number(body.sort_order),
      SHOW_SIDEBAR:
        body.show_sidebar === undefined || body.show_sidebar === null
          ? null
          : body.show_sidebar
            ? 1
            : 0,
      IS_ACTIVE:
        body.is_active === undefined || body.is_active === null
          ? null
          : body.is_active
            ? 1
            : 0,
      DESCRIPTION: body.description ?? null,
      BY_USER: actorOf(req),
      BY_JOBSITE: jobsiteOf(req),
    });

    const response = spResultRow(result);
    return res.status(response?.success ? 200 : 400).json({
      success: Boolean(response?.success),
      message: response?.message || 'Failed to update menu.',
    });
  } catch (error) {
    return res.status(500).json({
      success: false,
      message: 'Server error',
      error: error.message,
    });
  }
}

export async function deleteMenu(req, res) {
  if (!isValidId(req.params.id)) {
    return res.status(400).json({ success: false, message: 'Invalid menu id.' });
  }

  try {
    const result = await executeMenusSp('DELETE', {
      ID: Number(req.params.id),
      BY_USER: actorOf(req),
      BY_JOBSITE: jobsiteOf(req),
    });
    const response = spResultRow(result);
    return res.status(response?.success ? 200 : 400).json({
      success: Boolean(response?.success),
      message: response?.message || 'Failed to delete menu.',
    });
  } catch (error) {
    return res.status(500).json({
      success: false,
      message: 'Server error',
      error: error.message,
    });
  }
}

const executeEnumsSp = (action, params) =>
  executeHrSp('ENUMS_SP', action, params);

export async function listEnums(req, res) {
  try {
    const result = await executeEnumsSp('SELECT', {
      BY_JOBSITE: jobsiteOf(req),
      TYPE: req.query.type?.trim() || null,
      CATEGORY: req.query.category?.trim() || null,
      SEARCH: req.query.q?.trim() || null,
      PAGE: Number(req.query.page) || 1,
      PAGE_SIZE: Number(req.query.page_size) || 0,
    });

    res.json({
      success: true,
      message: 'Fetched enums',
      data: result.recordsets?.[0] ?? [],
      meta: { total: result.recordsets?.[1]?.[0]?.total_count ?? 0 },
    });
  } catch (error) {
    res.status(500).json({ success: false, message: 'Server error', error: error.message });
  }
}

/** Map UI/query aliases to SP @SOURCE (sis | vendor). */
function workersSourceOf(raw) {
  const value = String(raw || '').trim().toLowerCase();
  if (value === 'sis') return 'sis';
  if (value === 'vendor' || value === 'ls') return 'vendor';
  return null;
}

function optionalIntQuery(value) {
  if (value === undefined || value === null || String(value).trim() === '') return null;
  const n = Number(value);
  return Number.isFinite(n) ? n : null;
}

/** active | inactive | all — default active (matches hr.v_workers_active). */
function workersStatusModeOf(raw) {
  const value = String(raw || '')
    .trim()
    .toLowerCase();
  if (value === 'inactive' || value === 'all' || value === 'active') return value;
  return 'active';
}

/** GET /api/hr/workers?source=sis|vendor|ls — paged employee master (read-only). */
export async function listWorkers(req, res) {
  try {
    const source = workersSourceOf(req.query.source);
    if (!source) {
      return res.status(400).json({
        success: false,
        message: 'Query source is required (sis or vendor/ls).',
      });
    }

    const result = await executeHrSp('WORKERS_SP', 'SELECT', {
      BY_JOBSITE: jobsiteOf(req),
      SOURCE: source,
      DEPARTMENT: optionalIntQuery(req.query.department),
      SECTION: optionalIntQuery(req.query.section),
      JOB_RANK: optionalIntQuery(req.query.job_rank),
      STATUS: optionalIntQuery(req.query.status),
      STATUS_MODE: workersStatusModeOf(req.query.status_mode),
      VENDOR: req.query.vendor?.trim() || null,
      LOKASI_KERJA: req.query.lokasi_kerja?.trim() || null,
      SEARCH: req.query.q?.trim() || null,
      PAGE: Number(req.query.page) || 1,
      PAGE_SIZE: Number(req.query.page_size) || 0,
    });

    const first = result.recordsets?.[0] ?? [];
    // Invalid SOURCE / CATCH returns a single { success, message } row — not a list.
    if (
      first.length === 1 &&
      Object.prototype.hasOwnProperty.call(first[0], 'success') &&
      Number(first[0].success) === 0
    ) {
      return res.status(400).json({
        success: false,
        message: first[0].message || 'Workers query failed.',
      });
    }

    // Grade is sensitive — never expose on list; reveal only via GET + edit_policy.
    const data = (first || []).map((row) => {
      if (!row || typeof row !== 'object') return row;
      const { grade: _grade, ...rest } = row;
      return rest;
    });

    res.json({
      success: true,
      message: 'Fetched workers',
      data,
      meta: { total: result.recordsets?.[1]?.[0]?.total_count ?? 0 },
    });
  } catch (error) {
    res.status(500).json({ success: false, message: 'Server error', error: error.message });
  }
}

/**
 * Grade field reveal — driven by hr.edit_policy module `workers_grade`
 * (can_edit = may reveal). Missing row → deny.
 */
async function canViewWorkersGrade(req) {
  const levelCode = levelCodeOf(req);
  if (!levelCode) return false;

  const schema = schemaName();
  const pool = await getConnection();
  const result = await pool
    .request()
    .input('BY_JOBSITE', jobsiteOf(req))
    .input('LEVEL_CODE', levelCode)
    .query(`
      SELECT TOP 1 CAST(can_edit AS INT) AS can_edit
      FROM ${schema}.edit_policy
      WHERE by_jobsite = @BY_JOBSITE
        AND deleted_at IS NULL
        AND module_code = N'workers_grade'
        AND LOWER(level_code) = @LEVEL_CODE
    `);

  return Number(result.recordset?.[0]?.can_edit) === 1;
}

/** GET /api/hr/workers/:id?source=sis|vendor|ls — full master row with joined names. */
export async function getWorker(req, res) {
  try {
    if (!isValidId(req.params.id)) {
      return res.status(400).json({ success: false, message: 'Invalid worker id.' });
    }
    const source = workersSourceOf(req.query.source);
    if (!source) {
      return res.status(400).json({
        success: false,
        message: 'Query source is required (sis or vendor/ls).',
      });
    }

    const result = await executeHrSp('WORKERS_SP', 'GET', {
      BY_JOBSITE: jobsiteOf(req),
      SOURCE: source,
      ID: Number(req.params.id),
    });

    const first = result.recordsets?.[0] ?? result.recordset ?? [];
    if (
      first.length === 1 &&
      Object.prototype.hasOwnProperty.call(first[0], 'success') &&
      Number(first[0].success) === 0
    ) {
      return res.status(400).json({
        success: false,
        message: first[0].message || 'Workers GET failed.',
      });
    }

    const row = first[0];
    if (!row) {
      return res.status(404).json({ success: false, message: 'Worker not found.' });
    }

    const canViewGrade = await canViewWorkersGrade(req);
    const data = { ...row };
    if (!canViewGrade) {
      data.grade = null;
    }

    res.json({
      success: true,
      message: 'Fetched worker',
      data,
      meta: { can_view_grade: canViewGrade },
    });
  } catch (error) {
    res.status(500).json({ success: false, message: 'Server error', error: error.message });
  }
}

/** GET /api/hr/workers/example?source=sis|vendor|ls */
export async function downloadWorkersExample(req, res) {
  try {
    const source = workersSourceOf(req.query.source);
    if (!source) {
      return res.status(400).json({
        success: false,
        message: 'Query source is required (sis or vendor/ls).',
      });
    }
    const buffer = buildWorkersExampleXlsx(source);
    const filename =
      source === 'sis' ? 'example_employees_sis.xlsx' : 'example_employees_ls.xlsx';
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

/** GET /api/hr/workers/export?source=… — Grade column only when workers_grade allows */
export async function exportWorkers(req, res) {
  try {
    const source = workersSourceOf(req.query.source);
    if (!source) {
      return res.status(400).json({
        success: false,
        message: 'Query source is required (sis or vendor/ls).',
      });
    }

    const result = await executeHrSp('WORKERS_SP', 'SELECT_EXPORT', {
      BY_JOBSITE: jobsiteOf(req),
      SOURCE: source,
      DEPARTMENT: optionalIntQuery(req.query.department),
      SECTION: optionalIntQuery(req.query.section),
      JOB_RANK: optionalIntQuery(req.query.job_rank),
      STATUS: optionalIntQuery(req.query.status),
      STATUS_MODE: workersStatusModeOf(req.query.status_mode),
      VENDOR: req.query.vendor?.trim() || null,
      LOKASI_KERJA: req.query.lokasi_kerja?.trim() || null,
      SEARCH: req.query.q?.trim() || null,
    });

    const first = result.recordsets?.[0] ?? result.recordset ?? [];
    if (
      first.length === 1 &&
      Object.prototype.hasOwnProperty.call(first[0], 'success') &&
      Number(first[0].success) === 0
    ) {
      return res.status(400).json({
        success: false,
        message: first[0].message || 'Workers export failed.',
      });
    }

    const includeGrade = await canViewWorkersGrade(req);
    const buffer = buildWorkersExportXlsx(first, source, includeGrade);
    const stamp = new Date().toISOString().slice(0, 10);
    const filename =
      source === 'sis'
        ? `employees_sis_${stamp}.xlsx`
        : `employees_ls_${stamp}.xlsx`;
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

/**
 * POST /api/hr/workers/import?source=sis|vendor|ls — multipart field `file`
 * INSERT-only; duplicate active NRP → skipped error. Grade applied only if allowed.
 */
export async function importWorkers(req, res) {
  try {
    const source = workersSourceOf(req.query.source);
    if (!source) {
      return res.status(400).json({
        success: false,
        message: 'Query source is required (sis or vendor/ls).',
      });
    }
    if (!req.file?.buffer) {
      return res.status(400).json({
        success: false,
        message: 'Upload a spreadsheet file in field "file".',
      });
    }

    const parsed = parseWorkersSpreadsheet(
      req.file.buffer,
      req.file.originalname,
      source,
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

    const canSetGrade = await canViewWorkersGrade(req);
    const byUser = actorOf(req);
    const byJobsite = jobsiteOf(req);
    let inserted = 0;
    const errors = [];

    for (const row of parsed.rows) {
      if (!row.nrp || !row.full_name) {
        errors.push({
          row: row.excelRow,
          nrp: row.nrp || null,
          reason: 'nrp and full_name are required.',
        });
        continue;
      }
      if (source === 'vendor' && (!row.vendor || !row.id_finger)) {
        errors.push({
          row: row.excelRow,
          nrp: row.nrp,
          reason: 'vendor and id_finger are required for LS.',
        });
        continue;
      }

      try {
        const result = await executeHrSp('WORKERS_SP', 'INSERT', {
          SOURCE: source,
          NRP: row.nrp,
          FULL_NAME: row.full_name,
          JABATAN: row.jabatan,
          DEPARTMENT_TEXT: row.department,
          SECTION_TEXT: row.section,
          STATUS_TEXT: row.status,
          LEVEL_JABATAN: row.level_jabatan,
          KLASIFIKASI_JABATAN: row.klasifikasi_jabatan,
          JOB_RANK_TEXT: row.job_rank,
          GRADE: canSetGrade ? row.grade : null,
          AREA_KERJA: row.area_kerja,
          STATUS_KARYAWAN_TEXT: row.status_karyawan,
          LOKASI_KERJA: row.lokasi_kerja,
          STAFF_NONSTAFF: row.staff_nonstaff,
          POH: row.poh,
          TANGGAL_MASUK: row.tanggal_masuk,
          TANGGAL_AKHIRKONTRAK: row.tanggal_akhirkontrak,
          TANGGAL_EFEKTIF_DIADARO: row.tanggal_efektif_diadaro,
          TEMPAT_LAHIR: row.tempat_lahir,
          KABUPATEN_LAHIR: row.kabupaten_lahir,
          PROVINSI_LAHIR: row.provinsi_lahir,
          TANGGAL_LAHIR: row.tanggal_lahir,
          PENDIDIKAN: row.pendidikan,
          NAMA_SEKOLAH: row.nama_sekolah,
          JURUSAN: row.jurusan,
          NO_IJASAH: row.no_ijasah,
          TANGGAL_MASUK_SEKOLAH: row.tanggal_masuk_sekolah,
          TANGGAL_LULUS_SEKOLAH: row.tanggal_lulus_sekolah,
          AGAMA: row.agama,
          SUKU: row.suku,
          GOLONGAN_DARAH: row.golongan_darah,
          DIRECT_INDIRECT: row.direct_indirect,
          REMARK_TEXT: row.remark,
          GENDER: row.gender,
          STATUS_KELUARGA: row.status_keluarga,
          ALAMAT: row.alamat,
          ID_FINGER: row.id_finger,
          VENDOR: row.vendor,
          BY_USER: byUser,
          BY_JOBSITE: byJobsite,
        });
        const outcome = spResultRow(result);
        if (outcome?.success) {
          inserted += 1;
        } else {
          errors.push({
            row: row.excelRow,
            nrp: row.nrp,
            reason: outcome?.message || 'Insert failed.',
          });
        }
      } catch (err) {
        errors.push({
          row: row.excelRow,
          nrp: row.nrp,
          reason: err.message || 'Insert failed.',
        });
      }
    }

    const skipped = errors.length;
    if (inserted > 0) {
      logActivity(req, {
        module: 'workers',
        action: 'IMPORT',
        recordKey: source,
        message: `Import workers source=${source} inserted=${inserted} skipped=${skipped}`,
      });
    }

    return res.status(inserted > 0 ? 200 : 400).json({
      success: inserted > 0,
      message:
        inserted > 0
          ? `Imported ${inserted} worker(s); ${skipped} skipped.`
          : `No rows imported; ${skipped} skipped.`,
      data: {
        inserted,
        skipped,
        total: parsed.rows.length,
        errors,
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

function polaKerjaPayload(body = {}) {
  const nrp = String(body.nrp || '').trim().toUpperCase();
  const polaKerja = String(body.pola_kerja || '').trim().toUpperCase();
  const remark = String(body.remark || '').trim().toUpperCase();
  const dateRaw = String(body.date || '').trim();
  const hariKe = body.hari_ke === undefined || body.hari_ke === '' ? null : Number(body.hari_ke);

  let polaCuti = String(body.pola_cuti || '').trim().toUpperCase();
  if (!polaCuti) {
    const masa = String(body.masa_onsite ?? '').trim();
    const cuti = String(body.cuti_lapangan ?? '').trim();
    if (masa !== '' && cuti !== '') polaCuti = `${masa}:${cuti}`.toUpperCase();
  }

  return {
    nrp,
    polaKerja,
    polaCuti,
    remark: remark || null,
    dateRaw,
    hariKe,
    polaHari: body.pola_hari != null ? String(body.pola_hari).trim() : null,
  };
}

/** GET /api/hr/work-pattern?month=YYYY-MM&department=&section=&job_rank=&q=&page=&page_size= */
export async function listWorkPattern(req, res) {
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
    const result = await executeHrSp('WORK_PATTERN_SP', 'SELECT', {
      MONTH: monthRaw,
      DEPARTMENT: parseIdList(req.query.department).join(',') || null,
      SECTION: parseIdList(req.query.section).join(',') || null,
      JOB_RANK: req.query.job_rank?.trim() || null,
      SEARCH: req.query.q?.trim() || null,
      PAGE: Number(req.query.page) || 1,
      PAGE_SIZE: Number(req.query.page_size) || 0,
      SCOPE_SECTIONS: scopeToCsv(scope),
      BY_USER: actorOf(req),
      BY_JOBSITE: jobsiteOf(req),
    });

    res.json({
      success: true,
      message: 'Fetched pola kerja',
      data: result.recordsets?.[0] ?? [],
      meta: {
        total: result.recordsets?.[1]?.[0]?.total_count ?? 0,
        month: monthRaw,
        scoped: !scope.unrestricted,
        scope_sections: scope.unrestricted ? null : scope.sectionIds.length,
      },
    });
  } catch (error) {
    res.status(500).json({ success: false, message: 'Server error', error: error.message });
  }
}

/** GET /api/hr/work-pattern/lookup?nrp= */
export async function lookupWorkPatternWorker(req, res) {
  try {
    const nrp = String(req.query.nrp || '').trim();
    if (!nrp) {
      return res.status(400).json({ success: false, message: 'nrp is required.' });
    }

    const result = await executeHrSp('WORK_PATTERN_SP', 'LOOKUP', {
      NRP: nrp,
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

export async function getWorkPattern(req, res) {
  if (!isValidId(req.params.id)) {
    return res.status(400).json({ success: false, message: 'Invalid pola kerja id.' });
  }

  try {
    const result = await executeHrSp('WORK_PATTERN_SP', 'GET', {
      ID: Number(req.params.id),
      BY_JOBSITE: jobsiteOf(req),
    });
    const row = result.recordset?.[0];
    if (!row) {
      return res.status(404).json({ success: false, message: 'Pola kerja not found.' });
    }
    return res.json({ success: true, message: 'Fetched pola kerja', data: row });
  } catch (error) {
    return res.status(500).json({
      success: false,
      message: 'Server error',
      error: error.message,
    });
  }
}

export async function createWorkPattern(req, res) {
  try {
    const payload = polaKerjaPayload(req.body);
    if (
      !payload.nrp ||
      !payload.dateRaw ||
      !payload.polaKerja ||
      !payload.polaCuti ||
      payload.hariKe == null ||
      !Number.isFinite(payload.hariKe)
    ) {
      return res.status(400).json({
        success: false,
        message: 'nrp, date, pola_kerja, pola_cuti (or masa_onsite+cuti_lapangan), and hari_ke are required.',
      });
    }

    const result = await executeHrSp('WORK_PATTERN_SP', 'INSERT', {
      NRP: payload.nrp,
      DATE: payload.dateRaw,
      POLA_KERJA: payload.polaKerja,
      POLA_CUTI: payload.polaCuti,
      POLA_HARI: payload.polaHari,
      HARI_KE: payload.hariKe,
      REMARK: payload.remark,
      BY_USER: actorOf(req),
      BY_JOBSITE: jobsiteOf(req),
    });

    const response = spResultRow(result);
    if (response?.success) {
      logActivity(req, {
        module: 'work_pattern',
        action: 'INSERT',
        recordId: response.id,
        recordKey: payload.nrp,
        message: `Create work pattern NRP ${payload.nrp}`,
      });
    }
    return res.status(response?.success ? 201 : 400).json({
      success: Boolean(response?.success),
      message: response?.message || 'Failed to save pola kerja.',
      ...(response?.success && { data: { id: response.id } }),
    });
  } catch (error) {
    return res.status(500).json({
      success: false,
      message: 'Server error',
      error: error.message,
    });
  }
}

export async function updateWorkPattern(req, res) {
  if (!isValidId(req.params.id)) {
    return res.status(400).json({ success: false, message: 'Invalid pola kerja id.' });
  }

  try {
    const payload = polaKerjaPayload(req.body);
    if (
      !payload.nrp ||
      !payload.dateRaw ||
      !payload.polaKerja ||
      !payload.polaCuti ||
      payload.hariKe == null ||
      !Number.isFinite(payload.hariKe)
    ) {
      return res.status(400).json({
        success: false,
        message: 'nrp, date, pola_kerja, pola_cuti (or masa_onsite+cuti_lapangan), and hari_ke are required.',
      });
    }

    const result = await executeHrSp('WORK_PATTERN_SP', 'UPDATE', {
      ID: Number(req.params.id),
      NRP: payload.nrp,
      DATE: payload.dateRaw,
      POLA_KERJA: payload.polaKerja,
      POLA_CUTI: payload.polaCuti,
      POLA_HARI: payload.polaHari,
      HARI_KE: payload.hariKe,
      REMARK: payload.remark,
      BY_USER: actorOf(req),
      BY_JOBSITE: jobsiteOf(req),
    });

    const response = spResultRow(result);
    if (response?.success) {
      logActivity(req, {
        module: 'work_pattern',
        action: 'UPDATE',
        recordId: Number(req.params.id),
        recordKey: payload.nrp,
        message: `Update work pattern id=${req.params.id} NRP ${payload.nrp}`,
      });
    }
    return res.status(response?.success ? 200 : 400).json({
      success: Boolean(response?.success),
      message: response?.message || 'Failed to update pola kerja.',
    });
  } catch (error) {
    return res.status(500).json({
      success: false,
      message: 'Server error',
      error: error.message,
    });
  }
}

export async function deleteWorkPattern(req, res) {
  if (!isValidId(req.params.id)) {
    return res.status(400).json({ success: false, message: 'Invalid pola kerja id.' });
  }

  try {
    const result = await executeHrSp('WORK_PATTERN_SP', 'DELETE', {
      ID: Number(req.params.id),
      BY_USER: actorOf(req),
      BY_JOBSITE: jobsiteOf(req),
    });
    const response = spResultRow(result);
    if (response?.success) {
      logActivity(req, {
        module: 'work_pattern',
        action: 'DELETE',
        recordId: Number(req.params.id),
        message: `Delete work pattern id=${req.params.id}`,
      });
    }
    return res.status(response?.success ? 200 : 400).json({
      success: Boolean(response?.success),
      message: response?.message || 'Failed to delete pola kerja.',
    });
  } catch (error) {
    return res.status(500).json({
      success: false,
      message: 'Server error',
      error: error.message,
    });
  }
}

/** GET /api/hr/work-pattern/example — CSV template for mass upload */
export async function downloadWorkPatternExample(_req, res) {
  const csv = buildWorkPatternExampleCsv();
  res.setHeader('Content-Type', 'text/csv; charset=utf-8');
  res.setHeader(
    'Content-Disposition',
    'attachment; filename="example_work_pattern.csv"',
  );
  return res.status(200).send(csv);
}

/** GET /api/hr/work-pattern/export — Excel of filtered list (same filters as SELECT SP) */
export async function exportWorkPattern(req, res) {
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
    const result = await executeHrSp('WORK_PATTERN_SP', 'SELECT', {
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
    const buffer = buildWorkPatternExportXlsx(rows);
    const filename = `work_pattern_${monthRaw}.xlsx`;
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

/** GET /api/hr/work-pattern/generate-preview?month=&nrp= */
export async function previewGenerateWorkPattern(req, res) {
  try {
    const now = new Date();
    const defaultMonth = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}`;
    const monthRaw = String(req.query.month ?? req.body?.month ?? '').trim() || defaultMonth;
    if (!/^\d{4}-\d{2}$/.test(monthRaw)) {
      return res.status(400).json({
        success: false,
        message: 'month must be YYYY-MM',
      });
    }

    const nrp = String(req.query.nrp ?? req.body?.nrp ?? '').trim();
    const scope = await resolveSectionScope(req.user);
    const result = await executeHrSp('WORK_PATTERN_SP', 'GENERATE_PREVIEW', {
      MONTH: monthRaw,
      NRP: nrp || null,
      SCOPE_SECTIONS: scopeToCsv(scope),
      BY_USER: actorOf(req),
      BY_JOBSITE: jobsiteOf(req),
    });

    const data = result.recordsets?.[0] ?? [];
    const total = result.recordsets?.[1]?.[0]?.total_count ?? data.length;
    return res.json({
      success: true,
      message: total > 0 ? 'Preview ready' : 'Tidak ada data untuk digenerate',
      data,
      meta: { total, month: monthRaw },
    });
  } catch (error) {
    return res.status(500).json({
      success: false,
      message: 'Server error',
      error: error.message,
    });
  }
}

/**
 * POST /api/hr/work-pattern/generate
 * Body: { month: 'YYYY-MM', nrp?: '0216,0217' }
 * Expands seed rows into hr.workers_roster_kerja via WORK_PATTERN_SP GENERATE.
 */
export async function generateWorkPattern(req, res) {
  try {
    const now = new Date();
    const defaultMonth = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}`;
    const monthRaw = String(req.body?.month ?? '').trim() || defaultMonth;
    if (!/^\d{4}-\d{2}$/.test(monthRaw)) {
      return res.status(400).json({
        success: false,
        message: 'month must be YYYY-MM',
      });
    }

    const nrp = String(req.body?.nrp ?? '').trim();
    const scope = await resolveSectionScope(req.user);
    const result = await executeHrSp('WORK_PATTERN_SP', 'GENERATE', {
      MONTH: monthRaw,
      NRP: nrp || null,
      SCOPE_SECTIONS: scopeToCsv(scope),
      BY_USER: actorOf(req),
      BY_JOBSITE: jobsiteOf(req),
    });

    const response = spResultRow(result);
    const ok = Boolean(response?.success);
    if (ok) {
      logActivity(req, {
        module: 'work_pattern',
        action: 'GENERATE',
        recordKey: nrp || monthRaw,
        message: `Generate roster month=${monthRaw} workers=${Number(response.workers) || 0}`,
      });
    }
    return res.status(ok ? 200 : 400).json({
      success: ok,
      message: response?.message || 'Generate gagal.',
      data: ok
        ? {
            workers: Number(response.workers) || 0,
            days_upserted: Number(response.days_upserted) || 0,
            month: monthRaw,
          }
        : undefined,
    });
  } catch (error) {
    return res.status(500).json({
      success: false,
      message: 'Server error',
      error: error.message,
    });
  }
}

/**
 * POST /api/hr/work-pattern/import — multipart field `file` (.xlsx/.xls/.csv)
 * Columns: date, nrp, full_name, pola_kerja, pola_cuti, hari_ke, remark
 */
export async function importWorkPattern(req, res) {
  try {
    if (!req.file?.buffer) {
      return res.status(400).json({
        success: false,
        message: 'Upload a spreadsheet file in field "file".',
      });
    }

    const parsed = parseWorkPatternSpreadsheet(
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
    const byJobsite = jobsiteOf(req);
    let inserted = 0;
    const errors = [];

    for (const row of parsed.rows) {
      if (!row.date || !row.nrp || !row.pola_kerja || !row.pola_cuti || row.hari_ke == null) {
        errors.push({
          row: row.excelRow,
          nrp: row.nrp || null,
          reason:
            'date, nrp, pola_kerja, pola_cuti, and hari_ke are required (full_name optional).',
        });
        continue;
      }

      try {
        const result = await executeHrSp('WORK_PATTERN_SP', 'INSERT', {
          NRP: row.nrp,
          DATE: row.date,
          POLA_KERJA: row.pola_kerja,
          POLA_CUTI: row.pola_cuti,
          HARI_KE: row.hari_ke,
          REMARK: row.remark,
          BY_USER: byUser,
          BY_JOBSITE: byJobsite,
        });
        const outcome = spResultRow(result);
        if (outcome?.success) {
          inserted += 1;
        } else {
          errors.push({
            row: row.excelRow,
            nrp: row.nrp,
            reason: outcome?.message || 'Insert failed.',
          });
        }
      } catch (err) {
        errors.push({
          row: row.excelRow,
          nrp: row.nrp,
          reason: err.message || 'Insert failed.',
        });
      }
    }

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

/** GET /api/hr/roster?month=YYYY-MM&department=&section=&job_rank=&q=&page=&page_size= */
export async function listRoster(req, res) {
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
      PAGE: Number(req.query.page) || 1,
      PAGE_SIZE: Number(req.query.page_size) || 0,
      SCOPE_SECTIONS: scopeToCsv(scope),
      BY_USER: actorOf(req),
      BY_JOBSITE: jobsiteOf(req),
    });

    res.json({
      success: true,
      message: 'Fetched roster kerja',
      data: result.recordsets?.[0] ?? [],
      meta: {
        total: result.recordsets?.[1]?.[0]?.total_count ?? 0,
        month: monthRaw,
        scoped: !scope.unrestricted,
        scope_sections: scope.unrestricted ? null : scope.sectionIds.length,
      },
    });
  } catch (error) {
    res.status(500).json({ success: false, message: 'Server error', error: error.message });
  }
}

export async function getRoster(req, res) {
  if (!isValidId(req.params.id)) {
    return res.status(400).json({ success: false, message: 'Invalid roster kerja id.' });
  }

  try {
    const result = await executeHrSp('ROSTER_SP', 'GET', {
      ID: Number(req.params.id),
      BY_JOBSITE: jobsiteOf(req),
    });
    const row = result.recordset?.[0];
    if (!row) {
      return res.status(404).json({ success: false, message: 'Roster kerja not found.' });
    }
    return res.json({ success: true, message: 'Fetched roster kerja', data: row });
  } catch (error) {
    return res.status(500).json({
      success: false,
      message: 'Server error',
      error: error.message,
    });
  }
}

function levelCodeOf(req) {
  return String(req.user?.level_code || req.user?.level || '').trim().toLowerCase();
}

/** sis | ls | all for the Personalia queue. Superadmin sees both groups. */
function sakitWorkerScope(req) {
  const level = levelCodeOf(req);
  if (level === 'superadmin' || level === 'sa') return 'all';
  const scope = String(req.user?.worker_scope || '').trim().toLowerCase();
  if (scope === 'sis' || scope === 'ls' || scope === 'all') return scope;
  return 'none';
}

/** SIS/LS dropdown is only honored for accounts that already see both groups. */
function sakitHrStatusWorker(req) {
  if (sakitWorkerScope(req) !== 'all') return null;
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
    if (response?.success) {
      logActivity(req, {
        module: 'roster',
        action: 'UPDATE',
        recordId: Number(req.params.id),
        message: `Update roster remark=${remark} id=${req.params.id}`,
      });
    }
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

/** GET /api/hr/sickness?month=YYYY-MM&department=&section=&job_rank=&progress=&status_worker=&q=&page=&page_size= */
export async function listSickness(req, res) {
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
    const result = await executeHrSp('SICKNESS_SP', 'SELECT', {
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
      message: 'Fetched sakit',
      data: result.recordsets?.[0] ?? [],
      meta: {
        total: result.recordsets?.[1]?.[0]?.total_count ?? 0,
        month: monthRaw,
        scoped: !scope.unrestricted,
        scope_sections: scope.unrestricted ? null : scope.sectionIds.length,
        status_counts: sakitStatusCounts(result),
      },
    });
  } catch (error) {
    res.status(500).json({ success: false, message: 'Server error', error: error.message });
  }
}

export async function getSickness(req, res) {
  if (!isValidId(req.params.id)) {
    return res.status(400).json({ success: false, message: 'Invalid sakit id.' });
  }

  try {
    const result = await executeHrSp('SICKNESS_SP', 'GET', {
      ID: Number(req.params.id),
      BY_JOBSITE: jobsiteOf(req),
    });
    const row = result.recordset?.[0];
    if (!row) {
      return res.status(404).json({ success: false, message: 'Sickness not found.' });
    }
    return res.json({ success: true, message: 'Fetched sakit', data: row });
  } catch (error) {
    return res.status(500).json({
      success: false,
      message: 'Server error',
      error: error.message,
    });
  }
}

function sakitPayload(body = {}) {
  const category = String(body.category || '')
    .trim()
    .toLowerCase();
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
    dateIssue: body.date_issue
      ? String(body.date_issue).trim().slice(0, 10)
      : null,
    category,
    nameDoctor: String(body.name_doctor || '').trim(),
    nameAgency: String(body.name_agency || '').trim(),
    diagnosa: String(body.diagnosa || '').trim(),
    startDate: body.start_date
      ? String(body.start_date).trim().slice(0, 10)
      : null,
    endDate,
    description:
      body.description != null ? String(body.description).trim() : null,
  };
}

function sakitFieldsValid(payload) {
  return (
    payload.nrp &&
    payload.dateIssue &&
    ['inpatient', 'outpatient', 'pasca'].includes(payload.category) &&
    payload.nameDoctor &&
    payload.nameAgency &&
    payload.diagnosa &&
    payload.startDate
  );
}

async function insertSicknessPhotoRows(jobsite, refId, byUser, files, relDir) {
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
        INSERT INTO ${schema}.workers_sickness_photos (
          by_jobsite, ref_id, [path], name, fullpath, [type],
          meta_key, meta_values, support_attach,
          created_by, updated_at, updated_by
        )
        VALUES (
          @BY_JOBSITE, @REF_ID, @PATH, @NAME, @FULLPATH, @TYPE,
          @META_KEY, @META_VALUES, NULL,
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

/** GET /api/hr/sickness/section — approval queue for Section Head / acting Unit Head */
export async function listSicknessSection(req, res) {
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
    const result = await executeHrSp('SICKNESS_SP', 'SELECT_SECTION', {
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
      message: 'Fetched sakit section queue',
      data: result.recordsets?.[0] ?? [],
      meta: {
        total: result.recordsets?.[1]?.[0]?.total_count ?? 0,
        month: monthRaw,
        scoped: !scope.unrestricted,
        scope_sections: scope.unrestricted ? null : scope.sectionIds.length,
        status_counts: sakitStatusCounts(result),
      },
    });
  } catch (error) {
    res.status(500).json({ success: false, message: 'Server error', error: error.message });
  }
}

function sakitStatusCounts(result) {
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

async function decideSicknessSection(req, res, action) {
  if (!isValidId(req.params.id)) {
    return res.status(400).json({ success: false, message: 'Invalid sakit id.' });
  }
  try {
    const scope = await resolveSectionScope(req.user);
    const result = await executeHrSp('SICKNESS_SP', action, {
      ID: Number(req.params.id),
      NOTE: req.body?.note != null ? String(req.body.note) : null,
      SCOPE_SECTIONS: scopeToCsv(scope),
      LEVEL_CODE: levelCodeOf(req),
      WORKER_SCOPE: sakitWorkerScope(req),
      BY_USER: actorOf(req),
      BY_JOBSITE: jobsiteOf(req),
    });
    const response = spResultRow(result);
    if (response?.success) {
      logActivity(req, {
        module: 'sickness',
        action,
        recordId: Number(req.params.id),
        message: `${action} sickness id=${req.params.id}`,
      });
    }
    if (response?.success && ['APPROVE_SECTION', 'APPROVE_GL', 'APPROVE_DEPT'].includes(action)) {
      notifySicknessHr(Number(req.params.id), jobsiteOf(req)).catch((notifyError) => {
        console.error('sakit hr notify failed:', notifyError.message);
      });
    }
    return res.status(response?.success ? 200 : 400).json({
      success: Boolean(response?.success),
      message: response?.message || 'Failed to update sakit.',
    });
  } catch (error) {
    return res.status(500).json({
      success: false,
      message: 'Server error',
      error: error.message,
    });
  }
}

/** POST /api/hr/sickness/:id/approve-section */
export function approveSicknessSection(req, res) {
  return decideSicknessSection(req, res, 'APPROVE_SECTION');
}

/** POST /api/hr/sickness/:id/reject-section */
export function rejectSicknessSection(req, res) {
  return decideSicknessSection(req, res, 'REJECT_SECTION');
}

/** GET /api/hr/sickness/group — LS queue for Group Leader / Unit Head */
export async function listSicknessGroup(req, res) {
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
    const result = await executeHrSp('SICKNESS_SP', 'SELECT_GL', {
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
      message: 'Fetched sakit group queue',
      data: result.recordsets?.[0] ?? [],
      meta: {
        total: result.recordsets?.[1]?.[0]?.total_count ?? 0,
        month: monthRaw,
        scoped: !scope.unrestricted,
        scope_sections: scope.unrestricted ? null : scope.sectionIds.length,
        status_counts: sakitStatusCounts(result),
      },
    });
  } catch (error) {
    res.status(500).json({ success: false, message: 'Server error', error: error.message });
  }
}

/** POST /api/hr/sickness/:id/approve-group */
export function approveSicknessGroup(req, res) {
  return decideSicknessSection(req, res, 'APPROVE_GL');
}

/** POST /api/hr/sickness/:id/reject-group */
export function rejectSicknessGroup(req, res) {
  return decideSicknessSection(req, res, 'REJECT_GL');
}

/** GET /api/hr/sickness/department — queue for Department Head */
export async function listSicknessDepartment(req, res) {
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
    const result = await executeHrSp('SICKNESS_SP', 'SELECT_DEPT', {
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
      message: 'Fetched sakit department queue',
      data: result.recordsets?.[0] ?? [],
      meta: {
        total: result.recordsets?.[1]?.[0]?.total_count ?? 0,
        month: monthRaw,
        scoped: !scope.unrestricted,
        scope_sections: scope.unrestricted ? null : scope.sectionIds.length,
        status_counts: sakitStatusCounts(result),
      },
    });
  } catch (error) {
    res.status(500).json({ success: false, message: 'Server error', error: error.message });
  }
}

/** GET /api/hr/sickness/hr — final queue for Personalia, split by worker_scope */
export async function listSicknessHr(req, res) {
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

    const result = await executeHrSp('SICKNESS_SP', 'SELECT_HR', {
      MONTH: monthRaw,
      DEPARTMENT: parseIdList(req.query.department).join(',') || null,
      SECTION: parseIdList(req.query.section).join(',') || null,
      JOB_RANK: req.query.job_rank?.trim() || null,
      PROGRESS: req.query.progress?.trim() || null,
      STATUS_WORKER: sakitHrStatusWorker(req),
      SEARCH: req.query.q?.trim() || null,
      PAGE: Number(req.query.page) || 1,
      PAGE_SIZE: Number(req.query.page_size) || 0,
      LEVEL_CODE: levelCodeOf(req),
      WORKER_SCOPE: sakitWorkerScope(req),
      BY_USER: actorOf(req),
      BY_JOBSITE: jobsiteOf(req),
    });

    res.json({
      success: true,
      message: 'Fetched sakit HR queue',
      data: result.recordsets?.[0] ?? [],
      meta: {
        total: result.recordsets?.[1]?.[0]?.total_count ?? 0,
        month: monthRaw,
        scoped: false,
        worker_scope: sakitWorkerScope(req),
        status_counts: sakitStatusCounts(result),
      },
    });
  } catch (error) {
    res.status(500).json({ success: false, message: 'Server error', error: error.message });
  }
}

/** GET /api/hr/sickness/hr/export — same filters as the Personalia list, all rows. */
export async function exportSicknessHr(req, res) {
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

    const workerScope = sakitWorkerScope(req);
    const progress = req.query.progress?.trim() || null;
    const statusWorker = sakitHrStatusWorker(req);
    const result = await executeHrSp('SICKNESS_SP', 'SELECT_HR', {
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
    const buffer = buildSicknessHrExportXlsx(rows, {
      month: monthRaw,
      workerScope,
      progress,
      statusWorker,
    });
    const filename = `sickness_personalia_${monthRaw}.xlsx`;
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

/** POST /api/hr/sickness/:id/approve-hr */
export function approveSicknessHr(req, res) {
  return decideSicknessSection(req, res, 'APPROVE_HR');
}

/** POST /api/hr/sickness/:id/reject-hr */
export function rejectSicknessHr(req, res) {
  return decideSicknessSection(req, res, 'REJECT_HR');
}

/** POST /api/hr/sickness/:id/approve-department */
export function approveSicknessDepartment(req, res) {
  return decideSicknessSection(req, res, 'APPROVE_DEPT');
}

/** POST /api/hr/sickness/:id/reject-department */
export function rejectSicknessDepartment(req, res) {
  return decideSicknessSection(req, res, 'REJECT_DEPT');
}

/** GET /api/hr/sickness/department-exceptions */
export async function listSicknessDepartmentExceptions(req, res) {
  try {
    const result = await executeHrSp('SICKNESS_SP', 'LIST_DEPT_EXCEPTION', {
      BY_USER: actorOf(req),
      BY_JOBSITE: jobsiteOf(req),
    });
    res.json({
      success: true,
      message: 'Fetched department sakit exceptions',
      data: result.recordsets?.[0] ?? [],
    });
  } catch (error) {
    res.status(500).json({ success: false, message: 'Server error', error: error.message });
  }
}

/** POST /api/hr/sickness/department-exceptions */
export async function createSicknessDepartmentException(req, res) {
  try {
    const result = await executeHrSp('SICKNESS_SP', 'INSERT_DEPT_EXCEPTION', {
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

/** DELETE /api/hr/sickness/department-exceptions/:id */
export async function deleteSicknessDepartmentException(req, res) {
  if (!isValidId(req.params.id)) {
    return res.status(400).json({ success: false, message: 'Invalid exception id.' });
  }
  try {
    const result = await executeHrSp('SICKNESS_SP', 'DELETE_DEPT_EXCEPTION', {
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

/** GET /api/hr/sickness/lookup?nrp= */
export async function lookupSicknessWorker(req, res) {
  try {
    const nrp = String(req.query.nrp || '').trim();
    if (!nrp) {
      return res.status(400).json({ success: false, message: 'nrp is required.' });
    }

    const scope = await resolveSectionScope(req.user);
    const result = await executeHrSp('SICKNESS_SP', 'LOOKUP', {
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

/** POST /api/hr/sickness — multipart fields + optional files[] */
export async function createSickness(req, res) {
  const files = Array.isArray(req.files) ? req.files : [];
  try {
    const payload = sakitPayload(req.body);
    if (!sakitFieldsValid(payload)) {
      await cleanupUploadedFiles(files);
      return res.status(400).json({
        success: false,
        message:
          'nrp, date_issue, category, name_doctor, name_agency, diagnosa, and start_date are required.',
      });
    }

    const result = await executeHrSp('SICKNESS_SP', 'INSERT', {
      NRP: payload.nrp,
      FULL_NAME: payload.fullName,
      DATE_ISSUE: payload.dateIssue,
      CATEGORY: payload.category,
      NAME_DOCTOR: payload.nameDoctor,
      NAME_AGENCY: payload.nameAgency,
      DIAGNOSA: payload.diagnosa,
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
        message: response?.message || 'Failed to save sakit.',
      });
    }

    const newId = Number(response.id);
    logActivity(req, {
      module: 'sickness',
      action: 'INSERT',
      recordId: newId,
      recordKey: payload.nrp,
      message: `Create sickness NRP ${payload.nrp}`,
    });

    let reconApproved = false;
    if (isReconAutoApproveLevel(levelCodeOf(req))) {
      reconApproved = await applyReconAutoApprove(
        'sickness',
        newId,
        actorOf(req),
        jobsiteOf(req),
      );
      if (reconApproved) {
        logActivity(req, {
          module: 'sickness',
          action: 'RECON_AUTO_APPROVE',
          recordId: newId,
          recordKey: payload.nrp,
          message: `Recon auto-approve sickness NRP ${payload.nrp} to HR`,
        });
      }
    }
    if (!reconApproved) {
      notifySicknessCreated(newId, jobsiteOf(req)).catch((notifyError) => {
        console.error('sakit notify failed:', notifyError.message);
      });
    }

    const relDir = req.sakitUploadRelDir || 'sakit';
    try {
      await insertSicknessPhotoRows(
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
        message: 'Sickness saved but evidence upload failed.',
        error: photoErr.message,
        data: { id: newId },
      });
    }

    return res.status(201).json({
      success: true,
      message: reconApproved
        ? 'Sickness saved and auto-approved to HR.'
        : response.message || 'Sickness saved successfully.',
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

/** PUT /api/hr/sickness/:id — JSON only (no photo on edit) */
export async function updateSickness(req, res) {
  if (!isValidId(req.params.id)) {
    return res.status(400).json({ success: false, message: 'Invalid sakit id.' });
  }

  try {
    const payload = sakitPayload(req.body);
    if (!sakitFieldsValid(payload)) {
      return res.status(400).json({
        success: false,
        message:
          'nrp, date_issue, category, name_doctor, name_agency, diagnosa, and start_date are required.',
      });
    }

    const result = await executeHrSp('SICKNESS_SP', 'UPDATE', {
      ID: Number(req.params.id),
      NRP: payload.nrp,
      FULL_NAME: payload.fullName,
      DATE_ISSUE: payload.dateIssue,
      CATEGORY: payload.category,
      NAME_DOCTOR: payload.nameDoctor,
      NAME_AGENCY: payload.nameAgency,
      DIAGNOSA: payload.diagnosa,
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
        module: 'sickness',
        action: 'UPDATE',
        recordId: Number(req.params.id),
        recordKey: payload.nrp,
        message: `Update sickness id=${req.params.id} NRP ${payload.nrp}`,
      });
    }
    return res.status(response?.success ? 200 : 400).json({
      success: Boolean(response?.success),
      message: response?.message || 'Failed to update sakit.',
    });
  } catch (error) {
    return res.status(500).json({
      success: false,
      message: 'Server error',
      error: error.message,
    });
  }
}

/** POST /api/hr/sickness/:id/cancel */
export async function cancelSickness(req, res) {
  if (!isValidId(req.params.id)) {
    return res.status(400).json({ success: false, message: 'Invalid sakit id.' });
  }

  try {
    const result = await executeHrSp('SICKNESS_SP', 'CANCEL', {
      ID: Number(req.params.id),
      LEVEL_CODE: levelCodeOf(req),
      BY_USER: actorOf(req),
      BY_JOBSITE: jobsiteOf(req),
    });
    const response = spResultRow(result);
    if (response?.success) {
      logActivity(req, {
        module: 'sickness',
        action: 'CANCEL',
        recordId: Number(req.params.id),
        message: `Cancel sickness id=${req.params.id}`,
      });
    }
    return res.status(response?.success ? 200 : 400).json({
      success: Boolean(response?.success),
      message: response?.message || 'Failed to cancel sakit.',
    });
  } catch (error) {
    return res.status(500).json({
      success: false,
      message: 'Server error',
      error: error.message,
    });
  }
}

function sendSicknessFile(res, relativePath, downloadName) {
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

/** GET /api/hr/sickness/evidence?path=sakit/yyyy/mm/file.jpg — auth-gated by relative path */
export async function getSicknessEvidenceByPath(req, res) {
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
        FROM ${schema}.workers_sickness_photos
        WHERE deleted_at IS NULL
          AND by_jobsite = @BY_JOBSITE
          AND support_attach IS NULL
          AND (fullpath = @FULLPATH OR [path] = @FULLPATH)
      `);
    const row = result.recordset?.[0];
    if (!row?.fullpath) {
      return res.status(404).json({ success: false, message: 'Evidence not found.' });
    }
    return sendSicknessFile(res, row.fullpath, row.name);
  } catch (error) {
    return res.status(500).json({
      success: false,
      message: 'Server error',
      error: error.message,
    });
  }
}

/** GET /api/hr/sickness/evidence/:photoId — auth-gated file serve */
export async function getSicknessEvidence(req, res) {
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
        FROM ${schema}.workers_sickness_photos
        WHERE deleted_at IS NULL
          AND by_jobsite = @BY_JOBSITE
          AND id = @ID
          AND support_attach IS NULL
      `);
    const row = result.recordset?.[0];
    if (!row?.fullpath) {
      return res.status(404).json({ success: false, message: 'Evidence not found.' });
    }
    return sendSicknessFile(res, row.fullpath, row.name);
  } catch (error) {
    return res.status(500).json({
      success: false,
      message: 'Server error',
      error: error.message,
    });
  }
}

function editPolicyPayload(body = {}) {
  const levelCode = String(body.level_code || '').trim().toLowerCase();
  const moduleCode = String(body.module_code || '').trim().toLowerCase();
  const pastDaysRaw = body.past_days;
  const pastDays =
    pastDaysRaw === undefined || pastDaysRaw === '' || pastDaysRaw === null
      ? 0
      : Number(pastDaysRaw);
  return {
    moduleCode: moduleCode || 'roster_kerja',
    levelCode,
    canEdit: body.can_edit === true || body.can_edit === 1 || body.can_edit === '1',
    allowPast:
      body.allow_past === true || body.allow_past === 1 || body.allow_past === '1',
    pastDays: Number.isFinite(pastDays) ? pastDays : NaN,
    description:
      body.description != null ? String(body.description).trim() : null,
  };
}

/** GET /api/hr/edit-policy/modules */
export async function listEditPolicyModules(req, res) {
  try {
    const result = await executeHrSp('EDIT_POLICY_MODULES_SP', 'LIST', {
      BY_USER: actorOf(req),
      BY_JOBSITE: jobsiteOf(req),
    });
    res.json({
      success: true,
      message: 'Fetched edit policy modules',
      data: result.recordset ?? result.recordsets?.[0] ?? [],
    });
  } catch (error) {
    // Fallback if script 49 not applied yet
    try {
      const legacy = await executeHrSp('EDIT_POLICY_SP', 'LIST_MODULES', {
        BY_USER: actorOf(req),
        BY_JOBSITE: jobsiteOf(req),
      });
      return res.json({
        success: true,
        message: 'Fetched edit policy modules',
        data: legacy.recordset ?? legacy.recordsets?.[0] ?? [],
      });
    } catch (fallbackError) {
      return res.status(500).json({
        success: false,
        message: 'Server error',
        error: error.message || fallbackError.message,
      });
    }
  }
}

/** POST /api/hr/edit-policy/modules — create or update catalog row from UI */
export async function upsertEditPolicyModule(req, res) {
  try {
    const moduleCode = String(req.body?.module_code || '')
      .trim()
      .toLowerCase();
    const moduleName = String(req.body?.module_name || '').trim();
    const description =
      req.body?.description != null ? String(req.body.description).trim() : null;
    const sortRaw = req.body?.sort_order;
    const sortOrder =
      sortRaw === undefined || sortRaw === '' || sortRaw === null
        ? null
        : Number(sortRaw);

    if (!moduleCode || !moduleName) {
      return res.status(400).json({
        success: false,
        message: 'module_code and module_name are required.',
      });
    }

    const result = await executeHrSp('EDIT_POLICY_MODULES_SP', 'UPSERT', {
      MODULE_CODE: moduleCode,
      MODULE_NAME: moduleName,
      DESCRIPTION: description,
      SORT_ORDER: Number.isFinite(sortOrder) ? sortOrder : null,
      BY_USER: actorOf(req),
      BY_JOBSITE: jobsiteOf(req),
    });
    const response = spResultRow(result);
    return res.status(response?.success ? 200 : 400).json({
      success: Boolean(response?.success),
      message: response?.message || 'Failed to save module.',
      ...(response?.success && { data: { id: response.id, module_code: moduleCode } }),
    });
  } catch (error) {
    return res.status(500).json({
      success: false,
      message: 'Server error',
      error: error.message,
    });
  }
}

/** GET /api/hr/edit-policy?module=roster_kerja */
export async function listEditPolicy(req, res) {
  try {
    const moduleCode = String(req.query.module || 'roster_kerja').trim().toLowerCase();
    const result = await executeHrSp('EDIT_POLICY_SP', 'SELECT', {
      MODULE_CODE: moduleCode,
      SEARCH: req.query.q?.trim() || null,
      PAGE: Number(req.query.page) || 1,
      PAGE_SIZE: Number(req.query.page_size) || 0,
      BY_USER: actorOf(req),
      BY_JOBSITE: jobsiteOf(req),
    });
    res.json({
      success: true,
      message: 'Fetched edit policies',
      data: result.recordsets?.[0] ?? [],
      meta: {
        total: result.recordsets?.[1]?.[0]?.total_count ?? 0,
        module: moduleCode,
      },
    });
  } catch (error) {
    res.status(500).json({ success: false, message: 'Server error', error: error.message });
  }
}

export async function getEditPolicy(req, res) {
  if (!isValidId(req.params.id)) {
    return res.status(400).json({ success: false, message: 'Invalid policy id.' });
  }
  try {
    const result = await executeHrSp('EDIT_POLICY_SP', 'GET', {
      ID: Number(req.params.id),
      BY_JOBSITE: jobsiteOf(req),
    });
    const row = result.recordset?.[0];
    if (!row) {
      return res.status(404).json({ success: false, message: 'Policy not found.' });
    }
    return res.json({ success: true, message: 'Fetched edit policy', data: row });
  } catch (error) {
    return res.status(500).json({
      success: false,
      message: 'Server error',
      error: error.message,
    });
  }
}

export async function createEditPolicy(req, res) {
  try {
    const payload = editPolicyPayload(req.body);
    if (!payload.levelCode || !Number.isFinite(payload.pastDays) || payload.pastDays < 0) {
      return res.status(400).json({
        success: false,
        message: 'level_code and past_days (>= 0) are required.',
      });
    }
    const result = await executeHrSp('EDIT_POLICY_SP', 'INSERT', {
      MODULE_CODE: payload.moduleCode,
      LEVEL_CODE: payload.levelCode,
      CAN_EDIT: payload.canEdit ? 1 : 0,
      PAST_DAYS: payload.pastDays,
      ALLOW_PAST: payload.allowPast ? 1 : 0,
      DESCRIPTION: payload.description,
      BY_USER: actorOf(req),
      BY_JOBSITE: jobsiteOf(req),
    });
    const response = spResultRow(result);
    if (response?.success) {
      logActivity(req, {
        module: 'edit_policy',
        action: 'INSERT',
        recordId: response.id,
        recordKey: payload.moduleCode,
        message: `Create edit policy ${payload.moduleCode}/${payload.levelCode}`,
      });
    }
    return res.status(response?.success ? 201 : 400).json({
      success: Boolean(response?.success),
      message: response?.message || 'Failed to create policy.',
      ...(response?.success && { data: { id: response.id } }),
    });
  } catch (error) {
    return res.status(500).json({
      success: false,
      message: 'Server error',
      error: error.message,
    });
  }
}

export async function updateEditPolicy(req, res) {
  if (!isValidId(req.params.id)) {
    return res.status(400).json({ success: false, message: 'Invalid policy id.' });
  }
  try {
    const payload = editPolicyPayload(req.body);
    if (!payload.levelCode || !Number.isFinite(payload.pastDays) || payload.pastDays < 0) {
      return res.status(400).json({
        success: false,
        message: 'level_code and past_days (>= 0) are required.',
      });
    }
    const result = await executeHrSp('EDIT_POLICY_SP', 'UPDATE', {
      ID: Number(req.params.id),
      MODULE_CODE: payload.moduleCode,
      LEVEL_CODE: payload.levelCode,
      CAN_EDIT: payload.canEdit ? 1 : 0,
      PAST_DAYS: payload.pastDays,
      ALLOW_PAST: payload.allowPast ? 1 : 0,
      DESCRIPTION: payload.description,
      BY_USER: actorOf(req),
      BY_JOBSITE: jobsiteOf(req),
    });
    const response = spResultRow(result);
    if (response?.success) {
      logActivity(req, {
        module: 'edit_policy',
        action: 'UPDATE',
        recordId: Number(req.params.id),
        recordKey: payload.moduleCode,
        message: `Update edit policy id=${req.params.id}`,
      });
    }
    return res.status(response?.success ? 200 : 400).json({
      success: Boolean(response?.success),
      message: response?.message || 'Failed to update policy.',
    });
  } catch (error) {
    return res.status(500).json({
      success: false,
      message: 'Server error',
      error: error.message,
    });
  }
}

export async function deleteEditPolicy(req, res) {
  if (!isValidId(req.params.id)) {
    return res.status(400).json({ success: false, message: 'Invalid policy id.' });
  }
  try {
    const result = await executeHrSp('EDIT_POLICY_SP', 'DELETE', {
      ID: Number(req.params.id),
      BY_USER: actorOf(req),
      BY_JOBSITE: jobsiteOf(req),
    });
    const response = spResultRow(result);
    if (response?.success) {
      logActivity(req, {
        module: 'edit_policy',
        action: 'DELETE',
        recordId: Number(req.params.id),
        message: `Delete edit policy id=${req.params.id}`,
      });
    }
    return res.status(response?.success ? 200 : 400).json({
      success: Boolean(response?.success),
      message: response?.message || 'Failed to delete policy.',
    });
  } catch (error) {
    return res.status(500).json({
      success: false,
      message: 'Server error',
      error: error.message,
    });
  }
}

/** @deprecated aliases — prefer /edit-policy */
export const listRosterLegacyEditPolicy = listEditPolicy;
export const getRosterLegacyEditPolicy = getEditPolicy;
export const createRosterLegacyEditPolicy = createEditPolicy;
export const updateRosterLegacyEditPolicy = updateEditPolicy;
export const deleteRosterLegacyEditPolicy = deleteEditPolicy;

/** Distinct enum types in hr.enums with row counts (the "catalog" of enums). */
export async function listEnumTypes(req, res) {
  try {
    const schema = schemaName();
    const data = await listQuery(
      `
      SELECT e.type, COUNT(*) AS total
      FROM ${schema}.enums e
      WHERE e.by_jobsite = @BY_JOBSITE AND e.deleted_at IS NULL
      GROUP BY e.type
      ORDER BY e.type
    `,
      jobsiteOf(req),
    );
    res.json({ success: true, message: 'Fetched enum types', data });
  } catch (error) {
    res.status(500).json({ success: false, message: 'Server error', error: error.message });
  }
}

export async function getEnum(req, res) {
  if (!isValidId(req.params.id)) {
    return res.status(400).json({ success: false, message: 'Invalid enum id.' });
  }

  try {
    const result = await executeEnumsSp('GET', {
      ID: Number(req.params.id),
      BY_JOBSITE: jobsiteOf(req),
    });
    const row = result.recordset?.[0];
    if (!row) {
      return res.status(404).json({ success: false, message: 'Enum not found.' });
    }
    return res.json({ success: true, message: 'Fetched enum', data: row });
  } catch (error) {
    return res.status(500).json({
      success: false,
      message: 'Server error',
      error: error.message,
    });
  }
}

export async function createEnum(req, res) {
  try {
    const body = req.body || {};
    const name = String(body.name || '').trim();
    const type = String(body.type || '').trim();

    if (!name || !type) {
      return res.status(400).json({
        success: false,
        message: 'name and type are required.',
      });
    }

    const refId =
      body.ref_id === undefined || body.ref_id === null || body.ref_id === ''
        ? null
        : Number(body.ref_id);

    const result = await executeEnumsSp('INSERT', {
      CODE: body.code ?? null,
      NAME: name,
      CATEGORY: body.category ?? null,
      DESCRIPTION: body.description ?? null,
      TYPE: type,
      REF_ID: Number.isFinite(refId) ? refId : null,
      BY_USER: actorOf(req),
      BY_JOBSITE: jobsiteOf(req),
    });

    const response = spResultRow(result);
    return res.status(response?.success ? 201 : 400).json({
      success: Boolean(response?.success),
      message: response?.message || 'Failed to save enum.',
      ...(response?.success && { data: { id: response.id } }),
    });
  } catch (error) {
    return res.status(500).json({
      success: false,
      message: 'Server error',
      error: error.message,
    });
  }
}

export async function updateEnum(req, res) {
  if (!isValidId(req.params.id)) {
    return res.status(400).json({ success: false, message: 'Invalid enum id.' });
  }

  try {
    const body = req.body || {};
    const clearRef = body.ref_id === null || body.ref_id === '';
    const refId =
      body.ref_id === undefined || clearRef ? null : Number(body.ref_id);

    const result = await executeEnumsSp('UPDATE', {
      ID: Number(req.params.id),
      CODE: body.code ?? null,
      NAME: body.name ?? null,
      CATEGORY: body.category ?? null,
      DESCRIPTION: body.description ?? null,
      TYPE: body.type ?? null,
      REF_ID: Number.isFinite(refId) ? refId : null,
      CLEAR_REF: clearRef ? 1 : 0,
      BY_USER: actorOf(req),
      BY_JOBSITE: jobsiteOf(req),
    });

    const response = spResultRow(result);
    return res.status(response?.success ? 200 : 400).json({
      success: Boolean(response?.success),
      message: response?.message || 'Failed to update enum.',
    });
  } catch (error) {
    return res.status(500).json({
      success: false,
      message: 'Server error',
      error: error.message,
    });
  }
}

export async function deleteEnum(req, res) {
  if (!isValidId(req.params.id)) {
    return res.status(400).json({ success: false, message: 'Invalid enum id.' });
  }

  try {
    const result = await executeEnumsSp('DELETE', {
      ID: Number(req.params.id),
      BY_USER: actorOf(req),
      BY_JOBSITE: jobsiteOf(req),
    });
    const response = spResultRow(result);
    return res.status(response?.success ? 200 : 400).json({
      success: Boolean(response?.success),
      message: response?.message || 'Failed to delete enum.',
    });
  } catch (error) {
    return res.status(500).json({
      success: false,
      message: 'Server error',
      error: error.message,
    });
  }
}

export async function listMenuPrivilege(req, res) {
  try {
    const schema = schemaName();
    const byJobsite = jobsiteOf(req);
    const data = await listQuery(
      `
      SELECT
        id, by_jobsite, name, menu, dashboard,
        access_create, access_read, access_update, access_delete, access_export,
        created_at, updated_at
      FROM ${schema}.menu_privilege
      WHERE by_jobsite = @BY_JOBSITE AND deleted_at IS NULL
      ORDER BY id
    `,
      byJobsite,
    );
    res.json({ success: true, message: 'Fetched menu privilege', data });
  } catch (error) {
    res.status(500).json({ success: false, message: 'Server error', error: error.message });
  }
}

const executeLevelPermissionsSp = (action, params) =>
  executeHrSp('LEVEL_PERMISSIONS_SP', action, params);

function toBit(value, fallback = null) {
  if (value === undefined || value === null || value === '') return fallback;
  if (value === true || value === 1 || value === '1' || value === 'true') return 1;
  if (value === false || value === 0 || value === '0' || value === 'false') return 0;
  return fallback;
}

export async function listLevelPermissions(req, res) {
  try {
    const levelId =
      req.query.level_id === undefined || req.query.level_id === ''
        ? null
        : Number(req.query.level_id);
    if (levelId != null && !Number.isFinite(levelId)) {
      return res.status(400).json({ success: false, message: 'Invalid level_id.' });
    }

    const includeLegacy =
      req.query.include_legacy === '1' ||
      req.query.include_legacy === 'true' ||
      req.query.hr_only === '0';

    const result = await executeLevelPermissionsSp('SELECT', {
      LEVEL_ID: levelId,
      HR_ONLY: includeLegacy ? 0 : 1,
      SEARCH: req.query.q ? String(req.query.q).slice(0, 150) : null,
      BY_USER: actorOf(req),
      BY_JOBSITE: jobsiteOf(req),
    });

    const data = result.recordsets?.[0] || result.recordset || [];
    const total = result.recordsets?.[1]?.[0]?.total_count ?? data.length;
    res.json({
      success: true,
      message: 'Fetched level permissions',
      data,
      meta: { total: Number(total) || 0 },
    });
  } catch (error) {
    res.status(500).json({ success: false, message: 'Server error', error: error.message });
  }
}

/**
 * Bulk upsert matrix rows for one level.
 * Body: { level_id, rows: [{ menu_id, can_read, can_insert, ... }] }
 */
export async function upsertLevelPermissions(req, res) {
  try {
    const levelId = Number(req.body?.level_id);
    const rows = Array.isArray(req.body?.rows) ? req.body.rows : null;

    if (!Number.isFinite(levelId) || !rows) {
      return res.status(400).json({
        success: false,
        message: 'level_id and rows[] are required.',
      });
    }

    if (rows.length === 0) {
      return res.status(400).json({
        success: false,
        message: 'rows must not be empty.',
      });
    }

    const byJobsite = jobsiteOf(req);
    const byUser = actorOf(req);
    const saved = [];

    for (const row of rows) {
      const menuId = Number(row?.menu_id);
      if (!Number.isFinite(menuId)) {
        return res.status(400).json({
          success: false,
          message: 'Each row requires a numeric menu_id.',
        });
      }

      const result = await executeLevelPermissionsSp('UPSERT', {
        ID: row?.id != null && Number.isFinite(Number(row.id)) ? Number(row.id) : null,
        LEVEL_ID: levelId,
        MENU_ID: menuId,
        CAN_READ: toBit(row.can_read, 0),
        CAN_INSERT: toBit(row.can_insert, 0),
        CAN_UPDATE: toBit(row.can_update, 0),
        CAN_DELETE: toBit(row.can_delete, 0),
        CAN_EXPORT: toBit(row.can_export, 0),
        CAN_APPROVE: toBit(row.can_approve, 0),
        AUDIENCE:
          row.audience === undefined
            ? null
            : row.audience == null || row.audience === ''
              ? null
              : String(row.audience).slice(0, 100),
        CLEAR_AUDIENCE:
          row.audience === null || row.audience === '' ? 1 : 0,
        BY_USER: byUser,
        BY_JOBSITE: byJobsite,
      });

      const outcome = spResultRow(result);
      if (!outcome || !outcome.success) {
        return res.status(400).json({
          success: false,
          message: outcome?.message || 'Failed to save level permission.',
          error: { menu_id: menuId },
        });
      }
      saved.push({ menu_id: menuId, id: outcome.id });
    }

    logActivity(req, {
      module: 'level_permissions',
      action: 'UPSERT',
      recordId: levelId,
      message: `Upsert ${saved.length} level permission(s) level_id=${levelId}`,
    });

    res.json({
      success: true,
      message: `Saved ${saved.length} level permission(s).`,
      data: saved,
    });
  } catch (error) {
    res.status(500).json({ success: false, message: 'Server error', error: error.message });
  }
}

/** Ops status for Biostar Finger Pulse ingest (watermarks + recent runs). */
export async function getFingerPulseStatus(req, res) {
  try {
    const byJobsite = Number(req.user?.by_jobsite) || Number(process.env.DEFAULT_JOBSITE_ID) || 1;
    const pool = await getConnection();
    await closeStaleFingerPulseRuns(pool, 5);
    const result = await executeHrSp('FINGER_PULSE_SP', 'STATUS', {
      BY_JOBSITE: byJobsite,
    });
    const sets = result.recordsets || [];
    res.json({
      success: true,
      message: 'Finger Pulse status',
      data: {
        watermarks: sets[0] || [],
        recent_runs: sets[1] || [],
        config: sets[2]?.[0] || null,
      },
    });
  } catch (error) {
    res.status(500).json({
      success: false,
      message: 'Server error',
      error: error.message,
    });
  }
}

/** Combined person-day viewer (mesin + OAMS). */
export async function listFingerPulse(req, res) {
  try {
    const byJobsite = Number(req.user?.by_jobsite) || Number(process.env.DEFAULT_JOBSITE_ID) || 1;
    const page = Math.max(1, Number(req.query.page) || 1);
    const pageSize = Math.min(200, Math.max(1, Number(req.query.page_size) || 25));
    const date =
      req.query.date && String(req.query.date).trim()
        ? String(req.query.date).trim().slice(0, 10)
        : null;
    const result = await executeHrSp(
      'FINGER_PULSE_SP',
      'SELECT',
      {
        DATE: date,
        SEARCH: req.query.q ? String(req.query.q).slice(0, 100) : null,
        SOURCE: req.query.source ? String(req.query.source).slice(0, 20) : 'all',
        COMPLETENESS: req.query.completeness
          ? String(req.query.completeness).slice(0, 30)
          : 'all',
        PAGE: page,
        PAGE_SIZE: pageSize,
        BY_JOBSITE: byJobsite,
      },
      { timeout: 120000 },
    );
    const sets = result.recordsets || [];
    const rows = sets[0] || [];
    const summary = sets[1]?.[0] || {};
    const byStructure = sets[2] || [];
    const missingOutPeople = sets[3] || [];
    const total = Number(summary.total_count) || 0;
    const toIsoDay = (v) => {
      if (v == null) return null;
      if (v instanceof Date && !Number.isNaN(v.getTime())) {
        const y = v.getFullYear();
        const m = String(v.getMonth() + 1).padStart(2, '0');
        const d = String(v.getDate()).padStart(2, '0');
        return `${y}-${m}-${d}`;
      }
      const s = String(v);
      return /^\d{4}-\d{2}-\d{2}/.test(s) ? s.slice(0, 10) : s;
    };
    res.json({
      success: true,
      message: 'Finger Pulse person-day list',
      data: rows,
      meta: {
        total,
        page,
        page_size: pageSize,
        summary: {
          machine_count: Number(summary.machine_count) || 0,
          oams_count: Number(summary.oams_count) || 0,
          both_count: Number(summary.both_count) || 0,
          fingered_count: Number(summary.fingered_count) || 0,
          complete_count: Number(summary.complete_count) || 0,
          missing_out_count: Number(summary.missing_out_count) || 0,
          no_in_count: Number(summary.no_in_count) || 0,
        },
        by_structure: byStructure.map((r) => ({
          department_name: r.department_name || '(Tanpa department)',
          section_name: r.section_name || '(Tanpa section)',
          person_count: Number(r.person_count) || 0,
          fingered_count: Number(r.fingered_count) || 0,
          complete_count: Number(r.complete_count) || 0,
          missing_out_count: Number(r.missing_out_count) || 0,
          no_in_count: Number(r.no_in_count) || 0,
          non_oams_count: Number(r.non_oams_count) || 0,
          oams_count: Number(r.oams_count) || 0,
        })),
        missing_out_people: missingOutPeople.map((r) => ({
          date: toIsoDay(r.date),
          nrp: r.nrp != null ? String(r.nrp) : '',
          full_name: r.full_name != null ? String(r.full_name) : '',
          finger_in: r.finger_in ?? r.machine_in ?? r.oams_in ?? null,
          finger_out: r.finger_out ?? null,
          department_name: r.department_name || '(Tanpa department)',
          section_name: r.section_name || '(Tanpa section)',
        })),
      },
    });
  } catch (error) {
    res.status(500).json({
      success: false,
      message: 'Server error',
      error: error.message,
    });
  }
}

/** Machine punch timeline for one NRP + date. */
export async function listFingerPulsePunches(req, res) {
  try {
    const byJobsite = Number(req.user?.by_jobsite) || Number(process.env.DEFAULT_JOBSITE_ID) || 1;
    const nrp = String(req.query.nrp || '').trim();
    const date = String(req.query.date || '').trim().slice(0, 10);
    if (!nrp || !date) {
      return res.status(400).json({
        success: false,
        message: 'nrp and date are required.',
      });
    }
    const result = await executeHrSp('FINGER_PULSE_SP', 'PUNCHES', {
      NRP: nrp,
      DATE: date,
      BY_JOBSITE: byJobsite,
    });
    const rows = result.recordset || result.recordsets?.[0] || [];
    if (rows[0] && rows[0].success === false) {
      return res.status(400).json({
        success: false,
        message: rows[0].message || 'Failed to load punches.',
      });
    }
    res.json({
      success: true,
      message: 'Finger Pulse punches',
      data: rows,
    });
  } catch (error) {
    res.status(500).json({
      success: false,
      message: 'Server error',
      error: error.message,
    });
  }
}

function canRunFingerPulse(req) {
  const level = String(req.user?.level_code || req.user?.level || '')
    .trim()
    .toLowerCase();
  return level === 'superadmin' || level === 'sa' || level === 'hr_administrator';
}

/**
 * POST /api/hr/finger-pulse/run
 * Manual trigger (same as CLI): pulse | reconcile | backfill.
 * Body: { action, date_from?, date_to? }
 */
export async function runFingerPulse(req, res) {
  if (!canRunFingerPulse(req)) {
    return res.status(403).json({
      success: false,
      message: 'Only HR administrator or superadmin can run Finger Pulse.',
    });
  }

  const action = String(req.body?.action || req.body?.mode || '')
    .trim()
    .toLowerCase();
  if (!['pulse', 'reconcile', 'backfill'].includes(action)) {
    return res.status(400).json({
      success: false,
      message: 'action must be pulse, reconcile, or backfill.',
    });
  }

  const dateFrom =
    req.body?.date_from != null ? String(req.body.date_from).trim().slice(0, 10) : null;
  const dateTo =
    req.body?.date_to != null ? String(req.body.date_to).trim().slice(0, 10) : null;

  const lock = getFingerPulseRunLock();
  if (lock) {
    return res.status(409).json({
      success: false,
      message: `Finger Pulse already running (${lock.mode} since ${lock.startedAt}).`,
      data: { lock },
    });
  }

  // Biostar pulls can take several minutes (especially backfill).
  req.setTimeout?.(900000);
  res.setTimeout?.(900000);

  try {
    const pool = await getConnection();
    const outcome = await runFingerPulseIngest(pool, {
      mode: action,
      dateFrom,
      dateTo,
      log: (msg, extra) => {
        if (extra !== undefined) console.log(`[finger-pulse] ${msg}`, extra);
        else console.log(`[finger-pulse] ${msg}`);
      },
    });
    const status = outcome.success ? 200 : 502;
    return res.status(status).json({
      success: outcome.success,
      message: outcome.message,
      data: outcome,
    });
  } catch (error) {
    const code = error?.code;
    if (code === 'BUSY') {
      return res.status(409).json({
        success: false,
        message: error.message,
        data: { lock: error.lock || getFingerPulseRunLock() },
      });
    }
    if (code === 'BAD_WINDOW' || code === 'BAD_MODE') {
      return res.status(400).json({
        success: false,
        message: error.message,
      });
    }
    if (code === 'DISABLED') {
      return res.status(503).json({
        success: false,
        message: error.message,
      });
    }
    console.error('[finger-pulse] run failed', error);
    return res.status(500).json({
      success: false,
      message: 'Finger Pulse run failed',
      error: error.message,
    });
  }
}
