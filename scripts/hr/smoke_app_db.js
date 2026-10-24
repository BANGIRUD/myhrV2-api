/**
 * Soft-launch smoke: app DB_* → hr.v_user_login (Azure after Fase D).
 * Usage: node scripts/hr/smoke_app_db.js
 */
import dotenv from 'dotenv';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';
import { getConnection, sql } from '../../config/database.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
dotenv.config({ path: join(__dirname, '..', '..', '.env') });

console.log('DB_SERVER=', process.env.DB_SERVER);
console.log('HR_SCHEMA=', process.env.HR_SCHEMA);
console.log('AUTH_DEV_BYPASS=', process.env.AUTH_DEV_BYPASS);
console.log('BYPASS_PASSWORD set=', Boolean(process.env.BYPASS_PASSWORD));

const pool = await getConnection();
const r = await pool.request().query(`
  SELECT COUNT(*) AS login_rows FROM hr.v_user_login;
  SELECT TOP (1) id, username, level_code FROM hr.v_user_login ORDER BY id;
  SELECT COUNT(*) AS sickness FROM hr.workers_sickness WHERE deleted_at IS NULL;
  SELECT
    SUM(CASE WHEN level_code IS NULL THEN 1 ELSE 0 END) AS no_level,
    SUM(CASE WHEN level_code IS NOT NULL THEN 1 ELSE 0 END) AS with_level
  FROM hr.v_user_login;
  SELECT TOP (5) id, username, level_id, level_code, legacy_level
  FROM hr.v_user_login
  ORDER BY id;
`);

console.log('OK smoke', {
  login_rows: r.recordsets[0][0].login_rows,
  sample: r.recordsets[1][0],
  sickness: r.recordsets[2][0].sickness,
  levels: r.recordsets[3][0],
  samples: r.recordsets[4],
});

await sql.close();
process.exit(0);
