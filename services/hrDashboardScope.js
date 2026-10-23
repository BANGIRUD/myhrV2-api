import { getConnection, sql } from '../config/database.js';
import { getHrSchema, quoteSchemaName } from '../config/databaseSchema.js';
import { isAllAccessUser } from './hrMenuPermission.js';

/** Numeric ids from a CSV / array / number (invalid tokens dropped). */
export function parseIdList(value) {
  if (value == null || value === '') return [];
  const parts = Array.isArray(value) ? value : String(value).split(',');
  return [
    ...new Set(
      parts
        .map((p) => Number.parseInt(String(p).trim(), 10))
        .filter((n) => Number.isFinite(n) && n > 0),
    ),
  ];
}

/**
 * Sections the signed-in user may see on structure-based dashboards.
 *
 * - all-access users (`approval_stage = all`, superadmin, management) → unrestricted
 * - levels with `structure_scoped = false` → unrestricted
 * - otherwise (any level, driven purely by the user's row in `hr.users`):
 *   - `section` ids assigned → exactly those sections (`department` does not widen the scope)
 *   - no `section` assigned → every section of their `department` ids
 *
 * Keep in sync with the frontend `scopeStructureOptions` (src/utils/structure.ts).
 * Returns `{ unrestricted: true }` or `{ unrestricted: false, sectionIds: number[] }`.
 * A scoped user with no assignment gets an empty list (sees nothing).
 */
export async function resolveSectionScope(user = {}) {
  if (isAllAccessUser(user)) return { unrestricted: true, sectionIds: [] };
  if (user.structure_scoped === false) return { unrestricted: true, sectionIds: [] };

  const sectionIds = new Set(parseIdList(user.section));
  const departmentIds = parseIdList(user.department);

  if (departmentIds.length && sectionIds.size === 0) {
    const pool = await getConnection();
    const schema = quoteSchemaName(getHrSchema());
    const result = await pool
      .request()
      .input('by_jobsite', sql.Int, Number(user.by_jobsite) || 1)
      .input('department_ids', sql.NVarChar, departmentIds.join(',')).query(`
        SELECT s.id
        FROM ${schema}.structure s
        WHERE s.by_jobsite = @by_jobsite
          AND s.deleted_at IS NULL
          AND s.type = N'section'
          AND TRY_CAST(s.ref_id AS INT) IN (
            SELECT TRY_CAST(value AS INT) FROM STRING_SPLIT(@department_ids, N',')
          )
      `);
    for (const row of result.recordset || []) sectionIds.add(Number(row.id));
  }

  return { unrestricted: false, sectionIds: [...sectionIds] };
}

/** CSV for `@SCOPE_SECTIONS`; scoped-but-empty maps to `0` (matches no section). */
export function scopeToCsv(scope) {
  if (scope.unrestricted) return '';
  return scope.sectionIds.length ? scope.sectionIds.join(',') : '0';
}
