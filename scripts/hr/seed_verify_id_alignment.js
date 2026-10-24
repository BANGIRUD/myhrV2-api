/**
 * Verify dbo → hr id alignment for cutover tables (wave-1 + wave-2).
 *
 * Wave-1:
 *   hr.users (id = legacy_id)
 *   hr.workers_sickness / workers_permit / workers_finger_error (+ photos): hr.id = dbo.id, ref_id intact
 *
 * Wave-2:
 *   hr.workers / structure / enums (+ workers FK department/section/job_rank)
 *   hr.workers_cuti_period_master / workers_cuti_period (periode → master)
 *   hr.workers_cuti_kerja (windowed sync; dbo_missing outside window is OK)
 *   hr.workers_pola_kerja / workers_roster_kerja (windowed; dbo_missing outside OK)
 *
 * Default: local DB_* only. With `--prod`: PROD_DB_* + confirm gate
 * (config/prodDatabase.js). Exit 1 on failure.
 * Soft-warn (no fail) for known legacy orphans also present in dbo
 * (ref_id/department = 0, cuti periode pointing at deleted masters).
 *
 * Usage:
 *   node scripts/hr/seed_verify_id_alignment.js
 *   node scripts/hr/seed_verify_id_alignment.js --prod
 *   node scripts/hr/verify_id_alignment_prod.js   (alias for --prod + smoke)
 */
import dotenv from 'dotenv';
import sql from 'mssql';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
dotenv.config({ path: join(__dirname, '..', '..', '.env') });

const JOBSITE_ID = Number(process.env.DEFAULT_JOBSITE_ID || 1);
const useProd =
  process.argv.includes('--prod') || process.env.VERIFY_USE_PROD === '1';
const withSmoke =
  process.argv.includes('--smoke') ||
  process.env.VERIFY_SMOKE === '1' ||
  useProd;

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
  requestTimeout: 180000,
};

if (!useProd) {
  if (!localConfig.server || !localConfig.user || !localConfig.password) {
    throw new Error('Local DB_* env incomplete. Check .env');
  }
}

/** Tables where hr.id must equal dbo.id and legacy_id = id when set. */
const ID_TABLES = [
  { dbo: 'workers_sickness', hr: 'workers_sickness' },
  { dbo: 'workers_sickness_photos', hr: 'workers_sickness_photos' },
  { dbo: 'workers_permit', hr: 'workers_permit' },
  { dbo: 'workers_permit_photos', hr: 'workers_permit_photos' },
  { dbo: 'workers_finger_error', hr: 'workers_finger_error' },
  { dbo: 'workers_finger_error_photos', hr: 'workers_finger_error_photos' },
  { dbo: 'workers', hr: 'workers' },
  { dbo: 'structure', hr: 'structure' },
  { dbo: 'enums', hr: 'enums' },
  { dbo: 'workers_cuti_period_master', hr: 'workers_cuti_period_master' },
  { dbo: 'workers_cuti_period', hr: 'workers_cuti_period' },
  { dbo: 'workers_cuti_kerja', hr: 'workers_cuti_kerja' },
  { dbo: 'workers_pola_kerja', hr: 'workers_pola_kerja' },
  { dbo: 'workers_roster_kerja', hr: 'workers_roster_kerja' },
];

/** Parent/child graphs (child column → parent table). */
const REF_PAIRS = [
  {
    child: 'workers_sickness',
    parent: 'workers_sickness',
    column: 'ref_id',
    label: 'sickness child→parent',
  },
  {
    child: 'workers_sickness_photos',
    parent: 'workers_sickness',
    column: 'ref_id',
    label: 'sickness_photos→sickness',
  },
  {
    child: 'workers_permit',
    parent: 'workers_permit',
    column: 'ref_id',
    label: 'permit child→parent',
  },
  {
    child: 'workers_permit_photos',
    parent: 'workers_permit',
    column: 'ref_id',
    label: 'permit_photos→permit',
  },
  {
    child: 'workers_finger_error',
    parent: 'workers_finger_error',
    column: 'ref_id',
    label: 'finger_error child→parent',
  },
  {
    child: 'workers_finger_error_photos',
    parent: 'workers_finger_error',
    column: 'ref_id',
    label: 'finger_error_photos→finger_error',
  },
  {
    child: 'structure',
    parent: 'structure',
    column: 'ref_id',
    label: 'structure child→parent',
    ignoreZero: true,
  },
  {
    child: 'enums',
    parent: 'enums',
    column: 'ref_id',
    label: 'enums child→parent',
    ignoreZero: true,
  },
  {
    child: 'workers_cuti_period',
    parent: 'workers_cuti_period_master',
    column: 'periode',
    label: 'cuti_period.periode→master',
    ignoreZero: true,
    legacyDboOk: true,
  },
];

async function tableExists(pool, schema, name) {
  const r = await pool
    .request()
    .input('schema', sql.NVarChar(128), schema)
    .input('name', sql.NVarChar(128), name)
    .query(`
      SELECT 1 AS ok
      FROM sys.tables t
      INNER JOIN sys.schemas s ON s.schema_id = t.schema_id
      WHERE s.name = @schema AND t.name = @name
    `);
  return r.recordset.length > 0;
}

async function viewExists(pool, schema, name) {
  const r = await pool
    .request()
    .input('schema', sql.NVarChar(128), schema)
    .input('name', sql.NVarChar(128), name)
    .query(`
      SELECT 1 AS ok
      FROM sys.views v
      INNER JOIN sys.schemas s ON s.schema_id = v.schema_id
      WHERE s.name = @schema AND v.name = @name
    `);
  return r.recordset.length > 0;
}

async function columnExists(pool, schema, table, column) {
  const r = await pool
    .request()
    .input('schema', sql.NVarChar(128), schema)
    .input('table', sql.NVarChar(128), table)
    .input('column', sql.NVarChar(128), column)
    .query(`
      SELECT 1 AS ok
      FROM sys.columns c
      INNER JOIN sys.tables t ON t.object_id = c.object_id
      INNER JOIN sys.schemas s ON s.schema_id = t.schema_id
      WHERE s.name = @schema AND t.name = @table AND c.name = @column
    `);
  return r.recordset.length > 0;
}

/**
 * Fail only on id/legacy drift. dbo_missing (windowed sync) and hr_only
 * (app-created) are reported but do not fail.
 */
async function checkIdTable(pool, t) {
  const dboOk = await tableExists(pool, 'dbo', t.dbo);
  const hrOk = await tableExists(pool, 'hr', t.hr);
  if (!dboOk || !hrOk) {
    console.log(`· skip ${t.hr} (dbo=${dboOk}, hr=${hrOk})`);
    return 0;
  }

  const hasLegacy = await columnExists(pool, 'hr', t.hr, 'legacy_id');
  const hasDeleted = await columnExists(pool, 'hr', t.hr, 'deleted_at');
  const activeHr = hasDeleted ? 'h.deleted_at IS NULL' : '1=1';

  const r = await pool.request().query(`
    SELECT COUNT(*) AS hr_only
    FROM hr.${t.hr} h
    WHERE ${activeHr}
      AND NOT EXISTS (SELECT 1 FROM dbo.${t.dbo} d WHERE d.id = h.id);

    SELECT COUNT(*) AS id_mismatch
    FROM hr.${t.hr} h
    INNER JOIN dbo.${t.dbo} d ON d.id = h.id
    WHERE ${hasLegacy ? 'h.legacy_id IS NOT NULL AND h.legacy_id <> h.id' : '1=0'};

    SELECT COUNT(*) AS dbo_missing_in_hr
    FROM dbo.${t.dbo} d
    WHERE NOT EXISTS (SELECT 1 FROM hr.${t.hr} h WHERE h.id = d.id);

    SELECT COUNT(*) AS matched_ids
    FROM hr.${t.hr} h
    INNER JOIN dbo.${t.dbo} d ON d.id = h.id;
  `);

  const hrOnly = r.recordsets[0][0].hr_only;
  const idMismatch = r.recordsets[1][0].id_mismatch;
  const dboMissing = r.recordsets[2][0].dbo_missing_in_hr;
  const matched = r.recordsets[3][0].matched_ids;

  if (idMismatch > 0) {
    console.error(`✗ hr.${t.hr}: ${idMismatch} row(s) with legacy_id ≠ id`);
    return 1;
  }
  console.log(
    `✓ hr.${t.hr}: id/legacy aligned (matched=${matched}, dbo_missing_in_hr=${dboMissing}, hr_only_active=${hrOnly})`,
  );
  return 0;
}

async function checkRefPair(pool, pair) {
  if (!(await tableExists(pool, 'hr', pair.child))) return 0;
  if (!(await tableExists(pool, 'hr', pair.parent))) return 0;
  if (!(await columnExists(pool, 'hr', pair.child, pair.column))) {
    console.log(`· skip ${pair.label} (no ${pair.column})`);
    return 0;
  }

  const zeroFilter = pair.ignoreZero
    ? `AND TRY_CAST(c.${pair.column} AS BIGINT) IS NOT NULL AND TRY_CAST(c.${pair.column} AS BIGINT) <> 0`
    : `AND c.${pair.column} IS NOT NULL`;

  const r = await pool.request().query(`
    SELECT COUNT(*) AS broken
    FROM hr.${pair.child} c
    WHERE c.deleted_at IS NULL
      ${zeroFilter}
      AND NOT EXISTS (
        SELECT 1 FROM hr.${pair.parent} p WHERE p.id = TRY_CAST(c.${pair.column} AS BIGINT)
      );
  `);
  const broken = r.recordset[0].broken;

  if (broken === 0) {
    console.log(`✓ ${pair.label}: ${pair.column} OK`);
    return 0;
  }

  // Legacy junk also in dbo → warn only
  if (pair.legacyDboOk && (await tableExists(pool, 'dbo', pair.child))) {
    const dboParent = (await tableExists(pool, 'dbo', pair.parent))
      ? pair.parent
      : null;
    if (dboParent) {
      const dboOrphan = await pool.request().query(`
        SELECT COUNT(*) AS n
        FROM dbo.${pair.child} c
        WHERE c.${pair.column} IS NOT NULL
          ${pair.ignoreZero ? `AND TRY_CAST(c.${pair.column} AS BIGINT) <> 0` : ''}
          AND NOT EXISTS (
            SELECT 1 FROM dbo.${dboParent} p
            WHERE p.id = TRY_CAST(c.${pair.column} AS BIGINT)
          );
      `);
      const alsoInHrButNotDbo = await pool.request().query(`
        SELECT COUNT(*) AS n
        FROM hr.${pair.child} c
        WHERE c.deleted_at IS NULL
          ${zeroFilter}
          AND NOT EXISTS (
            SELECT 1 FROM hr.${pair.parent} p
            WHERE p.id = TRY_CAST(c.${pair.column} AS BIGINT)
          )
          AND EXISTS (
            SELECT 1 FROM dbo.${dboParent} p
            WHERE p.id = TRY_CAST(c.${pair.column} AS BIGINT)
          );
      `);
      if (alsoInHrButNotDbo.recordset[0].n === 0) {
        console.warn(
          `⚠ ${pair.label}: ${broken} orphan(s) (legacy dbo also has ${dboOrphan.recordset[0].n}) — not a sync drift`,
        );
        return 0;
      }
    }
  }

  console.warn(`⚠ ${pair.label}: ${broken} active child(ren) with missing parent id`);
  return 0;
}

async function checkWorkersFks(pool) {
  if (!(await tableExists(pool, 'hr', 'workers'))) return 0;
  if (!(await tableExists(pool, 'hr', 'structure'))) return 0;
  if (!(await tableExists(pool, 'hr', 'enums'))) return 0;

  const r = await pool.request().query(`
    SELECT
      (SELECT COUNT(*) FROM hr.workers w
        WHERE w.deleted_at IS NULL AND w.department IS NOT NULL AND w.department <> 0
          AND NOT EXISTS (SELECT 1 FROM hr.structure s WHERE s.id = w.department)) AS bad_dept,
      (SELECT COUNT(*) FROM hr.workers w
        WHERE w.deleted_at IS NULL AND w.section IS NOT NULL AND w.section <> 0
          AND NOT EXISTS (SELECT 1 FROM hr.structure s WHERE s.id = w.section)) AS bad_section,
      (SELECT COUNT(*) FROM hr.workers w
        WHERE w.deleted_at IS NULL AND w.job_rank IS NOT NULL AND w.job_rank <> 0
          AND NOT EXISTS (SELECT 1 FROM hr.enums e WHERE e.id = w.job_rank)) AS bad_job_rank,
      (SELECT COUNT(*) FROM hr.workers w
        WHERE w.deleted_at IS NULL AND w.department = 0) AS sentinel_dept_zero;
  `);
  const row = r.recordset[0];
  let failed = 0;

  if (row.bad_dept > 0 || row.bad_section > 0 || row.bad_job_rank > 0) {
    // Compare to dbo — fail only if hr is worse (sync drift)
    if (await tableExists(pool, 'dbo', 'workers')) {
      const dbo = await pool.request().query(`
        SELECT
          (SELECT COUNT(*) FROM dbo.workers w
            WHERE w.deleted_at IS NULL AND w.department IS NOT NULL AND w.department <> 0
              AND NOT EXISTS (SELECT 1 FROM dbo.structure s WHERE s.id = w.department)) AS bad_dept,
          (SELECT COUNT(*) FROM dbo.workers w
            WHERE w.deleted_at IS NULL AND w.section IS NOT NULL AND w.section <> 0
              AND NOT EXISTS (SELECT 1 FROM dbo.structure s WHERE s.id = w.section)) AS bad_section,
          (SELECT COUNT(*) FROM dbo.workers w
            WHERE w.deleted_at IS NULL AND w.job_rank IS NOT NULL AND w.job_rank <> 0
              AND NOT EXISTS (SELECT 1 FROM dbo.enums e WHERE e.id = w.job_rank)) AS bad_job_rank;
      `);
      const d = dbo.recordset[0];
      if (
        row.bad_dept > d.bad_dept ||
        row.bad_section > d.bad_section ||
        row.bad_job_rank > d.bad_job_rank
      ) {
        failed = 1;
        console.error(
          `✗ workers FK worse than dbo: hr dept/section/job_rank=${row.bad_dept}/${row.bad_section}/${row.bad_job_rank} dbo=${d.bad_dept}/${d.bad_section}/${d.bad_job_rank}`,
        );
      } else {
        console.warn(
          `⚠ workers FK orphans match dbo (dept/section/job_rank=${row.bad_dept}/${row.bad_section}/${row.bad_job_rank}; sentinel department=0: ${row.sentinel_dept_zero})`,
        );
      }
    } else {
      console.warn(
        `⚠ workers FK orphans: dept/section/job_rank=${row.bad_dept}/${row.bad_section}/${row.bad_job_rank}`,
      );
    }
  } else {
    console.log(
      `✓ workers FK department/section/job_rank OK (sentinel department=0: ${row.sentinel_dept_zero})`,
    );
  }
  return failed;
}

async function checkCutiPeriodeParity(pool) {
  if (!(await tableExists(pool, 'dbo', 'workers_cuti_period'))) return 0;
  if (!(await tableExists(pool, 'hr', 'workers_cuti_period'))) return 0;

  const r = await pool.request().query(`
    SELECT COUNT(*) AS n
    FROM dbo.workers_cuti_period d
    INNER JOIN hr.workers_cuti_period h ON h.id = d.id
    WHERE ISNULL(d.periode, -1) <> ISNULL(h.periode, -1);
  `);
  const n = r.recordset[0].n;
  if (n > 0) {
    console.error(`✗ workers_cuti_period: ${n} overlapping id(s) with periode dbo≠hr`);
    return 1;
  }
  console.log('✓ workers_cuti_period.periode matches dbo on overlapping ids');
  return 0;
}

/**
 * Smoke: login view + sickness list join via hr.users.legacy_id (by_user).
 * Fail only when objects exist but return hard errors / zero login rows.
 */
async function smokeProdRuntime(pool) {
  let failed = 0;

  if (await viewExists(pool, 'hr', 'v_user_login')) {
    const login = await pool.request().query(`
      SELECT COUNT(*) AS n FROM hr.v_user_login;
      SELECT TOP (3) id, username, level_code, legacy_id
      FROM hr.v_user_login
      ORDER BY id;
    `);
    const n = login.recordsets[0][0].n;
    if (n === 0) {
      failed += 1;
      console.error('✗ smoke: hr.v_user_login has 0 rows');
    } else {
      console.log(`✓ smoke: hr.v_user_login rows=${n}`, login.recordsets[1]);
    }
  } else {
    failed += 1;
    console.error('✗ smoke: hr.v_user_login view missing');
  }

  if (
    (await tableExists(pool, 'hr', 'workers_sickness')) &&
    (await tableExists(pool, 'hr', 'users'))
  ) {
    const join = await pool.request().query(`
      SELECT TOP (5)
        m.id,
        m.by_user,
        u.id AS user_id,
        u.username,
        u.legacy_id
      FROM hr.workers_sickness m
      LEFT JOIN hr.users u
        ON u.legacy_id = TRY_CAST(m.by_user AS INT)
       AND u.deleted_at IS NULL
      WHERE m.deleted_at IS NULL
        AND m.by_user IS NOT NULL
      ORDER BY m.id DESC;
    `);
    const resolved = join.recordset.filter((r) => r.user_id != null).length;
    console.log(
      `✓ smoke: sickness by_user→users.legacy_id sample (${resolved}/${join.recordset.length} resolved)`,
      join.recordset,
    );
  } else {
    console.log('· smoke: skip sickness legacy_id join (tables missing)');
  }

  return failed;
}

async function main() {
  let pool;
  let closeExtra = async () => {};

  if (useProd) {
    const { openProdDatabase, prodSql } = await import(
      '../../config/prodDatabase.js'
    );
    const opened = await openProdDatabase();
    pool = opened.pool;
    console.log(
      `Verify id alignment (PROD): ${opened.meta.server}/${opened.meta.database} jobsite=${JOBSITE_ID}`,
    );
    closeExtra = async () => {
      await prodSql.close().catch(() => {});
    };
  } else {
    console.log(
      `Verify id alignment: ${localConfig.server}/${localConfig.database} jobsite=${JOBSITE_ID}`,
    );
    pool = new sql.ConnectionPool(localConfig);
    await pool.connect();
  }

  let failed = 0;

  try {
    const users = await pool
      .request()
      .input('by_jobsite', sql.Int, JOBSITE_ID)
      .query(`
        SELECT COUNT(*) AS mismatch
        FROM hr.users
        WHERE by_jobsite = @by_jobsite
          AND legacy_id IS NOT NULL
          AND id <> legacy_id;

        SELECT TOP (5) id, legacy_id, username
        FROM hr.users
        WHERE by_jobsite = @by_jobsite
          AND legacy_id IS NOT NULL
          AND id <> legacy_id
        ORDER BY id;
      `);
    const mismatchUsers = users.recordsets[0][0].mismatch;
    if (mismatchUsers > 0) {
      failed += 1;
      console.error(`✗ hr.users id≠legacy_id: ${mismatchUsers}`, users.recordsets[1]);
    } else {
      console.log('✓ hr.users id = legacy_id');
    }

    for (const t of ID_TABLES) {
      failed += await checkIdTable(pool, t);
    }

    for (const pair of REF_PAIRS) {
      failed += await checkRefPair(pool, pair);
    }

    failed += await checkWorkersFks(pool);
    failed += await checkCutiPeriodeParity(pool);

    // Sample: overlapping dbo/hr ids for sickness + cuti
    if (
      (await tableExists(pool, 'dbo', 'workers_sickness')) &&
      (await tableExists(pool, 'hr', 'workers_sickness'))
    ) {
      const sample = await pool.request().query(`
        SELECT TOP (3)
          d.id AS dbo_id,
          h.id AS hr_id,
          d.ref_id AS dbo_ref,
          h.ref_id AS hr_ref,
          h.legacy_id
        FROM dbo.workers_sickness d
        INNER JOIN hr.workers_sickness h ON h.id = d.id
        ORDER BY d.id DESC
      `);
      console.log('sample workers_sickness dbo↔hr:', sample.recordset);
    }

    if (
      (await tableExists(pool, 'dbo', 'workers_cuti_period')) &&
      (await tableExists(pool, 'hr', 'workers_cuti_period'))
    ) {
      const sample = await pool.request().query(`
        SELECT TOP (3)
          d.id AS dbo_id,
          h.id AS hr_id,
          d.periode AS dbo_periode,
          h.periode AS hr_periode,
          h.legacy_id
        FROM dbo.workers_cuti_period d
        INNER JOIN hr.workers_cuti_period h ON h.id = d.id
        ORDER BY d.id DESC
      `);
      console.log('sample workers_cuti_period dbo↔hr:', sample.recordset);
    }

    if (withSmoke) {
      console.log('\n-- smoke --');
      failed += await smokeProdRuntime(pool);
    }

    if (failed) {
      throw new Error(`id alignment failed (${failed} check(s))`);
    }
    console.log('OK all wave-1 + wave-2 id checks passed');
  } finally {
    await pool.close();
    await closeExtra();
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
