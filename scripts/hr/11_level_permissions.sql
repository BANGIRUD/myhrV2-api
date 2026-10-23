-- =============================================
-- Table: hr.level_permissions — matrix level × menu
-- Flags: can_read / can_insert / can_update / can_delete / can_export / can_approve
-- Seeded from dbo.menu_privilege CSV menu lists via hr.level_legacy_map.
-- Differentiates hr_admin vs hr_admin_ls vs hr_administrator by menu set.
-- Run AFTER 08_level_legacy_map.sql + 10_menus.sql
-- =============================================
IF OBJECT_ID('hr.level_permissions', 'U') IS NULL
BEGIN
    CREATE TABLE hr.level_permissions (
        id INT IDENTITY(1,1) NOT NULL,
        by_jobsite INT NOT NULL,
        level_id INT NOT NULL,
        menu_id INT NOT NULL,
        can_read BIT NOT NULL
            CONSTRAINT DF_hr_lp_can_read DEFAULT (0),
        can_insert BIT NOT NULL
            CONSTRAINT DF_hr_lp_can_insert DEFAULT (0),
        can_update BIT NOT NULL
            CONSTRAINT DF_hr_lp_can_update DEFAULT (0),
        can_delete BIT NOT NULL
            CONSTRAINT DF_hr_lp_can_delete DEFAULT (0),
        can_export BIT NOT NULL
            CONSTRAINT DF_hr_lp_can_export DEFAULT (0),
        can_approve BIT NOT NULL
            CONSTRAINT DF_hr_lp_can_approve DEFAULT (0),
        created_at DATETIME2 NOT NULL
            CONSTRAINT DF_hr_lp_created_at DEFAULT (SYSUTCDATETIME()),
        created_by INT NULL,
        updated_at DATETIME2 NULL,
        updated_by INT NULL,
        deleted_at DATETIME2 NULL,
        deleted_by INT NULL,
        CONSTRAINT PK_hr_level_permissions PRIMARY KEY CLUSTERED (id),
        CONSTRAINT FK_hr_lp_jobsite
            FOREIGN KEY (by_jobsite) REFERENCES hr.jobsites (id),
        CONSTRAINT FK_hr_lp_level
            FOREIGN KEY (level_id) REFERENCES hr.levels (id),
        CONSTRAINT FK_hr_lp_menu
            FOREIGN KEY (menu_id) REFERENCES hr.menus (id)
    );

    CREATE UNIQUE INDEX UQ_hr_lp_level_menu_jobsite_active
        ON hr.level_permissions (by_jobsite, level_id, menu_id)
        WHERE deleted_at IS NULL;

    CREATE INDEX IX_hr_lp_level_jobsite
        ON hr.level_permissions (by_jobsite, level_id)
        WHERE deleted_at IS NULL;
END
GO

-- audience: NULL = every user of the level; otherwise CSV of tokens
-- (sis | ls | irel | meals | safety | attendance) matched against the
-- user's worker_scope / module. Set by 27_levels_consolidate.sql.
IF COL_LENGTH('hr.level_permissions', 'audience') IS NULL
BEGIN
    ALTER TABLE hr.level_permissions ADD audience NVARCHAR(100) NULL;
END
GO

DECLARE @JobsiteId INT = 1;

IF NOT EXISTS (SELECT 1 FROM hr.jobsites WHERE id = @JobsiteId AND deleted_at IS NULL)
BEGIN
    THROW 50021, 'hr.jobsites id=1 missing. Run 02_jobsites.sql first.', 1;
END;

IF NOT EXISTS (SELECT 1 FROM hr.menus WHERE by_jobsite = @JobsiteId)
BEGIN
    THROW 50022, 'hr.menus empty. Run 10_menus.sql first.', 1;
END;

IF NOT EXISTS (SELECT 1 FROM hr.level_legacy_map WHERE by_jobsite = @JobsiteId)
BEGIN
    THROW 50023, 'hr.level_legacy_map empty. Run 08_level_legacy_map.sql first.', 1;
END;

-- Helper: parse bool-ish strings from dbo.menu_privilege
-- Seed matrix from CSV menu lists (or * = all active menus for that jobsite)
;WITH priv AS (
    SELECT
        mp.id AS legacy_code,
        map.level_id,
        lv.approval_stage,
        LTRIM(RTRIM(ISNULL(mp.menu, N''))) AS menu_csv,
        CASE WHEN LOWER(LTRIM(RTRIM(ISNULL(mp.[read], N'')))) IN (N'true', N'1', N'yes') THEN 1 ELSE 0 END AS can_read,
        CASE WHEN LOWER(LTRIM(RTRIM(ISNULL(mp.[create], N'')))) IN (N'true', N'1', N'yes') THEN 1 ELSE 0 END AS can_insert,
        CASE WHEN LOWER(LTRIM(RTRIM(ISNULL(mp.[update], N'')))) IN (N'true', N'1', N'yes') THEN 1 ELSE 0 END AS can_update,
        CASE WHEN LOWER(LTRIM(RTRIM(ISNULL(mp.[delete], N'')))) IN (N'true', N'1', N'yes') THEN 1 ELSE 0 END AS can_delete,
        CASE WHEN LOWER(LTRIM(RTRIM(ISNULL(mp.[export], N'')))) IN (N'true', N'1', N'yes') THEN 1 ELSE 0 END AS can_export,
        CASE WHEN lv.approval_stage IN (N'superior', N'hr', N'all') THEN 1 ELSE 0 END AS can_approve
    FROM dbo.menu_privilege AS mp
    INNER JOIN hr.level_legacy_map AS map
        ON map.by_jobsite = @JobsiteId
       AND map.legacy_code = mp.id
    INNER JOIN hr.levels AS lv
        ON lv.id = map.level_id
       AND lv.deleted_at IS NULL
    WHERE mp.deleted_at IS NULL
),
-- Expand CSV → legacy menu ids (skip *)
csv_ids AS (
    SELECT
        p.level_id,
        p.can_read,
        p.can_insert,
        p.can_update,
        p.can_delete,
        p.can_export,
        p.can_approve,
        TRY_CAST(LTRIM(RTRIM(s.value)) AS INT) AS legacy_menu_id
    FROM priv AS p
    CROSS APPLY STRING_SPLIT(p.menu_csv, N',') AS s
    WHERE p.menu_csv <> N'*'
      AND LTRIM(RTRIM(s.value)) <> N''
),
star_rows AS (
    SELECT
        p.level_id,
        p.can_read,
        p.can_insert,
        p.can_update,
        p.can_delete,
        p.can_export,
        p.can_approve,
        m.id AS menu_id
    FROM priv AS p
    CROSS JOIN hr.menus AS m
    WHERE p.menu_csv = N'*'
      AND m.by_jobsite = @JobsiteId
      AND m.deleted_at IS NULL
      AND m.is_active = 1
),
csv_rows AS (
    SELECT
        c.level_id,
        c.can_read,
        c.can_insert,
        c.can_update,
        c.can_delete,
        c.can_export,
        c.can_approve,
        m.id AS menu_id
    FROM csv_ids AS c
    INNER JOIN hr.menus AS m
        ON m.by_jobsite = @JobsiteId
       AND m.legacy_id = c.legacy_menu_id
    WHERE c.legacy_menu_id IS NOT NULL
),
seed AS (
    SELECT
        level_id,
        menu_id,
        MAX(can_read) AS can_read,
        MAX(can_insert) AS can_insert,
        MAX(can_update) AS can_update,
        MAX(can_delete) AS can_delete,
        MAX(can_export) AS can_export,
        MAX(can_approve) AS can_approve
    FROM (
        SELECT * FROM star_rows
        UNION ALL
        SELECT * FROM csv_rows
    ) AS raw
    GROUP BY level_id, menu_id
)
INSERT INTO hr.level_permissions (
    by_jobsite,
    level_id,
    menu_id,
    can_read,
    can_insert,
    can_update,
    can_delete,
    can_export,
    can_approve,
    created_by
)
SELECT
    @JobsiteId,
    s.level_id,
    s.menu_id,
    s.can_read,
    s.can_insert,
    s.can_update,
    s.can_delete,
    s.can_export,
    s.can_approve,
    NULL
FROM seed AS s
WHERE NOT EXISTS (
    SELECT 1
    FROM hr.level_permissions AS lp
    WHERE lp.by_jobsite = @JobsiteId
      AND lp.level_id = s.level_id
      AND lp.menu_id = s.menu_id
      AND lp.deleted_at IS NULL
);

PRINT CONCAT('hr.level_permissions rows inserted for jobsite ', @JobsiteId, ': ', @@ROWCOUNT);
GO

-- ---- Verification: HR role menu differentiation (legacy ids 3=SIS, 4=LS) ----
DECLARE @JobsiteId INT = 1;

;WITH hr_codes AS (
    SELECT l.id, l.code
    FROM hr.levels l
    WHERE l.by_jobsite = @JobsiteId
      AND l.deleted_at IS NULL
      AND l.code IN (N'hr_admin', N'hr_admin_ls', N'hr_administrator')
),
flags AS (
    SELECT
        c.code,
        MAX(CASE WHEN m.legacy_id = 3 AND lp.can_read = 1 THEN 1 ELSE 0 END) AS has_sis,
        MAX(CASE WHEN m.legacy_id = 4 AND lp.can_read = 1 THEN 1 ELSE 0 END) AS has_ls,
        COUNT(lp.id) AS menu_count
    FROM hr_codes c
    LEFT JOIN hr.level_permissions lp
        ON lp.level_id = c.id
       AND lp.by_jobsite = @JobsiteId
       AND lp.deleted_at IS NULL
    LEFT JOIN hr.menus m
        ON m.id = lp.menu_id
    GROUP BY c.code
)
SELECT
    code,
    has_sis,
    has_ls,
    menu_count,
    CASE
        WHEN code = N'hr_admin' AND has_sis = 1 AND has_ls = 0 THEN N'OK — SIS only'
        WHEN code = N'hr_admin_ls' AND has_sis = 0 AND has_ls = 1 THEN N'OK — LS only'
        WHEN code = N'hr_administrator' AND has_sis = 1 AND has_ls = 1 THEN N'OK — SIS+LS (full HR)'
        ELSE N'CHECK — unexpected menu breadth'
    END AS differentiation
FROM flags
ORDER BY code;
GO

-- Summary by canonical level
SELECT
    l.code,
    l.approval_stage,
    COUNT(lp.id) AS permission_rows,
    SUM(CASE WHEN lp.can_approve = 1 THEN 1 ELSE 0 END) AS approve_rows
FROM hr.levels l
LEFT JOIN hr.level_permissions lp
    ON lp.level_id = l.id
   AND lp.by_jobsite = 1
   AND lp.deleted_at IS NULL
WHERE l.by_jobsite = 1
  AND l.deleted_at IS NULL
GROUP BY l.code, l.approval_stage, l.sort_order
ORDER BY l.sort_order, l.code;
GO
