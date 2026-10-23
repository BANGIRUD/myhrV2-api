-- =============================================
-- Upgrade hr.users: add level_id (canonical) + backfill from legacy map
-- Keep column [level] as legacy privilege key for dbo parity / menu_privilege FK
-- Run AFTER 08_level_legacy_map.sql
-- =============================================
IF COL_LENGTH('hr.users', 'level_id') IS NULL
BEGIN
    ALTER TABLE hr.users ADD level_id INT NULL;
END
GO

IF COL_LENGTH('hr.users', 'legacy_level') IS NULL
BEGIN
    -- Snapshot of original level string at migration time (optional audit)
    ALTER TABLE hr.users ADD legacy_level NVARCHAR(50) NULL;
END
GO

-- Per-user attributes that replace merged levels (see 27_levels_consolidate.sql)
--   worker_scope: sis | ls | all  (hr_admin / hr_administrator data scope)
--   module: irel | meals | safety | attendance  (module_admin)
IF COL_LENGTH('hr.users', 'worker_scope') IS NULL
BEGIN
    ALTER TABLE hr.users ADD worker_scope NVARCHAR(10) NULL;
END
GO

IF COL_LENGTH('hr.users', 'module') IS NULL
BEGIN
    ALTER TABLE hr.users ADD module NVARCHAR(30) NULL;
END
GO

-- Copy current level → legacy_level once
UPDATE u
SET u.legacy_level = u.level
FROM hr.users u
WHERE u.legacy_level IS NULL;
GO

-- Backfill level_id from map (jobsite-aware)
UPDATE u
SET u.level_id = m.level_id,
    u.updated_at = SYSUTCDATETIME(),
    u.updated_by = NULL
FROM hr.users u
INNER JOIN hr.level_legacy_map m
    ON m.by_jobsite = u.by_jobsite
   AND m.legacy_code = u.level
WHERE u.level_id IS NULL
   OR u.level_id <> m.level_id;
GO

-- FK (idempotent)
IF NOT EXISTS (
    SELECT 1 FROM sys.foreign_keys WHERE name = 'FK_hr_users_level_id'
)
BEGIN
    ALTER TABLE hr.users
        ADD CONSTRAINT FK_hr_users_level_id
        FOREIGN KEY (level_id) REFERENCES hr.levels (id);
END
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes WHERE name = 'IX_hr_users_level_id' AND object_id = OBJECT_ID('hr.users')
)
BEGIN
    CREATE INDEX IX_hr_users_level_id
        ON hr.users (by_jobsite, level_id)
        WHERE deleted_at IS NULL;
END
GO

-- Report unmapped users (should be empty)
SELECT
    u.id,
    u.username,
    u.level AS legacy_code,
    u.level_id,
    N'no mapping for legacy level' AS issue
FROM hr.users u
WHERE u.deleted_at IS NULL
  AND u.level_id IS NULL;
GO

-- Summary by canonical level
SELECT
    l.code,
    l.name,
    l.approval_stage,
    l.structure_scoped,
    COUNT(u.id) AS users_active
FROM hr.levels l
LEFT JOIN hr.users u
    ON u.level_id = l.id
   AND u.deleted_at IS NULL
WHERE l.by_jobsite = 1
  AND l.deleted_at IS NULL
GROUP BY l.code, l.name, l.approval_stage, l.structure_scoped, l.sort_order
ORDER BY l.sort_order, l.code;
GO
