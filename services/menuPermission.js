import { getConnection } from '../config/database.js';
import { quoteSchemaName } from '../config/databaseSchema.js';

const SUPERADMIN_LEVEL_CODES = new Set(['admin', 'superadmin', 'sa']);

export function isSuperadminUser(user = {}) {
  const code = String(user.level_code || '').toLowerCase();
  return SUPERADMIN_LEVEL_CODES.has(code) || Number(user.level_id) === 1;
}

/**
 * Check menu_permission for a level (+ optional jobsite).
 * permissionType: read | insert | update | delete | export | import | any_read
 */
export async function checkMenuPermission({
  levelId,
  byJobsite = null,
  permissionType,
  menuCode = null,
  menuCodes = null,
  any = false,
}) {
  if (!levelId) {
    return { allowed: false, message: 'Level is required.' };
  }

  if (permissionType === 'any_read') {
    const permissions = await getPermissionsByLevel(levelId, byJobsite);
    const allowed = permissions.some((item) => item.can_read);
    return {
      allowed,
      message: allowed ? null : 'Access denied.',
    };
  }

  const codes = Array.isArray(menuCodes)
    ? menuCodes.filter(Boolean)
    : menuCode
      ? [menuCode]
      : [];

  if (!codes.length) {
    return { allowed: false, message: 'Menu code is required.' };
  }

  const permissions = await getPermissionsByLevel(levelId, byJobsite);
  const matched = permissions.filter((item) => codes.includes(item.menu_code));

  if (!matched.length) {
    return { allowed: false, message: 'Access denied.' };
  }

  const flagKey = `can_${permissionType}`;
  const allowed = any
    ? matched.some((item) => Boolean(item[flagKey]))
    : matched.every((item) => Boolean(item[flagKey]));

  return {
    allowed,
    message: allowed ? null : 'Access denied.',
  };
}

export async function getPermissionsByLevel(levelId, byJobsite = null) {
  try {
    const connection = await getConnection();
    const request = connection.request().input('LEVEL_ID', levelId);

    let jobsiteFilter = '';
    if (byJobsite != null && byJobsite !== '') {
      request.input('BY_JOBSITE', byJobsite);
      jobsiteFilter = `
        AND (
          mp.by_jobsite IS NULL
          OR mp.by_jobsite = @BY_JOBSITE
        )
      `;
    }

    const schema = quoteSchemaName();
    const result = await request.query(`
      SELECT
        m.id AS menu_id,
        m.menu_code,
        m.menu_name,
        m.menu_url AS path,
        m.menu_url,
        m.icon,
        m.parent_id,
        m.sort_order,
        m.show_sidebar,
        CAST(ISNULL(mp.can_read, 0) AS BIT) AS can_read,
        CAST(ISNULL(mp.can_insert, 0) AS BIT) AS can_insert,
        CAST(ISNULL(mp.can_update, 0) AS BIT) AS can_update,
        CAST(ISNULL(mp.can_delete, 0) AS BIT) AS can_delete,
        CAST(ISNULL(mp.can_export, 0) AS BIT) AS can_export,
        CAST(ISNULL(mp.can_import, 0) AS BIT) AS can_import
      FROM ${schema}.menus m
      LEFT JOIN ${schema}.menu_permissions mp
        ON mp.menu_id = m.id
       AND mp.level_id = @LEVEL_ID
       AND mp.deleted_at IS NULL
       ${jobsiteFilter}
      WHERE m.is_active = 1
        AND m.deleted_at IS NULL
      ORDER BY m.sort_order, m.menu_name
    `);

    return result.recordset || [];
  } catch (error) {
    console.error('Failed to load menu permissions:', error.message);
    if (process.env.NODE_ENV === 'development') {
      return [];
    }
    throw error;
  }
}

export async function getNavigationByLevel(levelId, byJobsite = null) {
  const permissions = await getPermissionsByLevel(levelId, byJobsite);
  return permissions.filter((item) => item.can_read);
}
