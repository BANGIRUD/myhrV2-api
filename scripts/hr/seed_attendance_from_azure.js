/**
 * Sync attendance-domain tables from Azure dbo.* → local dbo.*, then refresh the
 * matching hr.* tables with their *_sync_*_from_dbo.sql script.
 *
 * Chain: Azure (READ-ONLY) → local dbo (legacy copy, keeps the bridge SPs current)
 *        → local hr (new schema used by hr.DASHBOARD_SP).
 *
 * - Upsert by id (IDENTITY_INSERT); only rows that actually differ are updated.
 * - Local-only rows inside the synced window are soft-deleted, never hard-deleted.
 * - Azure access is READ-ONLY (config/azureReadonly.js). Writes go to local DB_* only.
 * - Local DB is SQL Server Express (10 GB cap): big tables use a date window.
 *
 * Usage:
 *   node scripts/hr/seed_attendance_from_azure.js                 (all configured tables)
 *   node scripts/hr/seed_attendance_from_azure.js workers_standby (selected tables)
 */
import dotenv from 'dotenv';
import sql from 'mssql';
import { readFileSync } from 'fs';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';
import {
  openAzureReadonly,
  azureSelect,
  getAzureReadonlyConfig,
} from '../../config/azureReadonly.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
dotenv.config({ path: join(__dirname, '..', '..', '.env') });

const BATCH_SIZE = 500;

/**
 * name      : table in dbo (both sides)
 * where     : optional SQL filter applied on Azure AND when soft-deleting local-only rows
 * hrSync    : hr sync scripts to run after the dbo copy
 */
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

const TABLES = {
  workers_standby: {
    where: () => null,
    hrSync: ['30_sync_workers_standby_from_dbo.sql'],
    batchSize: BATCH_SIZE,
  },
  // Rolling window: first day of month-2 .. today (inclusive).
  // Keep in sync with 34_sync_attendance_ratio_from_dbo.sql.
  achievement_attendance_ratio: {
    where: () => {
      const t = new Date();
      t.setDate(t.getDate() + 1);
      const tomorrow = `${t.getFullYear()}-${pad2(t.getMonth() + 1)}-${pad2(t.getDate())}`;
      return `[date] >= '${firstOfMonth(-2)}' AND [date] < '${tomorrow}'`;
    },
    hrSync: ['34_sync_attendance_ratio_from_dbo.sql'],
    batchSize: 2000,
  },
  // Rolling window: first day of month-2 .. first day of month+2 (exclusive).
  // Keep in sync with 32_sync_workers_roster_kerja_from_dbo.sql.
  workers_roster_kerja: {
    where: () => `[date] >= '${firstOfMonth(-2)}' AND [date] < '${firstOfMonth(2)}'`,
    hrSync: ['32_sync_workers_roster_kerja_from_dbo.sql'],
    batchSize: 2000,
  },

  // ---- Sources for the ATTENDANCE computation in hr.DASHBOARD_SP (35_attendance_sources.sql) ----
  // Config shape for these: `hrTable` = target in hr (same ids, generic sync, no per-table SQL file).
  // Windows start at first of month-2 (same lower bound as roster/attendance).
  workers_travel: {
    where: () => `end_date >= '${firstOfMonth(-2)}'`,
    hrTable: 'workers_travel',
  },
  workers_cuti_period_master: { where: () => null, hrTable: 'workers_cuti_period_master' },
  workers_cuti_period: { where: () => null, hrTable: 'workers_cuti_period' },
  workers_sickness: { where: () => null, hrTable: 'workers_sickness', batchSize: 1000 },
  workers_sickness_photos: {
    where: () => null,
    hrTable: 'workers_sickness_photos',
    batchSize: 1000,
  },
  workers_permit: {
    where: () => `end_date >= '${firstOfMonth(-2)}'`,
    hrTable: 'workers_permit',
  },
  workers_permit_photos: {
    where: () => `created_at >= '${firstOfMonth(-2)}'`,
    hrTable: 'workers_permit_photos',
  },
  workers_cuti_kerja: {
    where: () => `end_date >= '${firstOfMonth(-2)}'`,
    hrTable: 'workers_cuti_kerja',
  },
  workers_finger_error: {
    where: () => `[date] >= '${firstOfMonth(-2)}'`,
    hrTable: 'workers_finger_error',
  },
  workers_finger_error_photos: {
    where: () => `created_at >= '${firstOfMonth(-2)}'`,
    hrTable: 'workers_finger_error_photos',
  },
  date_holiday: { where: () => null, hrTable: 'date_holiday' },
  replication_workers_fingers_non_oams_new: {
    where: () => `ndatetime >= '${firstOfMonth(-2)}' AND ndatetime < '${tomorrowStr()}'`,
    hrTable: 'workers_finger_log',
    batchSize: 2000,
  },
  replication_workers_fingers_oams: {
    where: () => `tanggal >= '${firstOfMonth(-2)}' AND tanggal < '${tomorrowStr()}'`,
    hrTable: 'workers_finger_oams',
    batchSize: 2000,
  },
};

/** text/ntext/image cannot be compared with EXCEPT. */
const NON_COMPARABLE_TYPES = new Set(['text', 'ntext', 'image', 'xml']);

const localConfig = {
  user: process.env.DB_USER,
  password: process.env.DB_PASSWORD,
  server: process.env.DB_SERVER,
  port: Number(process.env.DB_PORT || 1433),
  database: process.env.DB_NAME,
  options: { encrypt: true, trustServerCertificate: true, enableArithAbort: true },
  connectionTimeout: 45000,
  requestTimeout: 900000,
};

if (!localConfig.server || !localConfig.user || !localConfig.password) {
  throw new Error('Local DB_* env incomplete. Check .env');
}

const q = (name) => `[${String(name).replace(/]/g, ']]')}]`;

const COLUMNS_SQL = (table) => `
  SELECT c.name, t.name AS type, c.max_length, c.precision, c.scale, c.is_identity
  FROM sys.columns c
  JOIN sys.types t ON t.user_type_id = c.user_type_id
  WHERE c.object_id = OBJECT_ID('dbo.${table}')
  ORDER BY c.column_id
`;

function typeSpec(col) {
  const t = col.type.toLowerCase();
  switch (t) {
    case 'varchar':
    case 'char':
    case 'varbinary':
    case 'binary':
      return `${t}(${col.max_length === -1 ? 'MAX' : col.max_length})`;
    case 'nvarchar':
    case 'nchar':
      return `${t}(${col.max_length === -1 ? 'MAX' : col.max_length / 2})`;
    case 'decimal':
    case 'numeric':
      return `${t}(${col.precision},${col.scale})`;
    case 'datetime2':
    case 'datetimeoffset':
    case 'time':
      return `${t}(${col.scale})`;
    case 'text':
      return 'varchar(MAX)';
    case 'ntext':
      return 'nvarchar(MAX)';
    case 'image':
      return 'varbinary(MAX)';
    default:
      return t;
  }
}

function toJsonValue(value, type) {
  if (value === null || value === undefined) return null;
  if (value instanceof Date) {
    const iso = value.toISOString();
    switch (type) {
      case 'date':
        return iso.slice(0, 10);
      case 'time':
        return iso.slice(11, 23);
      case 'datetimeoffset':
        return iso;
      default:
        return iso.slice(0, 23);
    }
  }
  if (Buffer.isBuffer(value)) return value.toString('base64');
  return value;
}

async function syncTable(localPool, azurePool, table, config) {
  const where = config.where();
  const batchSize = config.batchSize || BATCH_SIZE;
  console.log(`\n== dbo.${table}${where ? `  (window: ${where})` : ''}`);
  const azureCols = (await azureSelect(azurePool, COLUMNS_SQL(table))).recordset;
  if (!azureCols.length) throw new Error(`Azure dbo.${table} missing.`);

  const localCols = (await localPool.request().query(COLUMNS_SQL(table))).recordset;
  if (!localCols.length) throw new Error(`Local dbo.${table} missing.`);

  const azureNames = new Set(azureCols.map((c) => c.name.toLowerCase()));
  const cols = localCols.filter((c) => azureNames.has(c.name.toLowerCase()));
  if (!cols.some((c) => c.name === 'id')) throw new Error(`dbo.${table} has no id column.`);

  const rows = (
    await azureSelect(
      azurePool,
      `SELECT ${cols.map((c) => q(c.name)).join(', ')} FROM dbo.${table}${
        where ? ` WHERE ${where}` : ''
      } ORDER BY id`,
    )
  ).recordset;
  console.log(`  Azure rows: ${rows.length}`);

  const withClause = cols
    .map((c) => `${q(c.name)} ${typeSpec(c)} '$."${c.name}"'`)
    .join(',\n      ');
  const colList = cols.map((c) => q(c.name)).join(', ');
  const nonIdCols = cols.filter((c) => c.name !== 'id');
  const comparable = nonIdCols.filter((c) => !NON_COMPARABLE_TYPES.has(c.type.toLowerCase()));
  const hasIdentity = localCols.some((c) => c.is_identity);
  const hasDeletedAt = localCols.some((c) => c.name === 'deleted_at');
  const hasUpdatedAt = localCols.some((c) => c.name === 'updated_at');

  const tx = new sql.Transaction(localPool);
  await tx.begin();
  try {
    // batch(), not query(): query() wraps in sp_executesql, which drops #stg on return.
    await new sql.Request(tx).batch(`
      IF OBJECT_ID('tempdb..#stg') IS NOT NULL DROP TABLE #stg;
      CREATE TABLE #stg (
        ${cols
          .map((c) => {
            const collate = /char|text/i.test(c.type) ? ' COLLATE DATABASE_DEFAULT' : '';
            return `${q(c.name)} ${typeSpec(c)}${collate} NULL`;
          })
          .join(',\n        ')}
      );
    `);

    for (let i = 0; i < rows.length; i += batchSize) {
      const chunk = rows.slice(i, i + batchSize).map((row) => {
        const out = {};
        for (const c of cols) out[c.name] = toJsonValue(row[c.name], c.type.toLowerCase());
        return out;
      });
      await new sql.Request(tx)
        .input('j', sql.NVarChar(sql.MAX), JSON.stringify(chunk))
        .query(`
          INSERT INTO #stg (${colList})
          SELECT ${colList}
          FROM OPENJSON(@j) WITH (
            ${withClause}
          );
        `);
    }

    const result = await new sql.Request(tx).query(`
      DECLARE @upd INT, @ins INT, @del INT = 0;

      UPDATE d SET
        ${nonIdCols.map((c) => `${q(c.name)} = s.${q(c.name)}`).join(',\n        ')}
      FROM dbo.${q(table)} d
      INNER JOIN #stg s ON s.id = d.id
      WHERE EXISTS (
        SELECT ${comparable.map((c) => `s.${q(c.name)}`).join(', ')}
        EXCEPT
        SELECT ${comparable.map((c) => `d.${q(c.name)}`).join(', ')}
      );
      SET @upd = @@ROWCOUNT;

      ${hasIdentity ? `SET IDENTITY_INSERT dbo.${q(table)} ON;` : ''}
      INSERT INTO dbo.${q(table)} (${colList})
      SELECT ${cols.map((c) => `s.${q(c.name)}`).join(', ')}
      FROM #stg s
      WHERE NOT EXISTS (SELECT 1 FROM dbo.${q(table)} d WHERE d.id = s.id);
      SET @ins = @@ROWCOUNT;
      ${hasIdentity ? `SET IDENTITY_INSERT dbo.${q(table)} OFF;` : ''}

      ${
        hasDeletedAt
          ? `UPDATE d SET
        deleted_at = GETDATE()${hasUpdatedAt ? ',\n        updated_at = GETDATE()' : ''}
      FROM dbo.${q(table)} d
      WHERE d.deleted_at IS NULL${where ? ` AND (${where})` : ''}
        AND NOT EXISTS (SELECT 1 FROM #stg s WHERE s.id = d.id);
      SET @del = @@ROWCOUNT;`
          : ''
      }

      DROP TABLE #stg;
      SELECT @upd AS updated, @ins AS inserted, @del AS soft_deleted_local_only;
    `);

    await tx.commit();
    console.log(`  ✓ local dbo.${table}:`, result.recordset[0]);
  } catch (err) {
    await tx.rollback();
    throw err;
  }
}

function splitBatches(sqlText) {
  return sqlText
    .split(/^\s*GO\s*$/gim)
    .map((batch) => batch.trim())
    .filter(Boolean);
}

async function runHrSync(localPool, files) {
  for (const file of files) {
    const text = readFileSync(join(__dirname, file), 'utf8');
    for (const batch of splitBatches(text)) {
      const req = localPool.request();
      req.on('info', (info) => console.log(`  ${info.message}`));
      await req.query(batch);
    }
    console.log(`✓ applied ${file}`);
  }
}

const HR_META_COLS = new Set(['id', 'by_jobsite', 'created_by', 'updated_by', 'deleted_by', 'legacy_id']);

/**
 * Generic dbo.<table> → hr.<hrTable> sync (same ids, IDENTITY_INSERT, legacy_id = id).
 * Copies every column that exists on both sides (except audit/meta). Windowed like the dbo copy.
 */
async function syncHrTable(localPool, table, hrTable, where) {
  const colsSql = (schema, name) => `
    SELECT c.name, t.name AS type FROM sys.columns c JOIN sys.types t ON t.user_type_id = c.user_type_id
    WHERE c.object_id = OBJECT_ID('${schema}.${name}') ORDER BY c.column_id`;
  const dboCols = (await localPool.request().query(colsSql('dbo', table))).recordset;
  const hrCols = (await localPool.request().query(colsSql('hr', hrTable))).recordset;
  if (!hrCols.length) throw new Error(`hr.${hrTable} missing. Apply 35_attendance_sources.sql first.`);
  const hrNames = new Set(hrCols.map((c) => c.name.toLowerCase()));
  const data = dboCols.filter(
    (c) => hrNames.has(c.name.toLowerCase()) && !HR_META_COLS.has(c.name.toLowerCase()),
  );
  const comparable = data.filter((c) => !NON_COMPARABLE_TYPES.has(c.type.toLowerCase()));
  const hasDeleted = data.some((c) => c.name === 'deleted_at');
  const winSrc = `(SELECT * FROM dbo.${q(table)}${where ? ` WHERE ${where}` : ''})`;
  const T = `hr.${q(hrTable)}`;

  console.log(`  → hr.${hrTable}`);
  const res = await localPool.request().query(`
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
    INSERT INTO ${T} (id, by_jobsite, legacy_id, ${data.map((c) => q(c.name)).join(', ')})
    SELECT s.id, 1, s.id, ${data.map((c) => `s.${q(c.name)}`).join(', ')}
    FROM ${winSrc} s
    WHERE NOT EXISTS (SELECT 1 FROM ${T} d WHERE d.id = s.id);
    SET @ins = @@ROWCOUNT;
    SET IDENTITY_INSERT ${T} OFF;

    ${
      hasDeleted
        ? `-- soft-delete hr rows (inside the window) that vanished from dbo; skipped when dbo window is empty
    IF EXISTS (SELECT 1 FROM ${winSrc} w)
    BEGIN
      UPDATE d SET d.deleted_at = SYSUTCDATETIME()
      FROM ${T} d
      WHERE d.deleted_at IS NULL${where ? ` AND d.id IN (SELECT id FROM ${T} WHERE ${where})` : ''}
        AND NOT EXISTS (SELECT 1 FROM dbo.${q(table)} s WHERE s.id = d.id);
      SET @del = @@ROWCOUNT;
    END`
        : ''
    }
    SELECT @upd AS updated, @ins AS inserted, @del AS soft_deleted;
  `);
  console.log(`  ✓ hr.${hrTable}:`, res.recordset[0]);
}

const requested = process.argv.slice(2);
const names = requested.length ? requested : Object.keys(TABLES);
for (const name of names) {
  if (!TABLES[name]) {
    throw new Error(`Unknown table "${name}". Configured: ${Object.keys(TABLES).join(', ')}`);
  }
}

console.log(`Local WRITE target: ${localConfig.server}/${localConfig.database} (port ${localConfig.port})`);
const azureMeta = getAzureReadonlyConfig();
console.log(`Azure READ-ONLY source: ${azureMeta.server}/${azureMeta.database}`);

const localPool = new sql.ConnectionPool(localConfig);
await localPool.connect();
console.log('✓ local connected (writable)');
const azurePool = await openAzureReadonly();

try {
  for (const name of names) {
    await syncTable(localPool, azurePool, name, TABLES[name]);
    console.log(`\n== hr.* refresh (${name})`);
    if (TABLES[name].hrSync) await runHrSync(localPool, TABLES[name].hrSync);
    if (TABLES[name].hrTable) {
      await syncHrTable(localPool, name, TABLES[name].hrTable, TABLES[name].where());
    }
  }
  console.log('\nOK');
} finally {
  await azurePool.close();
  await localPool.close();
}

process.exit(0);
