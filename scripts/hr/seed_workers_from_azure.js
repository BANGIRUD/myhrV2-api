/**
 * Sync Azure dbo.workers + dbo.workers_vendor_new → local dbo.*, then refresh
 * hr.workers / hr.workers_vendor via 20_sync_workers_from_dbo.sql +
 * 22_sync_workers_vendor_from_dbo.sql.
 *
 * - Columns present on Azure but missing locally are added (nullable) to local dbo.
 * - Upsert by id (IDENTITY_INSERT), only rows that actually differ are updated.
 * - Local-only rows are soft-deleted (deleted_at), never hard-deleted.
 * - dbo.insert_to_workers_history is disabled during the sync so the bulk
 *   copy does not flood local dbo.workers_history.
 *
 * Azure access is READ-ONLY (config/azureReadonly.js). All writes go to local DB_*.
 *
 * Usage: node scripts/hr/seed_workers_from_azure.js
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

const TABLES = [
  { name: 'workers', triggers: ['insert_to_workers_history'] },
  { name: 'workers_vendor_new', triggers: [] },
];

const HR_SYNC_FILES = [
  '20_sync_workers_from_dbo.sql',
  '22_sync_workers_vendor_from_dbo.sql',
];

/** text/ntext/image cannot be compared with EXCEPT. */
const NON_COMPARABLE_TYPES = new Set(['text', 'ntext', 'image', 'xml']);

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

async function ensureLocalColumns(localPool, table, azureCols) {
  const localCols = (await localPool.request().query(COLUMNS_SQL(table))).recordset;
  if (!localCols.length) {
    throw new Error(`Local dbo.${table} missing.`);
  }
  const localNames = new Set(localCols.map((c) => c.name.toLowerCase()));
  const missing = azureCols.filter((c) => !localNames.has(c.name.toLowerCase()));

  for (const col of missing) {
    await localPool
      .request()
      .query(`ALTER TABLE dbo.${q(table)} ADD ${q(col.name)} ${typeSpec(col)} NULL;`);
    console.log(`  + added local dbo.${table}.${col.name} ${typeSpec(col)}`);
  }

  return (await localPool.request().query(COLUMNS_SQL(table))).recordset;
}

async function syncTable(localPool, azurePool, { name: table, triggers }) {
  console.log(`\n== dbo.${table}`);
  const azureCols = (await azureSelect(azurePool, COLUMNS_SQL(table))).recordset;
  if (!azureCols.length) throw new Error(`Azure dbo.${table} missing.`);

  const localCols = await ensureLocalColumns(localPool, table, azureCols);
  const azureNames = new Set(azureCols.map((c) => c.name.toLowerCase()));
  const cols = localCols.filter((c) => azureNames.has(c.name.toLowerCase()));
  if (!cols.some((c) => c.name === 'id')) {
    throw new Error(`dbo.${table} has no id column.`);
  }

  const rows = (
    await azureSelect(
      azurePool,
      `SELECT ${cols.map((c) => q(c.name)).join(', ')} FROM dbo.${table} ORDER BY id`,
    )
  ).recordset;
  console.log(`  Azure rows: ${rows.length}`);

  const withClause = cols
    .map((c) => `${q(c.name)} ${typeSpec(c)} '$."${c.name}"'`)
    .join(',\n      ');
  const colList = cols.map((c) => q(c.name)).join(', ');
  const nonIdCols = cols.filter((c) => c.name !== 'id');
  const comparable = nonIdCols.filter(
    (c) => !NON_COMPARABLE_TYPES.has(c.type.toLowerCase()),
  );
  const hasIdentity = localCols.some((c) => c.is_identity);
  const hasDeletedAt = localCols.some((c) => c.name === 'deleted_at');
  const hasUpdatedAt = localCols.some((c) => c.name === 'updated_at');

  const tx = new sql.Transaction(localPool);
  await tx.begin();
  try {
    for (const trg of triggers) {
      await new sql.Request(tx).query(`DISABLE TRIGGER dbo.${q(trg)} ON dbo.${q(table)};`);
    }

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

    for (let i = 0; i < rows.length; i += BATCH_SIZE) {
      const chunk = rows.slice(i, i + BATCH_SIZE).map((row) => {
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
      WHERE d.deleted_at IS NULL
        AND NOT EXISTS (SELECT 1 FROM #stg s WHERE s.id = d.id);
      SET @del = @@ROWCOUNT;`
          : ''
      }

      DROP TABLE #stg;
      SELECT @upd AS updated, @ins AS inserted, @del AS soft_deleted_local_only;
    `);

    for (const trg of triggers) {
      await new sql.Request(tx).query(`ENABLE TRIGGER dbo.${q(trg)} ON dbo.${q(table)};`);
    }
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

async function runHrSync(localPool) {
  for (const file of HR_SYNC_FILES) {
    const text = readFileSync(join(__dirname, file), 'utf8');
    for (const batch of splitBatches(text)) {
      const req = localPool.request();
      req.on('info', (info) => console.log(`  ${info.message}`));
      await req.query(batch);
    }
    console.log(`✓ applied ${file}`);
  }
}

console.log(
  `Local WRITE target: ${localConfig.server}/${localConfig.database} (port ${localConfig.port})`,
);
const azureMeta = getAzureReadonlyConfig();
console.log(`Azure READ-ONLY source: ${azureMeta.server}/${azureMeta.database}`);

const localPool = new sql.ConnectionPool(localConfig);
await localPool.connect();
console.log('✓ local connected (writable)');
const azurePool = await openAzureReadonly();

try {
  for (const table of TABLES) {
    await syncTable(localPool, azurePool, table);
  }

  console.log('\n== hr.* refresh');
  await runHrSync(localPool);

  const summary = await localPool.request().query(`
    SELECT
      (SELECT COUNT(*) FROM dbo.workers) AS dbo_workers,
      (SELECT COUNT(*) FROM dbo.workers WHERE deleted_at IS NULL) AS dbo_workers_active,
      (SELECT COUNT(*) FROM dbo.workers_vendor_new) AS dbo_workers_vendor_new,
      (SELECT COUNT(*) FROM dbo.workers_vendor_new WHERE deleted_at IS NULL) AS dbo_workers_vendor_new_active,
      (SELECT COUNT(*) FROM hr.workers) AS hr_workers,
      (SELECT COUNT(*) FROM hr.workers WHERE deleted_at IS NULL) AS hr_workers_active,
      (SELECT COUNT(*) FROM hr.workers_vendor) AS hr_workers_vendor,
      (SELECT COUNT(*) FROM hr.workers_vendor WHERE deleted_at IS NULL) AS hr_workers_vendor_active
  `);
  console.log('\nOK', summary.recordset[0]);
} finally {
  await azurePool.close();
  await localPool.close();
}

process.exit(0);
