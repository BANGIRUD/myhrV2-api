/** SQL Server schema for Ticketing app objects (tables, SPs, triggers). */
export const DEFAULT_DB_SCHEMA = 'ticketing';

/** Multi-site MyHR schema (scripts/hr/*.sql). Parallel to legacy dbo. */
export const DEFAULT_HR_SCHEMA = 'hr';

const SCHEMA_PATTERN = /^[A-Za-z_][A-Za-z0-9_]*$/;

function resolveSchemaName(raw, fallback) {
  const value = raw?.trim();

  if (!value) {
    return fallback;
  }

  if (!SCHEMA_PATTERN.test(value)) {
    throw new Error(
      `Invalid schema name "${value}". Use letters, digits, and underscore only.`,
    );
  }

  return value;
}

/**
 * Resolved schema name from DB_SCHEMA env (default: ticketing).
 * Used by FLEET/ticketing SPs.
 * @returns {string}
 */
export function getDbSchema() {
  return resolveSchemaName(process.env.DB_SCHEMA, DEFAULT_DB_SCHEMA);
}

/**
 * Resolved MyHR multi-site schema from HR_SCHEMA env (default: hr).
 * @returns {string}
 */
export function getHrSchema() {
  return resolveSchemaName(process.env.HR_SCHEMA, DEFAULT_HR_SCHEMA);
}

/**
 * Bracket-quoted schema for dynamic SQL (e.g. SET DEFAULT_SCHEMA).
 * @param {string} [schema]
 * @returns {string}
 */
export function quoteSchemaName(schema = getDbSchema()) {
  if (!SCHEMA_PATTERN.test(schema)) {
    throw new Error(`Invalid schema name "${schema}".`);
  }

  return `[${schema.replace(/]/g, ']]')}]`;
}

/**
 * Schema-qualified procedure name for request.execute().
 * Login-mapped SQL users cannot use SET DEFAULT_SCHEMA; qualify explicitly.
 * @param {string} procedureName e.g. 'USERS_SP'
 * @param {'db' | 'hr'} [which='db']
 * @returns {string}
 */
export function qualifyProcedureName(procedureName, which = 'db') {
  const schema = which === 'hr' ? getHrSchema() : getDbSchema();

  if (schema === 'dbo') {
    return procedureName;
  }

  return `${schema}.${procedureName}`;
}

