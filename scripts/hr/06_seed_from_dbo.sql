-- =============================================
-- Seed / ETL: copy dbo.menu_privilege + dbo.users → hr.*
-- Default site: hr.jobsites id = 1 (DEFAULT)
-- Preserves dbo.users.id as hr.users.id (IDENTITY_INSERT);
-- legacy_id = src.id so id = legacy_id for cutover / FK views.
-- Safe to re-run: skips rows already present (by level id / legacy_id).
-- Run AFTER 05_views_login.sql (needs tables; views optional)
-- =============================================
SET NOCOUNT ON;

DECLARE @JobsiteId INT = 1;

IF NOT EXISTS (SELECT 1 FROM hr.jobsites WHERE id = @JobsiteId AND deleted_at IS NULL)
BEGIN
    THROW 50001, 'hr.jobsites id=1 (DEFAULT) missing. Run 02_jobsites.sql first.', 1;
END;

-- ---- menu_privilege ----
INSERT INTO hr.menu_privilege (
    id,
    by_jobsite,
    name,
    menu,
    dashboard,
    access_create,
    access_read,
    access_update,
    access_delete,
    access_export,
    created_at,
    updated_at,
    deleted_at,
    created_by
)
SELECT
    src.id,
    @JobsiteId,
    src.id,
    ISNULL(src.menu, N''),
    ISNULL(src.dashboard, N''),
    src.[create],
    src.[read],
    src.[update],
    src.[delete],
    src.[export],
    src.created_at,
    src.updated_at,
    src.deleted_at, NULL
FROM dbo.menu_privilege AS src
WHERE NOT EXISTS (
    SELECT 1
    FROM hr.menu_privilege AS dst
    WHERE dst.id = src.id
      AND dst.by_jobsite = @JobsiteId
);

PRINT CONCAT('menu_privilege rows for jobsite ', @JobsiteId, ': ', @@ROWCOUNT);

-- ---- users (only those whose level exists on this jobsite) ----
-- Preserve dbo id. Skip when target id is already taken by a different row.
SET IDENTITY_INSERT hr.users ON;

INSERT INTO hr.users (
    id,
    by_jobsite,
    username,
    password,
    full_name,
    email,
    phone,
    department,
    section,
    description,
    level,
    privilege_menu,
    ref_id,
    activation_key,
    last_login,
    is_active,
    created_at,
    updated_at,
    deleted_at,
    created_by,
    legacy_id
)
SELECT
    src.id,
    @JobsiteId,
    src.username,
    src.password,
    src.full_name,
    src.email,
    src.phone,
    src.department,
    src.section,
    src.description,
    src.level,
    src.privilege_menu,
    src.ref_id,
    src.activation_key,
    src.last_login,
    CASE WHEN src.deleted_at IS NULL THEN 1 ELSE 0 END,
    src.created_at,
    src.updated_at,
    src.deleted_at,
    NULL,
    src.id
FROM dbo.users AS src
INNER JOIN hr.menu_privilege AS mp
    ON mp.id = src.level
   AND mp.by_jobsite = @JobsiteId
WHERE NOT EXISTS (
    SELECT 1
    FROM hr.users AS dst
    WHERE dst.legacy_id = src.id
)
AND NOT EXISTS (
    SELECT 1
    FROM hr.users AS taken
    WHERE taken.id = src.id
);

PRINT CONCAT('users rows inserted (id=legacy_id) for jobsite ', @JobsiteId, ': ', @@ROWCOUNT);

SET IDENTITY_INSERT hr.users OFF;

-- Collisions: dbo user whose id is already occupied in hr by another row
SELECT
    u.id AS legacy_id,
    u.username,
    taken.id AS blocking_hr_id,
    taken.username AS blocking_username,
    taken.legacy_id AS blocking_legacy_id,
    N'hr.users.id already taken — run seed_realign_users_ids.js or free the id' AS reason
FROM dbo.users u
INNER JOIN hr.menu_privilege AS mp
    ON mp.id = u.level
   AND mp.by_jobsite = @JobsiteId
INNER JOIN hr.users AS taken
    ON taken.id = u.id
WHERE NOT EXISTS (
    SELECT 1 FROM hr.users dst WHERE dst.legacy_id = u.id
);

-- Report orphans (dbo users whose level was not migrated)
SELECT
    u.id AS legacy_id,
    u.username,
    u.level,
    N'level missing in hr.menu_privilege for jobsite' AS reason
FROM dbo.users u
WHERE u.deleted_at IS NULL
  AND NOT EXISTS (
      SELECT 1 FROM hr.menu_privilege mp
      WHERE mp.id = u.level AND mp.by_jobsite = @JobsiteId
  );

-- Fail soft report: migrated users whose id drifted from legacy_id
SELECT
    id,
    legacy_id,
    username,
    N'id <> legacy_id — run node scripts/hr/seed_realign_users_ids.js' AS reason
FROM hr.users
WHERE by_jobsite = @JobsiteId
  AND legacy_id IS NOT NULL
  AND id <> legacy_id;
GO
