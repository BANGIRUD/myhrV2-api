/**
 * One-shot local repair: make hr.users.id = legacy_id for dbo-sourced rows.
 *
 * Bulk strategy (fast on SQL Express):
 *  1. Build old_id → new_id map (legacy_id; park hr-only collisions to high ids)
 *  2. Remap all hr.* audit columns (created_by / updated_by / deleted_by) once
 *  3. Rebuild hr.users via temp table + IDENTITY_INSERT
 *
 * Does NOT touch Azure. Safe to re-run (no-op when already aligned).
 *
 * Usage: node scripts/hr/seed_realign_users_ids.js
 *        node scripts/hr/seed_realign_users_ids.js --dry-run
 */
import dotenv from 'dotenv';
import sql from 'mssql';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
dotenv.config({ path: join(__dirname, '..', '..', '.env') });

const JOBSITE_ID = Number(process.env.DEFAULT_JOBSITE_ID || 1);
const DRY_RUN = process.argv.includes('--dry-run');

/** Same catalog as 54_audit_by_user_id.sql (+ photos if present). */
const AUDIT_TABLES = [
  'jobsites',
  'menu_privilege',
  'users',
  'menus',
  'levels',
  'level_permissions',
  'enums',
  'structure',
  'workers',
  'workers_vendor',
  'workers_standby',
  'workers_roster_kerja',
  'attendance_ratio',
  'workers_pola_kerja',
  'workers_travel',
  'workers_cuti_period_master',
  'workers_cuti_period',
  'workers_sickness',
  'workers_sickness_photos',
  'workers_permit',
  'workers_permit_photos',
  'workers_cuti_kerja',
  'workers_finger_error',
  'date_holiday',
  'workers_finger_log',
  'workers_finger_oams',
  'roster_edit_policy',
  'edit_policy_modules',
  'edit_policy',
];

const localConfig = {
  user: process.env.DB_USER,
  password: process.env.DB_PASSWORD,
  server: process.env.DB_SERVER,
  port: Number(process.env.DB_PORT || 1433),
  database: process.env.DB_NAME,
  options: {
    encrypt: true,
    trustServerCertificate: true,
    enableArithAbort: true,
  },
  connectionTimeout: 45000,
  requestTimeout: 600000,
};

if (!localConfig.server || !localConfig.user || !localConfig.password) {
  throw new Error('Local DB_* env incomplete. Check .env');
}

function q(name) {
  return `[${String(name).replace(/]/g, ']]')}]`;
}

async function listAuditTargets(pool) {
  const targets = [];
  for (const table of AUDIT_TABLES) {
    const r = await pool.request().query(`
      SELECT c.name
      FROM sys.columns c
      WHERE c.object_id = OBJECT_ID('hr.${table.replace(/'/g, "''")}')
        AND c.name IN ('created_by', 'updated_by', 'deleted_by')
        AND TYPE_NAME(c.user_type_id) IN ('int', 'bigint', 'smallint', 'tinyint')
    `);
    for (const col of r.recordset) {
      targets.push({ table, column: col.name });
    }
  }
  return targets;
}

async function listUserColumns(pool) {
  const r = await pool.request().query(`
    SELECT c.name
    FROM sys.columns c
    WHERE c.object_id = OBJECT_ID('hr.users')
    ORDER BY c.column_id
  `);
  return r.recordset.map((row) => row.name);
}

/**
 * Build old_id → new_id.
 * dbo-sourced: new_id = legacy_id.
 * hr-only (legacy_id NULL) or already-aligned: keep id unless it collides with a target legacy_id.
 */
function buildIdMap(rows) {
  const byId = new Map(rows.map((r) => [r.id, r]));
  const targets = new Set(
    rows.filter((r) => r.legacy_id != null).map((r) => r.legacy_id),
  );

  let high = Math.max(0, ...rows.map((r) => r.id), ...targets) + 1;
  const map = new Map(); // old → new

  // First pass: dbo-sourced rows claim their legacy_id
  for (const r of rows) {
    if (r.legacy_id != null) {
      map.set(r.id, r.legacy_id);
    }
  }

  // Second pass: everyone else keeps id, or parks if target claimed
  for (const r of rows) {
    if (r.legacy_id != null) continue;
    if (targets.has(r.id)) {
      map.set(r.id, high);
      high += 1;
    } else {
      map.set(r.id, r.id);
    }
  }

  // Detect two dbo rows claiming the same legacy_id (unique index should prevent)
  const claimed = new Map();
  for (const [oldId, newId] of map) {
    const row = byId.get(oldId);
    if (row?.legacy_id == null) continue;
    if (claimed.has(newId) && claimed.get(newId) !== oldId) {
      throw new Error(
        `Duplicate legacy_id target ${newId}: users ${claimed.get(newId)} and ${oldId}`,
      );
    }
    claimed.set(newId, oldId);
  }

  return map;
}

async function main() {
  console.log(
    `Local WRITE target: ${localConfig.server}/${localConfig.database} (port ${localConfig.port}) jobsite=${JOBSITE_ID}${DRY_RUN ? ' [DRY-RUN]' : ''}`,
  );

  // Single pool/connection so #temp tables stay visible across requests
  const dedicated = new sql.ConnectionPool(localConfig);
  await dedicated.connect();

  try {
    const all = await dedicated
      .request()
      .input('by_jobsite', sql.Int, JOBSITE_ID)
      .query(`
        SELECT id, legacy_id, username
        FROM hr.users
        WHERE by_jobsite = @by_jobsite
        ORDER BY id
      `);

    const mismatches = all.recordset.filter(
      (r) => r.legacy_id != null && r.id !== r.legacy_id,
    );
    console.log(
      `Users jobsite ${JOBSITE_ID}: total=${all.recordset.length}, mismatches=${mismatches.length}`,
    );
    if (!mismatches.length) {
      console.log('✓ already aligned — nothing to do');
      return;
    }
    console.log('  sample mismatches:', mismatches.slice(0, 10));

    const idMap = buildIdMap(all.recordset);
    const changes = [...idMap.entries()].filter(([o, n]) => o !== n);
    console.log(`Id remaps required: ${changes.length}`);

    if (DRY_RUN) {
      console.log('  sample map:', changes.slice(0, 15));
      console.log('✓ [dry-run] map built; re-run without --dry-run to apply');
      return;
    }

    const columns = await listUserColumns(dedicated);
    const auditTargets = await listAuditTargets(dedicated);
    console.log(`Audit columns: ${auditTargets.length}`);

    // Permanent staging (pool may use multiple connections — #temp is unsafe)
    await dedicated.request().query(`
      IF OBJECT_ID('hr._tmp_user_id_map', 'U') IS NOT NULL DROP TABLE hr._tmp_user_id_map;
      IF OBJECT_ID('hr._tmp_users_rebuilt', 'U') IS NOT NULL DROP TABLE hr._tmp_users_rebuilt;
      CREATE TABLE hr._tmp_user_id_map (
        old_id INT NOT NULL PRIMARY KEY,
        new_id INT NOT NULL,
        CONSTRAINT UQ_tmp_user_id_map_new UNIQUE (new_id)
      );
    `);

    const CHUNK = 100;
    const fullEntries = [...idMap.entries()];
    for (let i = 0; i < fullEntries.length; i += CHUNK) {
      const slice = fullEntries.slice(i, i + CHUNK);
      const values = slice.map(([o, n]) => `(${o},${n})`).join(',');
      await dedicated.request().query(`
        INSERT INTO hr._tmp_user_id_map (old_id, new_id) VALUES ${values};
      `);
    }
    console.log(`✓ hr._tmp_user_id_map loaded (${fullEntries.length} rows)`);

    if (auditTargets.length && changes.length) {
      const stmts = auditTargets.map(
        ({ table, column }) => `
        UPDATE t
        SET t.${q(column)} = m.new_id
        FROM hr.${q(table)} t
        INNER JOIN hr._tmp_user_id_map m ON m.old_id = t.${q(column)}
        WHERE m.old_id <> m.new_id;`,
      );
      const r = await dedicated.request().query(stmts.join('\n'));
      const affected = Array.isArray(r.rowsAffected)
        ? r.rowsAffected.reduce((a, b) => a + b, 0)
        : 0;
      console.log(`✓ audit remapped (row-updates≈${affected})`);
    }

    const colList = columns.map(q).join(', ');
    const selectCols = columns
      .map((c) => (c === 'id' ? 'm.new_id AS id' : `u.${q(c)}`))
      .join(', ');

    await dedicated.request().query(`
      SELECT ${selectCols}
      INTO hr._tmp_users_rebuilt
      FROM hr.users u
      INNER JOIN hr._tmp_user_id_map m ON m.old_id = u.id
      WHERE u.by_jobsite = ${JOBSITE_ID};
    `);

    const rebuiltCount = await dedicated.request().query(`
      SELECT COUNT(*) AS n FROM hr._tmp_users_rebuilt
    `);
    const nRebuilt = rebuiltCount.recordset[0].n;
    console.log(`✓ hr._tmp_users_rebuilt: ${nRebuilt} rows`);
    if (nRebuilt !== fullEntries.length) {
      throw new Error(
        `Rebuild row count ${nRebuilt} != map size ${fullEntries.length} — abort before DELETE`,
      );
    }

    await dedicated.request().query(`
      DELETE FROM hr.users WHERE by_jobsite = ${JOBSITE_ID};

      SET IDENTITY_INSERT hr.users ON;
      INSERT INTO hr.users (${colList})
      SELECT ${colList} FROM hr._tmp_users_rebuilt;
      SET IDENTITY_INSERT hr.users OFF;

      DECLARE @max INT = (SELECT ISNULL(MAX(id), 0) FROM hr.users);
      DECLARE @sql NVARCHAR(200) =
        N'DBCC CHECKIDENT (''hr.users'', RESEED, ' + CAST(@max AS NVARCHAR(20)) + N')';
      EXEC sp_executesql @sql;

      DROP TABLE hr._tmp_users_rebuilt;
      DROP TABLE hr._tmp_user_id_map;
    `);
    console.log('✓ hr.users rebuilt with IDENTITY_INSERT');

    const left = await dedicated
      .request()
      .input('by_jobsite', sql.Int, JOBSITE_ID)
      .query(`
        SELECT COUNT(*) AS n
        FROM hr.users
        WHERE by_jobsite = @by_jobsite
          AND legacy_id IS NOT NULL
          AND id <> legacy_id
      `);

    if (left.recordset[0].n > 0) {
      throw new Error(
        `Still ${left.recordset[0].n} mismatch(es) after realign — inspect manually`,
      );
    }
    console.log('✓ hr.users id = legacy_id for all dbo-sourced rows');
  } finally {
    await dedicated.close();
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
