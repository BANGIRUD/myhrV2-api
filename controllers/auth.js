import bcrypt from 'bcrypt';
import jwt from 'jsonwebtoken';
import { getConnection, sql } from '../config/database.js';
import { getHrSchema } from '../config/databaseSchema.js';

const JWT_SECRET = process.env.JWT_SECRET || 'myhr-dev-secret';
const BYPASS_PASSWORD = process.env.BYPASS_PASSWORD || null;
const DEFAULT_JOBSITE_ID = Number(process.env.DEFAULT_JOBSITE_ID) || 1;
const BCRYPT_ROUNDS = 10;

function hrQualify(objectName) {
  return `${getHrSchema()}.${objectName}`;
}

/** Login against hr.v_user_login (canonical level + matrix menus). */
function loginQuery() {
  return `
  SELECT *
  FROM ${hrQualify('v_user_login')}
  WHERE username = @username
    AND by_jobsite = @by_jobsite
    AND is_active = 1
`;
}

/** GL fallback — hr.v_users_gl_login (group leaders from hr.v_workers_active). */
function loginGlQuery() {
  return `
  SELECT *
  FROM ${hrQualify('v_users_gl_login')}
  WHERE username = @username
`;
}

function loginByIdQuery() {
  return `
  SELECT *
  FROM ${hrQualify('v_user_login')}
  WHERE id = @id
    AND is_active = 1
`;
}

function toBoolFlag(value) {
  if (value === true || value === 1) return true;
  if (value === false || value === 0 || value == null) return false;
  return ['true', '1', 'yes'].includes(String(value).toLowerCase());
}

export function buildUserData(row) {
  const menuRaw = row.menu == null ? '' : String(row.menu);
  const menuArr =
    menuRaw === '*'
      ? ['*']
      : menuRaw.split(',').map((s) => s.trim()).filter(Boolean);
  const privArr = (row.privilege_menu || '')
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean);
  const allMenu =
    menuArr[0] === '*'
      ? ['*']
      : [...new Set([...menuArr, ...privArr])];

  let path_foto = 'public/assets/images/users/man.png';
  const gender = (row.gender || '').toLowerCase();
  if (gender === 'laki-laki') {
    path_foto = 'public/assets/images/users/man.png';
  } else if (gender === 'perempuan') {
    path_foto = 'public/assets/images/users/women.png';
  }

  const structure =
    row.department || row.section
      ? (row.department || '') + ',' + (row.section || '')
      : '';

  const legacyLevel =
    row.level || row.legacy_level_code || row.legacy_level || null;

  return {
    id: row.id || row.username,
    username: row.username,
    full_name: row.full_name,
    email: row.email || null,
    phone: row.phone || null,
    ref_id: row.ref_id || null,
    privilege_menu: row.privilege_menu || null,
    level: legacyLevel,
    section: row.section,
    department: row.department,
    section_name: row.section_name || null,
    department_name: row.department_name || null,
    section_fw: row.section_fw || null,
    department_fw: row.department_fw || null,
    description: row.description || null,
    dashboard: row.dashboard || null,
    menu: allMenu,
    path_foto,
    structure,
    access_read: row.read || null,
    access_update: row.update || null,
    access_create: row.create || null,
    access_delete: row.delete || null,
    access_export: row.export || null,
    access_approve: row.approve || null,
    // Canonical hr.levels / multi-site
    level_id: row.level_id != null ? Number(row.level_id) : null,
    level_code: row.level_code || null,
    level_name: row.level_name || null,
    by_jobsite:
      row.by_jobsite != null ? Number(row.by_jobsite) : DEFAULT_JOBSITE_ID,
    approval_stage: row.approval_stage || null,
    structure_scoped:
      row.structure_scoped == null ? null : toBoolFlag(row.structure_scoped),
    // Per-user attributes that replaced merged levels
    worker_scope: row.worker_scope || null, // sis | ls | all (hr_admin / hr_administrator)
    module: row.module || null, // irel | meals | safety | attendance (module_admin)
  };
}

function toIdList(csv) {
  return String(csv ?? '')
    .split(',')
    .map((s) => Number.parseInt(s.trim(), 10))
    .filter(Number.isFinite)
    .join(',');
}

/**
 * Department → sections tree from hr.structure for the user's assigned ids.
 * Parent departments of assigned sections are included even when the user
 * row does not list them.
 */
async function loadStructureTree(userData) {
  const departmentIds = toIdList(userData.department);
  const sectionIds = toIdList(userData.section);
  if (!departmentIds && !sectionIds) return [];

  const pool = await getConnection();
  const result = await pool
    .request()
    .input('by_jobsite', sql.Int, userData.by_jobsite ?? DEFAULT_JOBSITE_ID)
    .input('department_ids', sql.NVarChar, departmentIds)
    .input('section_ids', sql.NVarChar, sectionIds)
    .query(`
      WITH active_workers AS (
        SELECT w.department, w.section
        FROM ${hrQualify('v_workers_active')} w
        WHERE w.by_jobsite = @by_jobsite
      ),
      picked_sections AS (
        SELECT s.id, s.name, TRY_CAST(s.ref_id AS INT) AS department_id, s.by_order
        FROM ${hrQualify('structure')} s
        WHERE s.by_jobsite = @by_jobsite
          AND s.deleted_at IS NULL
          AND s.type = N'section'
          AND s.id IN (SELECT TRY_CAST(value AS INT) FROM STRING_SPLIT(@section_ids, N','))
      )
      SELECT
        d.id, d.name, N'department' AS type, NULL AS department_id, d.by_order,
        (SELECT COUNT(*) FROM active_workers aw WHERE aw.department = d.id) AS worker_count
      FROM ${hrQualify('structure')} d
      WHERE d.by_jobsite = @by_jobsite
        AND d.deleted_at IS NULL
        AND d.type = N'department'
        AND (
          d.id IN (SELECT TRY_CAST(value AS INT) FROM STRING_SPLIT(@department_ids, N','))
          OR d.id IN (SELECT department_id FROM picked_sections)
        )
      UNION ALL
      SELECT
        ps.id, ps.name, N'section', ps.department_id, ps.by_order,
        (SELECT COUNT(*) FROM active_workers aw WHERE aw.section = ps.id)
      FROM picked_sections ps
      ORDER BY by_order, name
    `);

  const departments = new Map();
  for (const row of result.recordset) {
    if (row.type === 'department') {
      departments.set(row.id, {
        id: row.id,
        name: row.name,
        worker_count: row.worker_count ?? 0,
        sections: [],
      });
    }
  }

  const unassigned = [];
  for (const row of result.recordset) {
    if (row.type !== 'section') continue;
    const section = {
      id: row.id,
      name: row.name,
      worker_count: row.worker_count ?? 0,
    };
    const parent = departments.get(row.department_id);
    if (parent) parent.sections.push(section);
    else unassigned.push(section);
  }

  // Same rule as services/hrDashboardScope.js: with sections assigned, only those sections count.
  // A department then shows the workers of ITS ASSIGNED SECTIONS (not the whole department) and
  // departments without any assigned section are not listed.
  if (sectionIds) {
    for (const [id, dept] of departments) {
      if (dept.sections.length === 0) {
        departments.delete(id);
        continue;
      }
      dept.worker_count = dept.sections.reduce((sum, s) => sum + s.worker_count, 0);
    }
  }

  const tree = [...departments.values()];
  if (unassigned.length > 0) {
    tree.push({
      id: null,
      name: null,
      worker_count: unassigned.reduce((sum, s) => sum + s.worker_count, 0),
      sections: unassigned,
    });
  }
  return tree;
}

async function withStructureTree(userData) {
  try {
    return { ...userData, structure_tree: await loadStructureTree(userData) };
  } catch (err) {
    console.error('Failed to load structure tree:', err.message);
    return { ...userData, structure_tree: [] };
  }
}

async function authenticationUser(username, byJobsite = DEFAULT_JOBSITE_ID) {
  const pool = await getConnection();
  let result = await pool
    .request()
    .input('username', sql.NVarChar, username)
    .input('by_jobsite', sql.Int, byJobsite)
    .query(loginQuery());

  if (result.recordset.length === 0) {
    result = await pool
      .request()
      .input('username', sql.NVarChar, username)
      .query(loginGlQuery());
    result.isGLUser = true;
  }

  return result;
}

async function findUserById(id) {
  const pool = await getConnection();
  return pool.request().input('id', sql.Int, id).query(loginByIdQuery());
}

async function verifyPassword(password, hashFromDb) {
  if (BYPASS_PASSWORD && password === BYPASS_PASSWORD) return true;
  if (!hashFromDb) return false;
  return bcrypt.compare(password, hashFromDb);
}

function buildTokenClaims(userData) {
  return {
    id: userData.id,
    username: userData.username,
    full_name: userData.full_name,
    level: userData.level,
    level_id: userData.level_id,
    level_code: userData.level_code,
    by_jobsite: userData.by_jobsite,
    approval_stage: userData.approval_stage,
    structure_scoped: userData.structure_scoped,
    worker_scope: userData.worker_scope,
    module: userData.module,
    section: userData.section,
    department: userData.department,
    section_fw: userData.section_fw,
    department_fw: userData.department_fw,
  };
}

export const loginUser = async (username, password, { remember_me } = {}) => {
  const result = await authenticationUser(username);

  if (result.recordset.length === 0) {
    return { success: false, message: 'Invalid username or password.' };
  }

  const row = result.recordset[0];
  const isMatch = await verifyPassword(password, row.password);
  if (!isMatch) {
    return { success: false, message: 'Invalid username or password.' };
  }

  // Update last_login only for hr.users (not GL)
  if (!result.isGLUser) {
    const pool = await getConnection();
    await pool
      .request()
      .input('id', sql.Int, row.id)
      .query(
        `UPDATE ${hrQualify('users')} SET last_login = SYSUTCDATETIME() WHERE id = @id`,
      );
  }

  const userData = await withStructureTree(buildUserData(row));
  const expiresIn = remember_me ? '7d' : process.env.JWT_EXPIRES || '18h';
  const expirationMs = remember_me
    ? 7 * 24 * 60 * 60 * 1000
    : 18 * 60 * 60 * 1000;
  const expiresAt = Date.now() + expirationMs;

  const token = jwt.sign(buildTokenClaims(userData), JWT_SECRET, {
    expiresIn,
  });

  return {
    success: true,
    message: 'Login successful.',
    data: {
      token,
      expiresAt,
      user: userData,
    },
  };
};

export const verifyAuthToken = (token) => {
  return jwt.verify(token, JWT_SECRET);
};

/**
 * Reload user from hr.v_user_login (GL fallback via username).
 * Prefer username from JWT; fall back to numeric id for regular users.
 */
export async function getUserProfile(userIdOrClaims, _context = {}) {
  const claims =
    userIdOrClaims && typeof userIdOrClaims === 'object'
      ? userIdOrClaims
      : { id: userIdOrClaims };

  const byJobsite =
    claims.by_jobsite != null
      ? Number(claims.by_jobsite)
      : DEFAULT_JOBSITE_ID;

  let result = null;

  if (claims.username) {
    result = await authenticationUser(claims.username, byJobsite);
  } else if (claims.id != null && Number.isFinite(Number(claims.id))) {
    result = await findUserById(Number(claims.id));
  }

  if (!result || result.recordset.length === 0) {
    return { success: false, message: 'User not found.' };
  }

  return {
    success: true,
    message: 'Fetched user profile successfully.',
    data: await withStructureTree(buildUserData(result.recordset[0])),
  };
}

/**
 * Change password for the authenticated hr.users account.
 * BYPASS_PASSWORD is intentionally NOT honored here (login-only).
 * GL-only accounts without an hr.users row are rejected.
 */
export async function changePassword(
  userClaims,
  { old_password, new_password, renew_password } = {},
) {
  if (!old_password || !new_password || !renew_password) {
    return {
      success: false,
      code: 'VALIDATION',
      message: 'Old password, new password, and confirmation are required.',
    };
  }

  if (String(new_password).length < 6) {
    return {
      success: false,
      code: 'VALIDATION',
      message: 'New password must be at least 6 characters.',
    };
  }

  if (new_password !== renew_password) {
    return {
      success: false,
      code: 'VALIDATION',
      message: 'New password confirmation does not match.',
    };
  }

  const userId =
    userClaims?.id != null && Number.isFinite(Number(userClaims.id))
      ? Number(userClaims.id)
      : null;

  if (userId == null) {
    return {
      success: false,
      code: 'UNSUPPORTED',
      message: 'Password change is not available for this account.',
    };
  }

  const pool = await getConnection();
  const existing = await pool
    .request()
    .input('id', sql.Int, userId)
    .query(
      `SELECT id, password, username
       FROM ${hrQualify('users')}
       WHERE id = @id
         AND deleted_at IS NULL`,
    );

  if (existing.recordset.length === 0) {
    return {
      success: false,
      code: 'UNSUPPORTED',
      message: 'Password change is not available for this account.',
    };
  }

  const row = existing.recordset[0];
  const isMatch = row.password
    ? await bcrypt.compare(String(old_password), String(row.password))
    : false;

  if (!isMatch) {
    return {
      success: false,
      code: 'INVALID_PASSWORD',
      message: 'Current password is incorrect.',
    };
  }

  const hashed = await bcrypt.hash(String(new_password), BCRYPT_ROUNDS);
  const updatedById = Number(userClaims?.id) || Number(row.id) || null;

  await pool
    .request()
    .input('id', sql.Int, row.id)
    .input('password', sql.NVarChar, hashed)
    .input('updated_by', sql.Int, updatedById)
    .query(
      `UPDATE ${hrQualify('users')}
       SET password = @password,
           updated_at = SYSUTCDATETIME(),
           updated_by = @updated_by
       WHERE id = @id
         AND deleted_at IS NULL`,
    );

  return {
    success: true,
    message: 'Password changed successfully.',
  };
}
