/**
 * Azure / production MyHR — writable connection for schema `hr` only.
 *
 * Separate from:
 *   - DB_*          → local day-to-day app / local migrate
 *   - AZURE_DB_*    → read-only seed pull (config/azureReadonly.js)
 *
 * Used by: scripts/hr/run_migrate_prod.js, sync_dbo_to_hr_prod.js,
 *          verify_id_alignment_prod.js
 *
 * Safety:
 *   - CONFIRM_PROD_MIGRATE=YES required
 *   - PROD_DB_SERVER must appear in PROD_DB_SERVER_ALLOWLIST (comma-separated)
 *   - Never reuse AZURE_DB_* credentials here
 */
import sql from 'mssql';
import dotenv from 'dotenv';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
dotenv.config({ path: join(__dirname, '..', '.env') });

/**
 * @returns {{ user: string, password: string, server: string, port: number, database: string }}
 */
export function getProdDbEnv() {
  const server = (process.env.PROD_DB_SERVER || '').trim();
  const user = (process.env.PROD_DB_USER || '').trim();
  const password = process.env.PROD_DB_PASSWORD || '';
  const database = (process.env.PROD_DB_NAME || '').trim();
  const port = Number.parseInt(process.env.PROD_DB_PORT || '1433', 10);

  if (!server || !user || !password || !database || Number.isNaN(port)) {
    throw new Error(
      'PROD_DB_* incomplete. Set PROD_DB_SERVER, PROD_DB_PORT, PROD_DB_NAME, PROD_DB_USER, PROD_DB_PASSWORD.',
    );
  }

  return { server, user, password, database, port };
}

/**
 * Refuse unless confirm gate + allowlist match.
 * @param {{ server: string }} env
 */
export function assertProdMigrateAllowed(env = getProdDbEnv()) {
  if (process.env.CONFIRM_PROD_MIGRATE !== 'YES') {
    throw new Error(
      'Refused: set CONFIRM_PROD_MIGRATE=YES to run production migrate/sync/verify scripts.',
    );
  }

  const allowlist = (process.env.PROD_DB_SERVER_ALLOWLIST || '')
    .split(',')
    .map((s) => s.trim().toLowerCase())
    .filter(Boolean);

  if (allowlist.length === 0) {
    throw new Error(
      'Refused: set PROD_DB_SERVER_ALLOWLIST to a comma-separated list of allowed hostnames.',
    );
  }

  const target = env.server.toLowerCase();
  if (!allowlist.includes(target)) {
    throw new Error(
      `Refused: PROD_DB_SERVER "${env.server}" is not in PROD_DB_SERVER_ALLOWLIST (${allowlist.join(', ')}).`,
    );
  }
}

/**
 * mssql config for production (writable; encrypt on; no trustServerCertificate for Azure).
 * @returns {import('mssql').config}
 */
export function getProdDatabaseConfig() {
  const env = getProdDbEnv();
  assertProdMigrateAllowed(env);

  return {
    user: env.user,
    password: env.password,
    server: env.server,
    port: env.port,
    database: env.database,
    options: {
      encrypt: true,
      trustServerCertificate: false,
      enableArithAbort: true,
    },
    pool: {
      max: 5,
      min: 0,
      idleTimeoutMillis: 30000,
    },
    connectionTimeout: 45000,
    requestTimeout: 600000,
  };
}

/**
 * Open a dedicated ConnectionPool to production (does not share local sql.connect).
 * @returns {Promise<{ pool: import('mssql').ConnectionPool, meta: ReturnType<typeof getProdDbEnv> }>}
 */
export async function openProdDatabase() {
  const meta = getProdDbEnv();
  assertProdMigrateAllowed(meta);
  const config = getProdDatabaseConfig();
  const pool = new sql.ConnectionPool(config);
  await pool.connect();
  console.log(
    `✓ PROD connected (writable hr): ${meta.server}/${meta.database} (port ${meta.port})`,
  );
  return { pool, meta };
}

export { sql as prodSql };
