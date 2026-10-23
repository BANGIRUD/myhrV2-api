-- =============================================
-- Table: hr.level_legacy_map — map dbo.users.level / menu_privilege.id → hr.levels
-- Run AFTER 07_levels.sql
-- =============================================
IF OBJECT_ID('hr.level_legacy_map', 'U') IS NULL
BEGIN
    CREATE TABLE hr.level_legacy_map (
        id INT IDENTITY(1,1) NOT NULL,
        by_jobsite INT NOT NULL,
        legacy_code NVARCHAR(50) NOT NULL,
        level_id INT NOT NULL,
        notes NVARCHAR(255) NULL,
        created_at DATETIME2 NOT NULL
            CONSTRAINT DF_hr_level_legacy_map_created_at DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT PK_hr_level_legacy_map PRIMARY KEY CLUSTERED (id),
        CONSTRAINT FK_hr_level_legacy_map_jobsite
            FOREIGN KEY (by_jobsite) REFERENCES hr.jobsites (id),
        CONSTRAINT FK_hr_level_legacy_map_level
            FOREIGN KEY (level_id) REFERENCES hr.levels (id),
        CONSTRAINT UQ_hr_level_legacy_map UNIQUE (by_jobsite, legacy_code)
    );
END
GO

-- User attributes implied by a legacy code (see 27_levels_consolidate.sql):
--   worker_scope = sis | ls | all   (HR data scope)
--   module       = irel | meals | safety | attendance   (module_admin)
IF COL_LENGTH('hr.level_legacy_map', 'worker_scope') IS NULL
    ALTER TABLE hr.level_legacy_map ADD worker_scope NVARCHAR(10) NULL;
GO

IF COL_LENGTH('hr.level_legacy_map', 'module') IS NULL
    ALTER TABLE hr.level_legacy_map ADD module NVARCHAR(30) NULL;
GO

DECLARE @JobsiteId INT = 1;

;WITH map AS (
    SELECT * FROM (VALUES
        (N'admin',              N'admin_section',    N'Rename semantik: inputer section'),
        (N'group_leader',       N'group_leader',     NULL),
        (N'section_head',       N'section_head',     NULL),
        (N'department_head',    N'department_head',  NULL),
        (N'admin_hr',           N'hr_admin',         N'HR operasional'),
        (N'admin_hr(LS)',       N'hr_admin_ls',      N'HR operasional LS — beda menu saja'),
        (N'administrator_hr',   N'hr_administrator', N'Atasan HR'),
        (N'superadmin',         N'superadmin',       NULL),
        (N'administrator',      N'administrator',    NULL),
        (N'management',         N'management',       NULL),
        (N'user',               N'employee',         N'Rename: user → employee'),
        (N'irel',               N'irel',             NULL),
        (N'admin_meals',        N'meals',            NULL),
        (N'admin_safety',       N'safety',           NULL),
        (N'finger_check',       N'attendance',       NULL),
        (N'finger',             N'attendance',       N'Katalog privilege tanpa user aktif'),
        (N'admin_irel',         N'irel',             N'Katalog privilege tanpa user aktif')
    ) AS v(legacy_code, level_code, notes)
)
INSERT INTO hr.level_legacy_map (by_jobsite, legacy_code, level_id, notes)
SELECT
    @JobsiteId,
    m.legacy_code,
    l.id,
    m.notes
FROM map m
INNER JOIN hr.levels l
    ON l.by_jobsite = @JobsiteId
   AND l.code = m.level_code
   AND l.deleted_at IS NULL
WHERE NOT EXISTS (
    SELECT 1 FROM hr.level_legacy_map x
    WHERE x.by_jobsite = @JobsiteId
      AND x.legacy_code = m.legacy_code
);
GO
