/**
 * Apply scripts/hr/*.sql against production (PROD_DB_*), not local DB_*.
 *
 * Safety: CONFIRM_PROD_MIGRATE=YES + PROD_DB_SERVER in PROD_DB_SERVER_ALLOWLIST
 * (see config/prodDatabase.js). Does NOT use AZURE_DB_* (that pool stays read-only).
 *
 * Usage:
 *   node scripts/hr/run_migrate_prod.js            (all numbered files)
 *   node scripts/hr/run_migrate_prod.js 01 02 07   (selected prefixes)
 *
 * Recommended waves: see docs/AZURE_HR_DEPLOY.md
 */
import { readFileSync, readdirSync } from 'fs';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';
import dotenv from 'dotenv';
import {
  assertProdMigrateAllowed,
  getProdDbEnv,
  openProdDatabase,
  prodSql,
} from '../../config/prodDatabase.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
dotenv.config({ path: join(__dirname, '..', '..', '.env') });

function splitBatches(sqlText) {
  return sqlText
    .split(/^\s*GO\s*$/gim)
    .map((batch) => batch.trim())
    .filter(Boolean);
}

const only = process.argv.slice(2).map((n) => String(Number.parseInt(n, 10)));
const files = readdirSync(__dirname)
  .filter((name) => /^\d+_.*\.sql$/i.test(name))
  .filter(
    (name) =>
      only.length === 0 || only.includes(String(Number.parseInt(name, 10))),
  )
  .sort();

if (files.length === 0) {
  console.error('No matching scripts/hr/NN_*.sql files.');
  process.exit(1);
}

const prodMeta = getProdDbEnv();
assertProdMigrateAllowed(prodMeta);
console.log(
  `Applying ${files.length} script(s) to PROD ${prodMeta.server}/${prodMeta.database}…`,
);
const { pool } = await openProdDatabase();

try {
  for (const file of files) {
    const fullPath = join(__dirname, file);
    const text = readFileSync(fullPath, 'utf8');
    const batches = splitBatches(text);
    console.log(`→ ${file} (${batches.length} batch(es))`);

    for (let i = 0; i < batches.length; i += 1) {
      try {
        await pool.request().query(batches[i]);
      } catch (err) {
        console.error(`  FAILED batch ${i + 1} in ${file}:`, err.message);
        process.exit(1);
      }
    }
  }

  // Existence-only summary (avoid SELECT FROM missing tables — SQL Server still binds them in CASE).
  const summary = await pool.request().query(`
    SELECT
      SCHEMA_ID(N'hr') AS hr_schema_id,
      CASE WHEN OBJECT_ID(N'hr.jobsites', 'U') IS NULL THEN 0 ELSE 1 END AS has_jobsites,
      CASE WHEN OBJECT_ID(N'hr.levels', 'U') IS NULL THEN 0 ELSE 1 END AS has_levels,
      CASE WHEN OBJECT_ID(N'hr.menus', 'U') IS NULL THEN 0 ELSE 1 END AS has_menus,
      CASE WHEN OBJECT_ID(N'hr.users', 'U') IS NULL THEN 0 ELSE 1 END AS has_users,
      CASE WHEN OBJECT_ID(N'hr.enums', 'U') IS NULL THEN 0 ELSE 1 END AS has_enums,
      CASE WHEN OBJECT_ID(N'hr.structure', 'U') IS NULL THEN 0 ELSE 1 END AS has_structure,
      CASE WHEN OBJECT_ID(N'hr.workers', 'U') IS NULL THEN 0 ELSE 1 END AS has_workers
  `);

  console.log('OK', summary.recordset[0]);
} finally {
  await pool.close();
  await prodSql.close().catch(() => {});
}

process.exit(0);
