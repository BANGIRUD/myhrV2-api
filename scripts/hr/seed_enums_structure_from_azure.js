/**
 * Pull dbo.enums + dbo.structure from Azure MYHR production → local hr.*
 * (multi-site format: by_jobsite + hr audit columns). Also MERGEs into
 * local dbo.* so legacy objects stay aligned — no DELETE (FK-safe).
 *
 * Azure access is READ-ONLY (config/azureReadonly.js). All writes go to local DB_*.
 *
 * Usage: node scripts/hr/seed_enums_structure_from_azure.js
 */
import dotenv from 'dotenv';
import sql from 'mssql';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';
import { readFileSync } from 'fs';
import {
  openAzureReadonly,
  azureSelect,
  getAzureReadonlyConfig,
} from '../../config/azureReadonly.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
dotenv.config({ path: join(__dirname, '..', '..', '.env') });

const JOBSITE_ID = Number(process.env.DEFAULT_JOBSITE_ID || 1);

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

function splitBatches(sqlText) {
  return sqlText
    .split(/^\s*GO\s*$/gim)
    .map((batch) => batch.trim())
    .filter(Boolean);
}

async function ensureHrTables(localPool) {
  // Ensure schema exists first
  await localPool.request().query(`
    IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'hr')
      EXEC('CREATE SCHEMA hr');
  `);

  for (const file of ['16_enums.sql', '17_structure.sql']) {
    const text = readFileSync(join(__dirname, file), 'utf8');
    for (const batch of splitBatches(text)) {
      await localPool.request().query(batch);
    }
    console.log(`✓ applied ${file}`);
  }

  const jobsites = await localPool
    .request()
    .input('jid', sql.Int, JOBSITE_ID)
    .query(`
      SELECT id FROM hr.jobsites WHERE id = @jid AND deleted_at IS NULL
    `);
  if (!jobsites.recordset.length) {
    throw new Error(
      `hr.jobsites id=${JOBSITE_ID} missing. Run scripts/hr/run_migrate.js first.`,
    );
  }
}

async function fetchAzureRows(azurePool, table) {
  if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(table)) {
    throw new Error(`Invalid table name: ${table}`);
  }
  const result = await azureSelect(
    azurePool,
    `SELECT * FROM dbo.${table} ORDER BY id`,
  );
  console.log(`Azure dbo.${table}: ${result.recordset.length} rows`);
  return result.recordset;
}

async function mergeEnumsToDbo(localPool, rows) {
  let upserted = 0;
  for (const row of rows) {
    await localPool
      .request()
      .input('id', sql.Int, row.id)
      .input('created_at', sql.DateTime2, row.created_at)
      .input('updated_at', sql.DateTime2, row.updated_at)
      .input('deleted_at', sql.DateTime2, row.deleted_at)
      .input('code', sql.NVarChar(50), row.code)
      .input('name', sql.NVarChar(sql.MAX), row.name)
      .input('category', sql.NVarChar(50), row.category)
      .input('description', sql.NVarChar(sql.MAX), row.description)
      .input('type', sql.NVarChar(50), row.type)
      .input('ref_id', sql.BigInt, row.ref_id)
      .input('by_user', sql.Int, row.by_user)
      .query(`
        IF EXISTS (SELECT 1 FROM dbo.enums WHERE id = @id)
        BEGIN
          UPDATE dbo.enums SET
            created_at = @created_at,
            updated_at = @updated_at,
            deleted_at = @deleted_at,
            code = @code,
            name = @name,
            category = @category,
            description = @description,
            type = @type,
            ref_id = @ref_id,
            by_user = @by_user
          WHERE id = @id;
        END
        ELSE
        BEGIN
          SET IDENTITY_INSERT dbo.enums ON;
          INSERT INTO dbo.enums (
            id, created_at, updated_at, deleted_at, code, name,
            category, description, type, ref_id, by_user
          ) VALUES (
            @id, @created_at, @updated_at, @deleted_at, @code, @name,
            @category, @description, @type, @ref_id, @by_user
          );
          SET IDENTITY_INSERT dbo.enums OFF;
        END
      `);
    upserted += 1;
  }
  console.log(`✓ dbo.enums upserted: ${upserted}`);
}

async function mergeStructureToDbo(localPool, rows) {
  let upserted = 0;
  for (const row of rows) {
    await localPool
      .request()
      .input('id', sql.Int, row.id)
      .input('key_id', sql.NVarChar(100), row.key_id)
      .input('created_at', sql.DateTime2, row.created_at)
      .input('updated_at', sql.DateTime2, row.updated_at)
      .input('deleted_at', sql.DateTime2, row.deleted_at)
      .input('code', sql.NVarChar(50), row.code)
      .input('name', sql.NVarChar(sql.MAX), row.name)
      .input('category', sql.NVarChar(50), row.category)
      .input('description', sql.NVarChar(sql.MAX), row.description)
      .input('type', sql.NVarChar(50), row.type)
      .input('ref_id', sql.BigInt, row.ref_id)
      .input('by_order', sql.Int, row.by_order)
      .input('by_user', sql.Int, row.by_user)
      .query(`
        IF EXISTS (SELECT 1 FROM dbo.structure WHERE id = @id)
        BEGIN
          UPDATE dbo.structure SET
            key_id = @key_id,
            created_at = @created_at,
            updated_at = @updated_at,
            deleted_at = @deleted_at,
            code = @code,
            name = @name,
            category = @category,
            description = @description,
            type = @type,
            ref_id = @ref_id,
            by_order = @by_order,
            by_user = @by_user
          WHERE id = @id;
        END
        ELSE
        BEGIN
          SET IDENTITY_INSERT dbo.structure ON;
          INSERT INTO dbo.structure (
            id, key_id, created_at, updated_at, deleted_at, code, name,
            category, description, type, ref_id, by_order, by_user
          ) VALUES (
            @id, @key_id, @created_at, @updated_at, @deleted_at, @code, @name,
            @category, @description, @type, @ref_id, @by_order, @by_user
          );
          SET IDENTITY_INSERT dbo.structure OFF;
        END
      `);
    upserted += 1;
  }
  console.log(`✓ dbo.structure upserted: ${upserted}`);
}

async function mergeEnumsToHr(localPool, rows) {
  let upserted = 0;
  for (const row of rows) {
    const createdBy = row.by_user != null && Number.isFinite(Number(row.by_user)) ? Number(row.by_user) : null;
    await localPool
      .request()
      .input('id', sql.Int, row.id)
      .input('by_jobsite', sql.Int, JOBSITE_ID)
      .input('code', sql.NVarChar(50), row.code)
      .input('name', sql.NVarChar(sql.MAX), row.name)
      .input('category', sql.NVarChar(50), row.category)
      .input('description', sql.NVarChar(sql.MAX), row.description)
      .input('type', sql.NVarChar(50), row.type)
      .input('ref_id', sql.BigInt, row.ref_id)
      .input('by_user', sql.Int, row.by_user)
      .input('created_at', sql.DateTime2, row.created_at)
      .input('created_by', sql.Int, createdBy)
      .input('updated_at', sql.DateTime2, row.updated_at)
      .input('deleted_at', sql.DateTime2, row.deleted_at)
      .input('legacy_id', sql.Int, row.id)
      .query(`
        IF EXISTS (
          SELECT 1 FROM hr.enums WHERE id = @id AND by_jobsite = @by_jobsite
        )
        BEGIN
          UPDATE hr.enums SET
            code = @code,
            name = @name,
            category = @category,
            description = @description,
            type = @type,
            ref_id = @ref_id,
            by_user = @by_user,
            created_at = @created_at,
            created_by = @created_by,
            updated_at = @updated_at,
            deleted_at = @deleted_at,
            legacy_id = @legacy_id
          WHERE id = @id AND by_jobsite = @by_jobsite;
        END
        ELSE
        BEGIN
          SET IDENTITY_INSERT hr.enums ON;
          INSERT INTO hr.enums (
            id, by_jobsite, code, name, category, description, type,
            ref_id, by_user, created_at, created_by, updated_at,
            deleted_at, legacy_id
          ) VALUES (
            @id, @by_jobsite, @code, @name, @category, @description, @type,
            @ref_id, @by_user, @created_at, @created_by, @updated_at,
            @deleted_at, @legacy_id
          );
          SET IDENTITY_INSERT hr.enums OFF;
        END
      `);
    upserted += 1;
  }
  console.log(`✓ hr.enums upserted (jobsite ${JOBSITE_ID}): ${upserted}`);
}

async function mergeStructureToHr(localPool, rows) {
  let upserted = 0;
  for (const row of rows) {
    const createdBy = row.by_user != null && Number.isFinite(Number(row.by_user)) ? Number(row.by_user) : null;
    await localPool
      .request()
      .input('id', sql.Int, row.id)
      .input('by_jobsite', sql.Int, JOBSITE_ID)
      .input('key_id', sql.NVarChar(100), row.key_id)
      .input('code', sql.NVarChar(50), row.code)
      .input('name', sql.NVarChar(sql.MAX), row.name)
      .input('category', sql.NVarChar(50), row.category)
      .input('description', sql.NVarChar(sql.MAX), row.description)
      .input('type', sql.NVarChar(50), row.type)
      .input('ref_id', sql.BigInt, row.ref_id)
      .input('by_order', sql.Int, row.by_order)
      .input('by_user', sql.Int, row.by_user)
      .input('created_at', sql.DateTime2, row.created_at)
      .input('created_by', sql.Int, createdBy)
      .input('updated_at', sql.DateTime2, row.updated_at)
      .input('deleted_at', sql.DateTime2, row.deleted_at)
      .input('legacy_id', sql.Int, row.id)
      .query(`
        IF EXISTS (
          SELECT 1 FROM hr.structure WHERE id = @id AND by_jobsite = @by_jobsite
        )
        BEGIN
          UPDATE hr.structure SET
            key_id = @key_id,
            code = @code,
            name = @name,
            category = @category,
            description = @description,
            type = @type,
            ref_id = @ref_id,
            by_order = @by_order,
            by_user = @by_user,
            created_at = @created_at,
            created_by = @created_by,
            updated_at = @updated_at,
            deleted_at = @deleted_at,
            legacy_id = @legacy_id
          WHERE id = @id AND by_jobsite = @by_jobsite;
        END
        ELSE
        BEGIN
          SET IDENTITY_INSERT hr.structure ON;
          INSERT INTO hr.structure (
            id, by_jobsite, key_id, code, name, category, description, type,
            ref_id, by_order, by_user, created_at, created_by, updated_at,
            deleted_at, legacy_id
          ) VALUES (
            @id, @by_jobsite, @key_id, @code, @name, @category, @description, @type,
            @ref_id, @by_order, @by_user, @created_at, @created_by, @updated_at,
            @deleted_at, @legacy_id
          );
          SET IDENTITY_INSERT hr.structure OFF;
        END
      `);
    upserted += 1;
  }
  console.log(`✓ hr.structure upserted (jobsite ${JOBSITE_ID}): ${upserted}`);
}

if (!localConfig.server || !localConfig.user || !localConfig.password) {
  throw new Error('Local DB_* env incomplete. Check .env');
}

const azureMeta = getAzureReadonlyConfig();
console.log(
  `Local WRITE target: ${localConfig.server}/${localConfig.database} (port ${localConfig.port})`,
);
console.log(
  `Azure READ-ONLY source: ${azureMeta.server}/${azureMeta.database}`,
);

const localPool = new sql.ConnectionPool(localConfig);
await localPool.connect();
console.log('✓ local connected (writable)');
const azurePool = await openAzureReadonly();

try {
  await ensureHrTables(localPool);

  const enumsRows = await fetchAzureRows(azurePool, 'enums');
  const structureRows = await fetchAzureRows(azurePool, 'structure');

  await mergeEnumsToDbo(localPool, enumsRows);
  await mergeStructureToDbo(localPool, structureRows);
  await mergeEnumsToHr(localPool, enumsRows);
  await mergeStructureToHr(localPool, structureRows);

  const summary = await localPool.request().query(`
    SELECT
      (SELECT COUNT(*) FROM dbo.enums) AS dbo_enums,
      (SELECT COUNT(*) FROM dbo.structure) AS dbo_structure,
      (SELECT COUNT(*) FROM hr.enums WHERE by_jobsite = ${JOBSITE_ID}) AS hr_enums,
      (SELECT COUNT(*) FROM hr.structure WHERE by_jobsite = ${JOBSITE_ID}) AS hr_structure,
      (SELECT COUNT(*) FROM hr.enums WHERE by_jobsite = ${JOBSITE_ID} AND deleted_at IS NULL) AS hr_enums_active,
      (SELECT COUNT(*) FROM hr.structure WHERE by_jobsite = ${JOBSITE_ID} AND deleted_at IS NULL) AS hr_structure_active
  `);
  console.log('OK', summary.recordset[0]);
} finally {
  await azurePool.close();
  await localPool.close();
}

process.exit(0);
