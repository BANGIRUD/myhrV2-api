/**
 * Soft-launch: set every active hr.users password = bcrypt(username).
 * Does NOT touch dbo.users (legacy CI keeps real passwords).
 *
 * Safety: CONFIRM_PROD_MIGRATE=YES + PROD_DB_SERVER_ALLOWLIST
 * Dry-run: add --dry-run (lists usernames, no UPDATE)
 *
 * Usage:
 *   node scripts/hr/reset_all_hr_passwords_to_username.js
 *   node scripts/hr/reset_all_hr_passwords_to_username.js --dry-run
 *   node scripts/hr/reset_all_hr_passwords_to_username.js --app   (DB_* instead of PROD_DB_*)
 */
import dotenv from 'dotenv';
import bcrypt from 'bcrypt';
import sql from 'mssql';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
dotenv.config({ path: join(__dirname, '..', '..', '.env') });

const BCRYPT_ROUNDS = 10;
const flags = new Set(process.argv.slice(2).filter((a) => a.startsWith('--')));
const dryRun = flags.has('--dry-run');

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

const list = await pool.request().query(`
  SELECT id, username
  FROM hr.users
  WHERE deleted_at IS NULL
    AND username IS NOT NULL
    AND LTRIM(RTRIM(username)) <> N''
  ORDER BY id;
`);

const rows = list.recordset;
console.log(
  `${dryRun ? 'DRY-RUN' : 'RESET'} hr.users passwords → bcrypt(username): ${rows.length} row(s)`,
);

let ok = 0;
let fail = 0;

for (const row of rows) {
  const username = String(row.username);
  try {
    if (dryRun) {
      if (ok < 5 || ok === rows.length - 1) {
        console.log(`  · would reset id=${row.id} username=${username}`);
      } else if (ok === 5) {
        console.log(`  · … (${rows.length - 6} more)`);
      }
      ok += 1;
      continue;
    }

    const hashed = await bcrypt.hash(username, BCRYPT_ROUNDS);
    await pool
      .request()
      .input('id', sql.Int, row.id)
      .input('password', sql.NVarChar, hashed)
      .query(`
        UPDATE hr.users
        SET password = @password,
            updated_at = SYSUTCDATETIME(),
            updated_by = NULL
        WHERE id = @id AND deleted_at IS NULL;
      `);
    ok += 1;
    if (ok % 50 === 0 || ok === rows.length) {
      console.log(`  … ${ok}/${rows.length}`);
    }
  } catch (err) {
    fail += 1;
    console.error(`  ✗ id=${row.id} username=${username}:`, err.message);
  }
}

console.log(`OK done updated=${ok} failed=${fail} dryRun=${dryRun}`);

// Spot-check a few after write
if (!dryRun && ok > 0) {
  const sample = await pool.request().query(`
    SELECT TOP (3) id, username, LEFT(password, 7) AS pwd_prefix
    FROM hr.users WHERE deleted_at IS NULL ORDER BY id;
  `);
  console.log('sample prefixes', sample.recordset);
  const first = rows[0];
  const got = await pool
    .request()
    .input('id', sql.Int, first.id)
    .query(`SELECT password FROM hr.users WHERE id = @id`);
  const match = await bcrypt.compare(
    String(first.username),
    got.recordset[0].password,
  );
  console.log(
    `verify first id=${first.id} username=${first.username} bcrypt(username)=${match}`,
  );
}

await pool.close();
await closeExtra();
process.exit(fail ? 1 : 0);
