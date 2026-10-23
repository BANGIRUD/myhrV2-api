import { getConnection } from '../config/database.js';
import { getHrSchema, quoteSchemaName } from '../config/databaseSchema.js';

const ALL_ACCESS_STAGES = new Set(['all']);
const ALL_ACCESS_CODES = new Set(['superadmin', 'management', 'sa']);

const FULL_MENU_ACCESS_CODES = new Set(['superadmin', 'sa']);

/** Data scope: approval_stage "all" → no structure filter. Not a menu bypass. */
export function isAllAccessUser(user = {}) {
  if (ALL_ACCESS_STAGES.has(String(user.approval_stage || '').toLowerCase())) {
    return true;
  }
  const code = String(user.level_code || user.level || '').toLowerCase();
  return ALL_ACCESS_CODES.has(code);
}

/**
 * Menu scope: only superadmin skips hr.level_permissions.
 * Other levels (incl. administrator / management) follow the matrix
 * migrated from menu_privilege.
 */
export function isFullMenuAccessUser(user = {}) {
  const code = String(user.level_code || user.level || '').toLowerCase();
  return FULL_MENU_ACCESS_CODES.has(code);
}

function mapMenuRow(row, { fullAccess = false } = {}) {
  return {
    menu_id: row.menu_id,
    legacy_id: row.legacy_id ?? null,
    menu_code: row.menu_code,
    menu_name: row.menu_name,
    menu_url: row.menu_url || null,
    path: row.path || row.menu_url || null,
    icon: row.icon || null,
    parent_id: row.parent_id ?? null,
    sort_order: row.sort_order ?? 0,
    show_sidebar: row.show_sidebar !== false && row.show_sidebar !== 0,
    can_read: fullAccess ? true : Boolean(row.can_read),
    can_insert: fullAccess ? true : Boolean(row.can_insert),
    can_update: fullAccess ? true : Boolean(row.can_update),
    can_delete: fullAccess ? true : Boolean(row.can_delete),
    can_export: fullAccess ? true : Boolean(row.can_export),
    can_approve: fullAccess ? true : Boolean(row.can_approve),
    can_import: false,
  };
}

/** All active menus for the jobsite with full flags (superadmin). */
export async function getHrAllMenus(byJobsite = 1) {
  const connection = await getConnection();
  const schema = quoteSchemaName(getHrSchema());
  const result = await connection
    .request()
    .input('BY_JOBSITE', byJobsite)
    .query(`
      SELECT
        m.id AS menu_id,
        m.legacy_id,
        m.menu_code,
        m.menu_name,
        m.menu_url,
        m.menu_url AS path,
        m.icon,
        m.parent_id,
        m.sort_order,
        m.show_sidebar
      FROM ${schema}.menus m
      WHERE m.by_jobsite = @BY_JOBSITE
        AND m.is_active = 1
        AND m.deleted_at IS NULL
      ORDER BY m.sort_order, m.menu_name
    `);

  return (result.recordset || []).map((row) =>
    mapMenuRow({ ...row, can_read: 1 }, { fullAccess: true }),
  );
}

/**
 * Audience tokens of a user: worker_scope (sis | ls | all → sis+ls) and module.
 * Returns null when the user has neither, i.e. no audience narrowing applies.
 */
export function getAudienceTokens(user = {}) {
  const tokens = new Set();
  const scope = String(user.worker_scope || '').trim().toLowerCase();
  const userModule = String(user.module || '').trim().toLowerCase();

  if (scope === 'all') {
    tokens.add('sis');
    tokens.add('ls');
  } else if (scope) {
    tokens.add(scope);
  }
  if (userModule) tokens.add(userModule);

  return tokens.size > 0 ? tokens : null;
}

/** hr.level_permissions.audience: NULL = whole level, else CSV matched to user tokens. */
function matchesAudience(audience, tokens) {
  if (!audience || !tokens) return true;
  return String(audience)
    .split(',')
    .map((t) => t.trim().toLowerCase())
    .filter(Boolean)
    .some((t) => tokens.has(t));
}

export async function getHrPermissionsByLevel(
  levelId,
  byJobsite = 1,
  user = null,
) {
  if (!levelId) return [];

  const connection = await getConnection();
  const schema = quoteSchemaName(getHrSchema());
  const request = connection
    .request()
    .input('LEVEL_ID', levelId)
    .input('BY_JOBSITE', byJobsite);

  const result = await request.query(`
    SELECT
      m.id AS menu_id,
      m.legacy_id,
      m.menu_code,
      m.menu_name,
      m.menu_url,
      m.menu_url AS path,
      m.icon,
      m.parent_id,
      m.sort_order,
      m.show_sidebar,
      lp.audience,
      CAST(ISNULL(lp.can_read, 0) AS BIT) AS can_read,
      CAST(ISNULL(lp.can_insert, 0) AS BIT) AS can_insert,
      CAST(ISNULL(lp.can_update, 0) AS BIT) AS can_update,
      CAST(ISNULL(lp.can_delete, 0) AS BIT) AS can_delete,
      CAST(ISNULL(lp.can_export, 0) AS BIT) AS can_export,
      CAST(ISNULL(lp.can_approve, 0) AS BIT) AS can_approve
    FROM ${schema}.menus m
    INNER JOIN ${schema}.level_permissions lp
      ON lp.menu_id = m.id
     AND lp.level_id = @LEVEL_ID
     AND lp.by_jobsite = @BY_JOBSITE
     AND lp.deleted_at IS NULL
    WHERE m.by_jobsite = @BY_JOBSITE
      AND m.is_active = 1
      AND m.deleted_at IS NULL
    ORDER BY m.sort_order, m.menu_name
  `);

  const tokens = getAudienceTokens(user || {});
  return (result.recordset || [])
    .filter((row) => matchesAudience(row.audience, tokens))
    .map((row) => mapMenuRow(row));
}

export async function getHrNavigationByUser(user = {}) {
  const byJobsite = Number(user.by_jobsite) || 1;

  if (isFullMenuAccessUser(user)) {
    // Superadmin bypasses the permission matrix, but the sidebar still follows
    // the catalog flag: legacy `menu_*` rows (show_sidebar = 0, CodeIgniter URLs)
    // have no React route yet and would land on "page not found".
    const menus = await getHrAllMenus(byJobsite);
    return menus.filter((item) => item.show_sidebar);
  }

  const permissions = await getHrPermissionsByLevel(
    user.level_id,
    byJobsite,
    user,
  );
  return permissions.filter((item) => item.can_read && item.show_sidebar);
}

export async function getHrPermissionsByUser(user = {}) {
  const byJobsite = Number(user.by_jobsite) || 1;

  if (isFullMenuAccessUser(user)) {
    return getHrAllMenus(byJobsite);
  }

  return getHrPermissionsByLevel(user.level_id, byJobsite, user);
}
