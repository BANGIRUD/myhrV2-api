/**
 * Azure MYHR production — READ-ONLY access only.
 *
 * Hard rule: never INSERT / UPDATE / DELETE / DDL against Azure.
 * Seed scripts pull SELECT data from here and write only to local DB_*.
 *
 * Usage:
 *   import { openAzureReadonly, azureSelect } from '../config/azureReadonly.js';
 *   const azure = await openAzureReadonly();
 *   const rows = await azureSelect(azure, 'SELECT id FROM dbo.users');
 *   await azure.close();
 */
import sql from 'mssql';
import dotenv from 'dotenv';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
dotenv.config({ path: join(__dirname, '..', '.env') });

/** Mutating / DDL keywords that must never run on Azure via this helper. */
const WRITE_PATTERN =
  /\b(INSERT|UPDATE|DELETE|MERGE|TRUNCATE|DROP|ALTER|CREATE|EXEC(?:UTE)?|GRANT|REVOKE|DENY|BACKUP|RESTORE|OPENROWSET|OPENDATASOURCE|BULK\s+INSERT)\b/i;

const SELECT_INTO_PATTERN = /\bSELECT\b[\s\S]*\bINTO\b/i;

/**
 * Strip comments then ensure every statement is a read-only SELECT / WITH…SELECT.
 * @param {string} sqlText
 */
export function assertAzureReadonlySql(sqlText) {
  if (typeof sqlText !== 'string' || !sqlText.trim()) {
    throw new Error('Azure read-only: empty SQL refused.');
  }

  const stripped = sqlText
    .replace(/\/\*[\s\S]*?\*\//g, ' ')
    .replace(/--[^\n]*/g, ' ')
    .trim();

  const batches = stripped
    .split(';')
    .map((b) => b.trim())
    .filter(Boolean);

  for (const batch of batches) {
    if (!/^(WITH|SELECT)\b/i.test(batch)) {
      throw new Error(
        `Azure is READ-ONLY — refused non-SELECT statement: ${batch.slice(0, 120)}`,
      );
    }

    // Ignore bracketed/quoted identifiers so [delete]/[update] columns don't false-positive
    const bare = batch
      .replace(/\[[^\]]*\]/g, ' ')
      .replace(/N?'(?:''|[^'])*'/gi, ' ')
      .replace(/"(?:""|[^"])*"/g, ' ');

    if (WRITE_PATTERN.test(bare)) {
      throw new Error(
        `Azure is READ-ONLY — refused mutating keyword in: ${batch.slice(0, 120)}`,
      );
    }

    if (SELECT_INTO_PATTERN.test(bare)) {
      throw new Error(
        'Azure is READ-ONLY — SELECT INTO is not allowed (creates objects).',
      );
    }
  }
}

/**
 * Build Azure connection config from AZURE_DB_* (never from DB_* app target).
 * @returns {import('mssql').config}
 */
export function getAzureReadonlyConfig() {
  if (process.env.AZURE_DB_ALLOW_WRITE === '1') {
    throw new Error(
      'AZURE_DB_ALLOW_WRITE is set — refused. Azure access is permanently read-only in this project.',
    );
  }

  const server =
    process.env.AZURE_DB_SERVER ||
    'sqlmisis-prod.6273d55d722a.database.windows.net';
  const user = process.env.AZURE_DB_USER || 'sysadminMyHRDispatch';
  const password = process.env.AZURE_DB_PASSWORD || 'MyHRDispatch2024!';
  const database = process.env.AZURE_DB_NAME || 'MYHR';
  const port = Number(process.env.AZURE_DB_PORT || 1433);

  if (!server || !user || !password || !database || Number.isNaN(port)) {
    throw new Error(
      'Azure read-only config incomplete. Set AZURE_DB_SERVER, AZURE_DB_USER, AZURE_DB_PASSWORD, AZURE_DB_NAME.',
    );
  }

  // Safety: refuse if someone pointed AZURE_* at the same host as writable DB_*
  // and expected writes — we still only SELECT, but log clearly.
  return {
    user,
    password,
    server,
    port,
    database,
    options: {
      encrypt: true,
      trustServerCertificate: false,
      enableArithAbort: true,
      // Prefer readable secondary when available (no-op on single primary).
      readOnlyIntent: true,
    },
    connectionTimeout: 45000,
    requestTimeout: 180000,
  };
}

/**
 * Open a dedicated Azure ConnectionPool (never shares global sql.connect / local pool).
 * @returns {Promise<import('mssql').ConnectionPool>}
 */
export async function openAzureReadonly() {
  const config = getAzureReadonlyConfig();
  const pool = new sql.ConnectionPool(config);
  await pool.connect();
  console.log(
    `✓ Azure READ-ONLY connected: ${config.server}/${config.database} (writes blocked in app)`,
  );
  return pool;
}

/**
 * Run a SELECT-only query on the Azure pool. Throws if SQL is not read-only.
 * @param {import('mssql').ConnectionPool} pool
 * @param {string} sqlText
 * @param {(req: import('mssql').Request) => void} [bind]
 */
export async function azureSelect(pool, sqlText, bind) {
  assertAzureReadonlySql(sqlText);
  const req = pool.request();
  if (typeof bind === 'function') {
    bind(req);
  }
  return req.query(sqlText);
}

export { sql as azureSql };
