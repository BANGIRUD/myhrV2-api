/**
 * Sync Azure dbo.menu_privilege + dbo.users → local dbo.* + hr.*
 * Adapts to multi-site hr format (by_jobsite=DEFAULT) and backfills level_id.
 *
 * hr.users.id is always preserved as dbo.users.id (IDENTITY_INSERT).
 * legacy_id = dbo id so id = legacy_id. No silent remap on collision —
 * skip + report; run seed_realign_users_ids.js if local ids have drifted.
 *
 * Azure access is READ-ONLY (config/azureReadonly.js). All writes go to local DB_*.
 *
 * Usage: node scripts/hr/seed_users_from_azure.js
 */
import dotenv from 'dotenv';
import sql from 'mssql';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';
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

if (!localConfig.server || !localConfig.user || !localConfig.password) {
  throw new Error('Local DB_* env incomplete. Check .env');
}

async function ensureJobsite(localPool) {
  const r = await localPool
    .request()
    .input('jid', sql.Int, JOBSITE_ID)
    .query(`
      SELECT id FROM hr.jobsites WHERE id = @jid AND deleted_at IS NULL
    `);
  if (!r.recordset.length) {
    throw new Error(
      `hr.jobsites id=${JOBSITE_ID} missing. Run scripts/hr/run_migrate.js first.`,
    );
  }
}

async function mergeMenuPrivilegeToDbo(localPool, rows) {
  let n = 0;
  for (const row of rows) {
    await localPool
      .request()
      .input('id', sql.NVarChar(50), row.id)
      .input('menu', sql.NVarChar(sql.MAX), row.menu ?? '')
      .input('dashboard', sql.NVarChar(sql.MAX), row.dashboard ?? '')
      .input('create', sql.NVarChar(50), row.create)
      .input('read', sql.NVarChar(50), row.read)
      .input('update', sql.NVarChar(50), row.update)
      .input('delete', sql.NVarChar(50), row.delete)
      .input('export', sql.NVarChar(50), row.export)
      .input('created_at', sql.DateTime2, row.created_at)
      .input('updated_at', sql.DateTime2, row.updated_at)
      .input('deleted_at', sql.DateTime2, row.deleted_at)
      .query(`
        IF EXISTS (SELECT 1 FROM dbo.menu_privilege WHERE id = @id)
        BEGIN
          UPDATE dbo.menu_privilege SET
            menu = @menu,
            dashboard = @dashboard,
            [create] = @create,
            [read] = @read,
            [update] = @update,
            [delete] = @delete,
            [export] = @export,
            created_at = @created_at,
            updated_at = @updated_at,
            deleted_at = @deleted_at
          WHERE id = @id;
        END
        ELSE
        BEGIN
          INSERT INTO dbo.menu_privilege (
            id, menu, dashboard, [create], [read], [update], [delete], [export],
            created_at, updated_at, deleted_at
          ) VALUES (
            @id, @menu, @dashboard, @create, @read, @update, @delete, @export,
            @created_at, @updated_at, @deleted_at
          );
        END
      `);
    n += 1;
  }
  console.log(`✓ dbo.menu_privilege upserted: ${n}`);
}

async function mergeMenuPrivilegeToHr(localPool, rows) {
  let n = 0;
  for (const row of rows) {
    await localPool
      .request()
      .input('id', sql.NVarChar(50), row.id)
      .input('by_jobsite', sql.Int, JOBSITE_ID)
      .input('name', sql.NVarChar(100), row.id)
      .input('menu', sql.NVarChar(sql.MAX), row.menu ?? '')
      .input('dashboard', sql.NVarChar(sql.MAX), row.dashboard ?? '')
      .input('access_create', sql.NVarChar(50), row.create)
      .input('access_read', sql.NVarChar(50), row.read)
      .input('access_update', sql.NVarChar(50), row.update)
      .input('access_delete', sql.NVarChar(50), row.delete)
      .input('access_export', sql.NVarChar(50), row.export)
      .input('created_at', sql.DateTime2, row.created_at)
      .input('updated_at', sql.DateTime2, row.updated_at)
      .input('deleted_at', sql.DateTime2, row.deleted_at)
      .query(`
        IF EXISTS (
          SELECT 1 FROM hr.menu_privilege
          WHERE id = @id AND by_jobsite = @by_jobsite
        )
        BEGIN
          UPDATE hr.menu_privilege SET
            name = @name,
            menu = @menu,
            dashboard = @dashboard,
            access_create = @access_create,
            access_read = @access_read,
            access_update = @access_update,
            access_delete = @access_delete,
            access_export = @access_export,
            created_at = ISNULL(@created_at, created_at),
            updated_at = @updated_at,
            deleted_at = @deleted_at,
            updated_by = NULL
          WHERE id = @id AND by_jobsite = @by_jobsite;
        END
        ELSE
        BEGIN
          INSERT INTO hr.menu_privilege (
            id, by_jobsite, name, menu, dashboard,
            access_create, access_read, access_update, access_delete, access_export,
            created_at, updated_at, deleted_at, created_by
          ) VALUES (
            @id, @by_jobsite, @name, @menu, @dashboard,
            @access_create, @access_read, @access_update, @access_delete, @access_export,
            ISNULL(@created_at, SYSUTCDATETIME()), @updated_at, @deleted_at, NULL
          );
        END
      `);
    n += 1;
  }
  console.log(`✓ hr.menu_privilege upserted (jobsite ${JOBSITE_ID}): ${n}`);
}

async function mergeUsersToDbo(localPool, rows) {
  let n = 0;
  for (const row of rows) {
    await localPool
      .request()
      .input('id', sql.Int, row.id)
      .input('created_at', sql.DateTime2, row.created_at)
      .input('updated_at', sql.DateTime2, row.updated_at)
      .input('deleted_at', sql.DateTime2, row.deleted_at)
      .input('username', sql.NVarChar(50), row.username)
      .input('password', sql.NVarChar(255), row.password)
      .input('full_name', sql.NVarChar(150), row.full_name)
      .input('department', sql.NVarChar(100), row.department)
      .input('section', sql.NVarChar(100), row.section)
      .input('description', sql.NVarChar(sql.MAX), row.description)
      .input('email', sql.NVarChar(150), row.email)
      .input('phone', sql.NVarChar(30), row.phone)
      .input('activation_key', sql.NVarChar(100), row.activation_key)
      .input('last_login', sql.DateTime2, row.last_login)
      .input('privilege_menu', sql.NVarChar(sql.MAX), row.privilege_menu)
      .input('ref_id', sql.BigInt, row.ref_id)
      .input('level', sql.NVarChar(50), row.level)
      .query(`
        IF EXISTS (SELECT 1 FROM dbo.users WHERE id = @id)
        BEGIN
          UPDATE dbo.users SET
            created_at = @created_at,
            updated_at = @updated_at,
            deleted_at = @deleted_at,
            username = @username,
            password = @password,
            full_name = @full_name,
            department = @department,
            section = @section,
            description = @description,
            email = @email,
            phone = @phone,
            activation_key = @activation_key,
            last_login = @last_login,
            privilege_menu = @privilege_menu,
            ref_id = @ref_id,
            level = @level
          WHERE id = @id;
        END
        ELSE
        BEGIN
          SET IDENTITY_INSERT dbo.users ON;
          INSERT INTO dbo.users (
            id, created_at, updated_at, deleted_at, username, password, full_name,
            department, section, description, email, phone, activation_key,
            last_login, privilege_menu, ref_id, level
          ) VALUES (
            @id, @created_at, @updated_at, @deleted_at, @username, @password, @full_name,
            @department, @section, @description, @email, @phone, @activation_key,
            @last_login, @privilege_menu, @ref_id, @level
          );
          SET IDENTITY_INSERT dbo.users OFF;
        END
      `);
    n += 1;
  }
  console.log(`✓ dbo.users upserted: ${n}`);
}

async function mergeUsersToHr(localPool, rows) {
  let updated = 0;
  let inserted = 0;
  const skippedPriv = [];
  const skippedCollision = [];

  for (const row of rows) {
    // Ensure privilege exists (FK)
    const priv = await localPool
      .request()
      .input('level', sql.NVarChar(50), row.level)
      .input('by_jobsite', sql.Int, JOBSITE_ID)
      .query(`
        SELECT id FROM hr.menu_privilege
        WHERE id = @level AND by_jobsite = @by_jobsite
      `);
    if (!priv.recordset.length) {
      skippedPriv.push({ id: row.id, username: row.username, level: row.level });
      continue;
    }

    const isActive = row.deleted_at == null ? 1 : 0;
    const result = await localPool
      .request()
      .input('legacy_id', sql.Int, row.id)
      .input('by_jobsite', sql.Int, JOBSITE_ID)
      .input('username', sql.NVarChar(50), row.username)
      .input('password', sql.NVarChar(255), row.password)
      .input('full_name', sql.NVarChar(150), row.full_name)
      .input('email', sql.NVarChar(150), row.email)
      .input('phone', sql.NVarChar(30), row.phone)
      .input('department', sql.NVarChar(100), row.department)
      .input('section', sql.NVarChar(100), row.section)
      .input('description', sql.NVarChar(sql.MAX), row.description)
      .input('level', sql.NVarChar(50), row.level)
      .input('legacy_level', sql.NVarChar(50), row.level)
      .input('privilege_menu', sql.NVarChar(sql.MAX), row.privilege_menu)
      .input('ref_id', sql.BigInt, row.ref_id)
      .input('activation_key', sql.NVarChar(100), row.activation_key)
      .input('last_login', sql.DateTime2, row.last_login)
      .input('is_active', sql.Bit, isActive)
      .input('created_at', sql.DateTime2, row.created_at)
      .input('updated_at', sql.DateTime2, row.updated_at)
      .input('deleted_at', sql.DateTime2, row.deleted_at)
      .query(`
        IF EXISTS (
          SELECT 1 FROM hr.users
          WHERE legacy_id = @legacy_id AND by_jobsite = @by_jobsite
        )
        BEGIN
          UPDATE hr.users SET
            username = @username,
            password = @password,
            full_name = @full_name,
            email = @email,
            phone = @phone,
            department = @department,
            section = @section,
            description = @description,
            level = @level,
            legacy_level = @legacy_level,
            privilege_menu = @privilege_menu,
            ref_id = @ref_id,
            activation_key = @activation_key,
            last_login = @last_login,
            is_active = @is_active,
            created_at = ISNULL(@created_at, created_at),
            updated_at = @updated_at,
            deleted_at = @deleted_at,
            updated_by = NULL
          WHERE legacy_id = @legacy_id AND by_jobsite = @by_jobsite;
          SELECT N'updated' AS action;
        END
        ELSE IF NOT EXISTS (SELECT 1 FROM hr.users WHERE id = @legacy_id)
        BEGIN
          -- Always preserve dbo id (no silent remap)
          SET IDENTITY_INSERT hr.users ON;
          INSERT INTO hr.users (
            id, by_jobsite, username, password, full_name, email, phone,
            department, section, description, level, legacy_level,
            privilege_menu, ref_id, activation_key, last_login, is_active,
            created_at, created_by, updated_at, deleted_at, legacy_id
          ) VALUES (
            @legacy_id, @by_jobsite, @username, @password, @full_name, @email, @phone,
            @department, @section, @description, @level, @legacy_level,
            @privilege_menu, @ref_id, @activation_key, @last_login, @is_active,
            ISNULL(@created_at, SYSUTCDATETIME()), NULL, @updated_at,
            @deleted_at, @legacy_id
          );
          SET IDENTITY_INSERT hr.users OFF;
          SELECT N'inserted' AS action;
        END
        ELSE
        BEGIN
          SELECT N'collision' AS action;
        END
      `);

    const action = result.recordset[0]?.action;
    if (action === 'inserted') inserted += 1;
    else if (action === 'updated') updated += 1;
    else if (action === 'collision') {
      skippedCollision.push({ id: row.id, username: row.username });
    }
  }

  console.log(
    `✓ hr.users upserted (jobsite ${JOBSITE_ID}): updated=${updated}, inserted=${inserted}, skipped_priv=${skippedPriv.length}, skipped_collision=${skippedCollision.length}`,
  );
  if (skippedPriv.length) {
    console.log('  skipped (missing menu_privilege):', skippedPriv.slice(0, 20));
  }
  if (skippedCollision.length) {
    console.error(
      '  skipped (id collision — free the id or run seed_realign_users_ids.js):',
      skippedCollision.slice(0, 20),
    );
  }
}

/** Fail if any dbo-sourced user has id <> legacy_id (needs realign). */
async function assertUsersIdEqualsLegacy(localPool) {
  const r = await localPool
    .request()
    .input('by_jobsite', sql.Int, JOBSITE_ID)
    .query(`
      SELECT id, legacy_id, username
      FROM hr.users
      WHERE by_jobsite = @by_jobsite
        AND legacy_id IS NOT NULL
        AND id <> legacy_id
      ORDER BY id;
    `);
  if (r.recordset.length) {
    console.error(
      `✗ hr.users id≠legacy_id: ${r.recordset.length} row(s). Run: node scripts/hr/seed_realign_users_ids.js`,
    );
    console.error('  sample:', r.recordset.slice(0, 10));
    throw new Error(
      `hr.users has ${r.recordset.length} row(s) with id <> legacy_id`,
    );
  }
  console.log('✓ hr.users id = legacy_id for all dbo-sourced rows');
}

async function softDeleteLocalOnlyUsers(localPool, azureIds) {
  // Single-batch table variable (pool may use different sessions per request)
  const values = azureIds.map((id) => `(${Number(id)})`).join(',');
  const result = await localPool
    .request()
    .input('by_jobsite', sql.Int, JOBSITE_ID)
    .query(`
      DECLARE @azure_user_ids TABLE (id INT NOT NULL PRIMARY KEY);
      INSERT INTO @azure_user_ids (id) VALUES ${values};

      DECLARE @dbo_n INT, @hr_n INT;

      UPDATE u SET
        deleted_at = ISNULL(u.deleted_at, SYSUTCDATETIME()),
        updated_at = SYSUTCDATETIME()
      FROM dbo.users u
      WHERE NOT EXISTS (SELECT 1 FROM @azure_user_ids a WHERE a.id = u.id)
        AND u.deleted_at IS NULL;
      SET @dbo_n = @@ROWCOUNT;

      UPDATE u SET
        deleted_at = ISNULL(u.deleted_at, SYSUTCDATETIME()),
        is_active = 0,
        updated_at = SYSUTCDATETIME(),
        updated_by = NULL
      FROM hr.users u
      WHERE u.by_jobsite = @by_jobsite
        AND u.legacy_id IS NOT NULL
        AND NOT EXISTS (SELECT 1 FROM @azure_user_ids a WHERE a.id = u.legacy_id)
        AND u.deleted_at IS NULL;
      SET @hr_n = @@ROWCOUNT;

      SELECT @dbo_n AS dbo_n, @hr_n AS hr_n;
    `);

  console.log(
    `✓ soft-deleted local-only users: dbo=${result.recordset[0].dbo_n}, hr=${result.recordset[0].hr_n} (azure ids=${azureIds.length})`,
  );
}

async function backfillLevelId(localPool) {
  const r = await localPool
    .request()
    .input('by_jobsite', sql.Int, JOBSITE_ID)
    .query(`
      UPDATE u
      SET u.level_id = m.level_id,
          u.worker_scope = ISNULL(u.worker_scope, m.worker_scope),
          u.module = ISNULL(u.module, m.module),
          u.legacy_level = ISNULL(u.legacy_level, u.level),
          u.updated_at = SYSUTCDATETIME(),
          u.updated_by = NULL
      FROM hr.users u
      INNER JOIN hr.level_legacy_map m
        ON m.by_jobsite = u.by_jobsite
       AND m.legacy_code = u.level
      WHERE u.by_jobsite = @by_jobsite
        AND (
              u.level_id IS NULL
           OR u.level_id <> m.level_id
           OR (u.worker_scope IS NULL AND m.worker_scope IS NOT NULL)
           OR (u.module IS NULL AND m.module IS NOT NULL)
        );

      SELECT @@ROWCOUNT AS mapped;

      SELECT COUNT(*) AS unmapped
      FROM hr.users u
      WHERE u.by_jobsite = @by_jobsite
        AND u.deleted_at IS NULL
        AND u.level_id IS NULL;
    `);

  // mssql returns multiple recordsets
  const mapped = r.recordsets?.[0]?.[0]?.mapped ?? r.recordset?.[0]?.mapped;
  const unmapped = r.recordsets?.[1]?.[0]?.unmapped;
  console.log(`✓ level_id backfill: mapped=${mapped}, unmapped_active=${unmapped}`);
}

console.log(
  `Local WRITE target: ${localConfig.server}/${localConfig.database} (port ${localConfig.port})`,
);
const azureMeta = getAzureReadonlyConfig();
console.log(
  `Azure READ-ONLY source: ${azureMeta.server}/${azureMeta.database}`,
);

const localPool = new sql.ConnectionPool(localConfig);
await localPool.connect();
console.log('✓ local connected (writable)');
const azurePool = await openAzureReadonly();

try {
  await ensureJobsite(localPool);

  const priv = await azureSelect(
    azurePool,
    `
    SELECT id, menu, dashboard, [create], [read], [update], [delete], [export],
           created_at, updated_at, deleted_at
    FROM dbo.menu_privilege
    ORDER BY id
  `,
  );
  console.log(`Azure dbo.menu_privilege: ${priv.recordset.length} rows`);

  const users = await azureSelect(
    azurePool,
    `
    SELECT id, created_at, updated_at, deleted_at, username, password, full_name,
           department, section, description, email, phone, activation_key,
           last_login, privilege_menu, ref_id, level
    FROM dbo.users
    ORDER BY id
  `,
  );
  console.log(`Azure dbo.users: ${users.recordset.length} rows`);

  await mergeMenuPrivilegeToDbo(localPool, priv.recordset);
  await mergeMenuPrivilegeToHr(localPool, priv.recordset);
  await mergeUsersToDbo(localPool, users.recordset);
  await mergeUsersToHr(localPool, users.recordset);
  await softDeleteLocalOnlyUsers(
    localPool,
    users.recordset.map((u) => u.id),
  );
  await backfillLevelId(localPool);
  await assertUsersIdEqualsLegacy(localPool);

  const summary = await localPool
    .request()
    .input('by_jobsite', sql.Int, JOBSITE_ID)
    .query(`
      SELECT
        (SELECT COUNT(*) FROM dbo.users) AS dbo_users,
        (SELECT COUNT(*) FROM dbo.users WHERE deleted_at IS NULL) AS dbo_users_active,
        (SELECT COUNT(*) FROM hr.users WHERE by_jobsite = @by_jobsite) AS hr_users,
        (SELECT COUNT(*) FROM hr.users WHERE by_jobsite = @by_jobsite AND deleted_at IS NULL) AS hr_users_active,
        (SELECT COUNT(*) FROM hr.users WHERE by_jobsite = @by_jobsite AND deleted_at IS NULL AND level_id IS NULL) AS hr_unmapped_level,
        (SELECT COUNT(*) FROM hr.menu_privilege WHERE by_jobsite = @by_jobsite) AS hr_privileges
    `);
  console.log('OK', summary.recordset[0]);

  const byLevel = await localPool
    .request()
    .input('by_jobsite', sql.Int, JOBSITE_ID)
    .query(`
      SELECT level, COUNT(*) AS n
      FROM hr.users
      WHERE by_jobsite = @by_jobsite AND deleted_at IS NULL
      GROUP BY level
      ORDER BY n DESC
    `);
  console.log('hr.users active by level:', byLevel.recordset);
} finally {
  await azurePool.close();
  await localPool.close();
}

process.exit(0);
