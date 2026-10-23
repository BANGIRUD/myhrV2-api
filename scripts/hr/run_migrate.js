/**
 * Apply scripts/hr/*.sql in order against the configured DB.
 * Usage: node scripts/hr/run_migrate.js            (all files)
 *        node scripts/hr/run_migrate.js 08 09 27   (only files with these numeric prefixes)
 */
import { readFileSync, readdirSync } from 'fs';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';
import dotenv from 'dotenv';
import { getConnection, sql } from '../../config/database.js';

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

const pool = await getConnection();

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

const summary = await pool.request().query(`
  SELECT
    (SELECT COUNT(*) FROM hr.jobsites WHERE deleted_at IS NULL) AS jobsites,
    (SELECT COUNT(*) FROM hr.menu_privilege) AS privileges,
    (SELECT COUNT(*) FROM hr.levels WHERE deleted_at IS NULL) AS levels,
    (SELECT COUNT(*) FROM hr.menus WHERE deleted_at IS NULL) AS menus,
    (SELECT COUNT(*) FROM hr.level_permissions WHERE deleted_at IS NULL) AS level_permissions,
    (SELECT COUNT(*) FROM hr.users WHERE deleted_at IS NULL) AS users_active,
    (SELECT COUNT(*) FROM hr.users) AS users_total,
    CASE WHEN OBJECT_ID('hr.enums', 'U') IS NULL THEN 0
         ELSE (SELECT COUNT(*) FROM hr.enums) END AS enums_total,
    CASE WHEN OBJECT_ID('hr.structure', 'U') IS NULL THEN 0
         ELSE (SELECT COUNT(*) FROM hr.structure) END AS structure_total
`);

console.log('OK', summary.recordset[0]);
await sql.close();
process.exit(0);
