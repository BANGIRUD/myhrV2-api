/**
 * Same-database sync: Azure dbo.* → hr.* (IDENTITY_INSERT, legacy_id = id).
 *
 * Unlike seed_attendance_from_azure.js (Azure SELECT → local WRITE), this runs
 * on one PROD connection: dbo is the id source of truth; hr receives mirrors.
 *
 * Safety: CONFIRM_PROD_MIGRATE=YES + PROD_DB_SERVER_ALLOWLIST
 * (config/prodDatabase.js). Does not touch azureReadonly / AZURE_DB_*.
 *
 * Usage:
 *   node scripts/hr/sync_dbo_to_hr_prod.js              (all groups)
 *   node scripts/hr/sync_dbo_to_hr_prod.js foundation    (users/enums/structure/workers)
 *   node scripts/hr/sync_dbo_to_hr_prod.js operational   (standby/roster/pola/attendance sources)
 *   node scripts/hr/sync_dbo_to_hr_prod.js workers_sickness workers_permit
 *
 * Windowed tables use the same month-2… bounds as local seed (see WINDOWS below).
 */
import { readFileSync } from 'fs';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';
import dotenv from 'dotenv';
import { openProdDatabase, prodSql } from '../../config/prodDatabase.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
dotenv.config({ path: join(__dirname, '..', '..', '.env') });

const BATCH_HINT = 1000;

const pad2 = (n) => String(n).padStart(2, '0');
const firstOfMonth = (offset) => {
  const d = new Date();
  const m = new Date(d.getFullYear(), d.getMonth() + offset, 1);
  return `${m.getFullYear()}-${pad2(m.getMonth() + 1)}-01`;
};
const tomorrowStr = () => {
  const t = new Date();
  t.setDate(t.getDate() + 1);
  return `${t.getFullYear()}-${pad2(t.getMonth() + 1)}-${pad2(t.getDate())}`;
};

/** SQL sync scripts that already implement UPDATE + IDENTITY_INSERT insert. */
const SQL_SYNC = {
  // 09 backfills level_id after new dbo users land (06 is insert-only).
  users: ['06_seed_from_dbo.sql', '09_users_level_id.sql'],
  enums_structure: ['18_seed_enums_structure_from_dbo.sql'],
  workers: ['20_sync_workers_from_dbo.sql'],
  workers_vendor: ['22_sync_workers_vendor_from_dbo.sql'],
  workers_standby: ['30_sync_workers_standby_from_dbo.sql'],
  workers_roster_kerja: ['32_sync_workers_roster_kerja_from_dbo.sql'],
  attendance_ratio: ['34_sync_attendance_ratio_from_dbo.sql'],
  workers_pola_kerja: ['38_sync_workers_pola_kerja_from_dbo.sql'],
};

/**
 * Generic dbo → hr table sync (hrTable may differ from dbo name).
 * where: optional SQL filter on dbo (and soft-delete window).
 */
const GENERIC = {
  workers_travel: {
    dbo: 'workers_travel',
    hr: 'workers_travel',
    where: () => `end_date >= '${firstOfMonth(-2)}'`,
  },
  workers_cuti_period_master: {
    dbo: 'workers_cuti_period_master',
    hr: 'workers_cuti_period_master',
    where: () => null,
  },
  workers_cuti_period: {
    dbo: 'workers_cuti_period',
    hr: 'workers_cuti_period',
    where: () => null,
  },
  workers_sickness: {
    dbo: 'workers_sickness',
    hr: 'workers_sickness',
    where: () => null,
  },
  workers_sickness_photos: {
    dbo: 'workers_sickness_photos',
    hr: 'workers_sickness_photos',
    where: () => null,
  },
  workers_permit: {
    dbo: 'workers_permit',
    hr: 'workers_permit',
    where: () => `end_date >= '${firstOfMonth(-2)}'`,
  },
  workers_permit_photos: {
    dbo: 'workers_permit_photos',
    hr: 'workers_permit_photos',
    where: () => `created_at >= '${firstOfMonth(-2)}'`,
  },
  workers_cuti_kerja: {
    dbo: 'workers_cuti_kerja',
    hr: 'workers_cuti_kerja',
    where: () => `end_date >= '${firstOfMonth(-2)}'`,
  },
  workers_finger_error: {
    dbo: 'workers_finger_error',
    hr: 'workers_finger_error',
    where: () => `[date] >= '${firstOfMonth(-2)}'`,
  },
  workers_finger_error_photos: {
    dbo: 'workers_finger_error_photos',
    hr: 'workers_finger_error_photos',
    where: () => `created_at >= '${firstOfMonth(-2)}'`,
  },
  date_holiday: {
    dbo: 'date_holiday',
    hr: 'date_holiday',
    where: () => null,
  },
  workers_finger_log: {
    dbo: 'replication_workers_fingers_non_oams_new',
    hr: 'workers_finger_log',
    where: () =>
      `ndatetime >= '${firstOfMonth(-2)}' AND ndatetime < '${tomorrowStr()}'`,
  },
  workers_finger_oams: {
    dbo: 'replication_workers_fingers_oams',
    hr: 'workers_finger_oams',
    where: () =>
      `tanggal >= '${firstOfMonth(-2)}' AND tanggal < '${tomorrowStr()}'`,
  },
};

const GROUPS = {
  foundation: [
    'users',
    'enums_structure',
    'workers',
    'workers_vendor',
  ],
  operational: [
    'workers_standby',
    'workers_roster_kerja',
    'attendance_ratio',
    'workers_pola_kerja',
    ...Object.keys(GENERIC),
  ],
  all: null, // filled below
};

GROUPS.all = [...GROUPS.foundation, ...GROUPS.operational];

const HR_META_COLS = new Set([
  'id',
  'by_jobsite',
  'created_by',
  'updated_by',
  'deleted_by',
  'legacy_id',
]);
const NON_COMPARABLE_TYPES = new Set([
  'text',
  'ntext',
  'image',
  'xml',
  'geometry',
  'geography',
]);

function q(name) {
  return `[${String(name).replace(/]/g, ']]')}]`;
}

function splitBatches(sqlText) {
  return sqlText
    .split(/^\s*GO\s*$/gim)
    .map((batch) => batch.trim())
    .filter(Boolean);
}

async function runSqlFiles(pool, files) {
  for (const file of files) {
    const text = readFileSync(join(__dirname, file), 'utf8');
    console.log(`→ SQL ${file}`);
    for (const batch of splitBatches(text)) {
      const req = pool.request();
      req.on('info', (info) => console.log(`  ${info.message}`));
      await req.query(batch);
    }
    console.log(`  ✓ ${file}`);
  }
}

async function syncHrTable(pool, dboTable, hrTable, where) {
  const colsSql = (schema, name) => `
    SELECT c.name, t.name AS type
    FROM sys.columns c
    JOIN sys.types t ON t.user_type_id = c.user_type_id
    WHERE c.object_id = OBJECT_ID(N'${schema}.${name}')
    ORDER BY c.column_id`;

  const dboCols = (await pool.request().query(colsSql('dbo', dboTable))).recordset;
  const hrCols = (await pool.request().query(colsSql('hr', hrTable))).recordset;

  if (!dboCols.length) {
    console.warn(`  ⚠ dbo.${dboTable} missing — skip hr.${hrTable}`);
    return;
  }
  if (!hrCols.length) {
    throw new Error(`hr.${hrTable} missing. Apply DDL scripts first (run_migrate_prod.js).`);
  }

  const hrNames = new Set(hrCols.map((c) => c.name.toLowerCase()));
  const hasLegacy = hrNames.has('legacy_id');
  const hasJobsite = hrNames.has('by_jobsite');
  const data = dboCols.filter(
    (c) => hrNames.has(c.name.toLowerCase()) && !HR_META_COLS.has(c.name.toLowerCase()),
  );
  if (!data.length) {
    throw new Error(`No overlapping data columns for dbo.${dboTable} → hr.${hrTable}`);
  }

  const comparable = data.filter((c) => !NON_COMPARABLE_TYPES.has(c.type.toLowerCase()));
  const hasDeleted = data.some((c) => c.name === 'deleted_at');
  const winSrc = `(SELECT * FROM dbo.${q(dboTable)}${where ? ` WHERE ${where}` : ''})`;
  const T = `hr.${q(hrTable)}`;

  const insertCols = [
    'id',
    ...(hasJobsite ? ['by_jobsite'] : []),
    ...(hasLegacy ? ['legacy_id'] : []),
    ...data.map((c) => c.name),
  ];
  const insertSelect = [
    's.id',
    ...(hasJobsite ? ['1'] : []),
    ...(hasLegacy ? ['s.id'] : []),
    ...data.map((c) => `s.${q(c.name)}`),
  ];

  console.log(`→ generic dbo.${dboTable} → hr.${hrTable}${where ? ` (window)` : ''}`);
  const res = await pool.request().query(`
    SET NOCOUNT ON;
    DECLARE @upd INT = 0, @ins INT = 0, @del INT = 0;

    UPDATE d SET ${data.map((c) => `d.${q(c.name)} = s.${q(c.name)}`).join(', ')}
    FROM ${T} d
    INNER JOIN ${winSrc} s ON s.id = d.id
    WHERE EXISTS (
      SELECT ${comparable.map((c) => `s.${q(c.name)}`).join(', ')}
      EXCEPT
      SELECT ${comparable.map((c) => `d.${q(c.name)}`).join(', ')}
    );
    SET @upd = @@ROWCOUNT;

    SET IDENTITY_INSERT ${T} ON;
    INSERT INTO ${T} (${insertCols.map(q).join(', ')})
    SELECT ${insertSelect.join(', ')}
    FROM ${winSrc} s
    WHERE NOT EXISTS (SELECT 1 FROM ${T} d WHERE d.id = s.id);
    SET @ins = @@ROWCOUNT;
    SET IDENTITY_INSERT ${T} OFF;

    ${
      hasDeleted
        ? `IF EXISTS (SELECT 1 FROM ${winSrc} w)
    BEGIN
      UPDATE d SET d.deleted_at = SYSUTCDATETIME()
      FROM ${T} d
      WHERE d.deleted_at IS NULL
        AND NOT EXISTS (SELECT 1 FROM dbo.${q(dboTable)} s WHERE s.id = d.id)
        ${where ? `AND d.id IN (SELECT id FROM ${T} x WHERE ${where})` : ''};
      SET @del = @@ROWCOUNT;
    END`
        : ''
    }

    SELECT @upd AS updated, @ins AS inserted, @del AS soft_deleted;
  `);
  console.log(`  ✓ hr.${hrTable}:`, res.recordset[0], `(batch hint ${BATCH_HINT})`);
}

async function runOne(pool, name) {
  if (SQL_SYNC[name]) {
    await runSqlFiles(pool, SQL_SYNC[name]);
    return;
  }
  if (GENERIC[name]) {
    const g = GENERIC[name];
    await syncHrTable(pool, g.dbo, g.hr, g.where());
    return;
  }
  throw new Error(
    `Unknown sync target "${name}". Known: ${[
      ...Object.keys(SQL_SYNC),
      ...Object.keys(GENERIC),
      ...Object.keys(GROUPS),
    ].join(', ')}`,
  );
}

const argv = process.argv.slice(2);
let targets;
if (argv.length === 0 || (argv.length === 1 && argv[0] === 'all')) {
  targets = GROUPS.all;
} else if (argv.length === 1 && GROUPS[argv[0]]) {
  targets = GROUPS[argv[0]];
} else {
  targets = argv;
}

const { pool, meta } = await openProdDatabase();
console.log(
  `Sync dbo → hr on ${meta.server}/${meta.database} (${targets.length} target(s))`,
);
console.log(
  `Windows: month-2 from ${firstOfMonth(-2)}; tomorrow=${tomorrowStr()}`,
);

try {
  for (const name of targets) {
    console.log(`\n== ${name}`);
    await runOne(pool, name);
  }
  console.log('\nOK sync_dbo_to_hr_prod');
} finally {
  await pool.close();
  await prodSql.close().catch(() => {});
}

process.exit(0);
