-- =============================================
-- Table: hr.menus — catalog (seed from dbo.menu)
-- Replaces CSV id lists in menu_privilege as the menu source of truth.
-- by_jobsite scopes menus per site; legacy_id preserves dbo.menu.id for ETL.
-- Run AFTER 02_jobsites.sql
-- =============================================
IF OBJECT_ID('hr.menus', 'U') IS NULL
BEGIN
    CREATE TABLE hr.menus (
        id INT IDENTITY(1,1) NOT NULL,
        by_jobsite INT NOT NULL,
        legacy_id INT NULL,                 -- dbo.menu.id
        legacy_ref_id BIGINT NULL,          -- dbo.menu.ref_id (pre-remap)
        menu_code NVARCHAR(100) NOT NULL,
        menu_name NVARCHAR(150) NOT NULL,
        menu_url NVARCHAR(500) NULL,
        icon NVARCHAR(100) NULL,
        menu_type NVARCHAR(50) NULL,        -- parents | children | divider
        parent_id INT NULL,                -- FK hr.menus.id (resolved after seed)
        sort_order INT NOT NULL
            CONSTRAINT DF_hr_menus_sort_order DEFAULT (0),
        show_sidebar BIT NOT NULL
            CONSTRAINT DF_hr_menus_show_sidebar DEFAULT (1),
        is_active BIT NOT NULL
            CONSTRAINT DF_hr_menus_is_active DEFAULT (1),
        description NVARCHAR(255) NULL,
        created_at DATETIME2 NOT NULL
            CONSTRAINT DF_hr_menus_created_at DEFAULT (SYSUTCDATETIME()),
        created_by INT NULL,
        updated_at DATETIME2 NULL,
        updated_by INT NULL,
        deleted_at DATETIME2 NULL,
        deleted_by INT NULL,
        CONSTRAINT PK_hr_menus PRIMARY KEY CLUSTERED (id),
        CONSTRAINT FK_hr_menus_jobsite
            FOREIGN KEY (by_jobsite) REFERENCES hr.jobsites (id)
    );

    CREATE UNIQUE INDEX UQ_hr_menus_code_jobsite_active
        ON hr.menus (by_jobsite, menu_code)
        WHERE deleted_at IS NULL;

    CREATE UNIQUE INDEX UQ_hr_menus_legacy_jobsite
        ON hr.menus (by_jobsite, legacy_id)
        WHERE legacy_id IS NOT NULL AND deleted_at IS NULL;

    CREATE INDEX IX_hr_menus_parent
        ON hr.menus (by_jobsite, parent_id)
        WHERE deleted_at IS NULL;
END
GO

-- Self-FK for parent (idempotent)
IF NOT EXISTS (
    SELECT 1 FROM sys.foreign_keys WHERE name = N'FK_hr_menus_parent'
)
BEGIN
    ALTER TABLE hr.menus
        ADD CONSTRAINT FK_hr_menus_parent
        FOREIGN KEY (parent_id) REFERENCES hr.menus (id);
END
GO

-- ---- Seed from dbo.menu (DEFAULT jobsite = 1) ----
DECLARE @JobsiteId INT = 1;

IF NOT EXISTS (SELECT 1 FROM hr.jobsites WHERE id = @JobsiteId AND deleted_at IS NULL)
BEGIN
    THROW 50020, 'hr.jobsites id=1 missing. Run 02_jobsites.sql first.', 1;
END;

INSERT INTO hr.menus (
    by_jobsite,
    legacy_id,
    legacy_ref_id,
    menu_code,
    menu_name,
    menu_url,
    icon,
    menu_type,
    sort_order,
    show_sidebar,
    is_active,
    description,
    created_at,
    updated_at,
    deleted_at,
    created_by
)
SELECT
    @JobsiteId,
    src.id,
    CASE WHEN src.ref_id IS NULL OR src.ref_id = 0 THEN NULL ELSE src.ref_id END,
    CONCAT(N'menu_', CAST(src.id AS NVARCHAR(20))),
    src.title,
    NULLIF(LTRIM(RTRIM(src.url)), N''),
    NULLIF(LTRIM(RTRIM(src.icon)), N''),
    NULLIF(LTRIM(RTRIM(src.type)), N''),
    ISNULL(src.[order], 0),
    CASE WHEN LOWER(ISNULL(src.type, N'')) = N'divider' THEN 0 ELSE 1 END,
    CASE WHEN src.deleted_at IS NULL THEN 1 ELSE 0 END,
    NULLIF(LTRIM(RTRIM(src.description)), N''),
    ISNULL(src.created_at, SYSUTCDATETIME()),
    src.updated_at,
    src.deleted_at, NULL
FROM dbo.menu AS src
WHERE NOT EXISTS (
    SELECT 1
    FROM hr.menus AS dst
    WHERE dst.by_jobsite = @JobsiteId
      AND dst.legacy_id = src.id
);

PRINT CONCAT('hr.menus rows for jobsite ', @JobsiteId, ' inserted: ', @@ROWCOUNT);
GO

-- Resolve parent_id from legacy_ref_id → sibling legacy_id
UPDATE child
SET child.parent_id = parent.id,
    child.updated_at = SYSUTCDATETIME(),
    child.updated_by = NULL
FROM hr.menus AS child
INNER JOIN hr.menus AS parent
    ON parent.by_jobsite = child.by_jobsite
   AND parent.legacy_id = child.legacy_ref_id
   AND parent.deleted_at IS NULL
WHERE child.legacy_ref_id IS NOT NULL
  AND (child.parent_id IS NULL OR child.parent_id <> parent.id);
GO
