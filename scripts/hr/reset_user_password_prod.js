/**
 * Reset one hr.users password (bcrypt) on PROD_DB_* / or app DB_*.
 * Optional --also-dbo updates dbo.users (legacy CI on same Azure DB).
 *
 * Usage:
 *   node scripts/hr/reset_user_password_prod.js dev01
 *   node scripts/hr/reset_user_password_prod.js dev01 --also-dbo
 *   node scripts/hr/reset_user_password_prod.js dev01 secret --app
 *
 * Default password = username. Optional 2nd arg = plaintext password.
 * Requires CONFIRM_PROD_MIGRATE + allowlist unless --app (uses DB_*).
 */
import dotenv from 'dotenv';
import bcrypt from 'bcrypt';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';
import sql from 'mssql';

const __dirname = dirname(fileURLToPath(import.meta.url));
dotenv.config({ path: join(__dirname, '..', '..', '.env') });

const BCRYPT_ROUNDS = 10;
const raw = process.argv.slice(2);
const flags = new Set(raw.filter((a) => a.startsWith('--')));
const args = raw.filter((a) => !a.startsWith('--'));
const username = args[0];
const plaintext = args[1] || username;

if (!username) {
  console.error(
    'Usage: node scripts/hr/reset_user_password_prod.js <username> [password] [--also-dbo] [--app]',
  );
  process.exit(1);
}

let pool;
let closeExtra = async () => {};

if (flags.has('--app')) {
  const db = await import('../../config/database.js');
  pool = await db.getConnection();
  closeExtra = async () => {
    await db.sql.close().catch(() => {});
  };
  console.log('Using app DB_*');
} else {
  const prod = await import('../../config/prodDatabase.js');
  const opened = await prod.openProdDatabase();
  pool = opened.pool;
  closeExtra = async () => {
    await prod.prodSql.close().catch(() => {});
  };
}

const hashed = await bcrypt.hash(String(plaintext), BCRYPT_ROUNDS);

const upd = await pool
  .request()
  .input('username', sql.NVarChar, String(username))
  .input('password', sql.NVarChar, hashed)
  .query(`
    UPDATE hr.users
    SET password = @password,
        updated_at = SYSUTCDATETIME(),
        updated_by = NULL
    WHERE username = @username AND deleted_at IS NULL;

    SELECT @@ROWCOUNT AS n;
    SELECT id, username, LEFT(password, 7) AS pwd_prefix, level_id
    FROM hr.users WHERE username = @username AND deleted_at IS NULL;
  `);

const n = upd.recordsets[0][0].n;
if (!n) {
  console.error(`No active hr.users row for username="${username}"`);
  await pool.close();
  await closeExtra();
  process.exit(1);
}

console.log('✓ hr.users password updated', upd.recordsets[1][0]);

if (flags.has('--also-dbo')) {
  const dbo = await pool
    .request()
    .input('username', sql.NVarChar, String(username))
    .input('password', sql.NVarChar, hashed)
    .query(`
      UPDATE dbo.users
      SET password = @password, updated_at = SYSUTCDATETIME()
      WHERE username = @username AND deleted_at IS NULL;
      SELECT @@ROWCOUNT AS n;
    `);
  console.log('✓ dbo.users password updated rows=', dbo.recordset[0].n);
}

console.log('✓ bcrypt self-check', await bcrypt.compare(String(plaintext), hashed));

await pool.close();
await closeExtra();
process.exit(0);
