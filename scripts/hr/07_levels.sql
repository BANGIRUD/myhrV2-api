-- =============================================
-- Table: hr.levels — canonical role catalog (MyHR approval stages)
-- Run AFTER 02_jobsites.sql (jobsite FK optional; levels are global per site copy)
--
-- approval_stage:
--   submit   = admin section (input pengajuan)
--   superior = GL / SH / DH (approve atasan, structure-scoped)
--   hr       = HR admin / HR administrator (approve final personalia)
--   all      = superadmin / administrator / management (no structure filter)
--   none     = employee / special roles without approve pipeline
--
-- NOTE: this file seeds the original 15-level catalog. 27_levels_consolidate.sql
-- merges it into 10 canonical levels (administrator -> management,
-- hr_admin_ls -> hr_admin, irel/meals/safety/attendance -> module_admin) and
-- retires the merged codes. Re-running 07 re-creates them empty; 27 removes them again.
-- =============================================
IF OBJECT_ID('hr.levels', 'U') IS NULL
BEGIN
    CREATE TABLE hr.levels (
        id INT IDENTITY(1,1) NOT NULL,
        by_jobsite INT NOT NULL,
        code NVARCHAR(50) NOT NULL,
        name NVARCHAR(100) NOT NULL,
        description NVARCHAR(255) NULL,
        approval_stage NVARCHAR(20) NOT NULL
            CONSTRAINT DF_hr_levels_approval_stage DEFAULT (N'none'),
        structure_scoped BIT NOT NULL
            CONSTRAINT DF_hr_levels_structure_scoped DEFAULT (0),
        sort_order INT NOT NULL
            CONSTRAINT DF_hr_levels_sort_order DEFAULT (100),
        is_active BIT NOT NULL
            CONSTRAINT DF_hr_levels_is_active DEFAULT (1),
        created_at DATETIME2 NOT NULL
            CONSTRAINT DF_hr_levels_created_at DEFAULT (SYSUTCDATETIME()),
        created_by INT NULL,
        updated_at DATETIME2 NULL,
        updated_by INT NULL,
        deleted_at DATETIME2 NULL,
        deleted_by INT NULL,
        CONSTRAINT PK_hr_levels PRIMARY KEY CLUSTERED (id),
        CONSTRAINT FK_hr_levels_jobsite
            FOREIGN KEY (by_jobsite) REFERENCES hr.jobsites (id),
        CONSTRAINT CK_hr_levels_approval_stage
            CHECK (approval_stage IN (N'submit', N'superior', N'hr', N'all', N'none'))
    );

    CREATE UNIQUE INDEX UQ_hr_levels_code_jobsite_active
        ON hr.levels (by_jobsite, code)
        WHERE deleted_at IS NULL;
END
GO

-- Seed DEFAULT jobsite (id = 1)
DECLARE @JobsiteId INT = 1;

IF NOT EXISTS (SELECT 1 FROM hr.jobsites WHERE id = @JobsiteId AND deleted_at IS NULL)
BEGIN
    THROW 50010, 'hr.jobsites id=1 missing. Run 02_jobsites.sql first.', 1;
END;

;WITH seed AS (
    SELECT * FROM (VALUES
        -- Stage 1: input
        (N'admin_section',     N'Admin Section',      N'Input pengajuan (legacy: admin)',                    N'submit',   1, 10),
        -- Stage 2: approve atasan
        (N'group_leader',      N'Group Leader',       N'Approve atasan — group leader',                     N'superior', 1, 20),
        (N'section_head',      N'Section Head',       N'Approve atasan — section head',                     N'superior', 1, 30),
        (N'department_head',   N'Department Head',    N'Approve atasan — department head',                  N'superior', 1, 40),
        -- Stage 3: HR (same approve authority; menu breadth differs)
        (N'hr_admin',          N'HR Admin',           N'Admin operasional HR (legacy: admin_hr)',            N'hr',       0, 50),
        (N'hr_admin_ls',       N'HR Admin LS',        N'Admin HR Labour Supply (legacy: admin_hr(LS))',      N'hr',       0, 55),
        (N'hr_administrator',  N'HR Administrator',   N'Atasan HR — akses penuh domain HR (legacy: administrator_hr)', N'hr', 0, 60),
        -- All-access
        (N'superadmin',        N'Super Admin',        N'Akses penuh sistem',                                N'all',      0, 1),
        (N'administrator',     N'Administrator',      N'Akses penuh operasional',                           N'all',      0, 2),
        (N'management',        N'Management',         N'Akses lihat semua tanpa batasan struktur',          N'all',      0, 3),
        -- Outside main pipeline
        (N'employee',          N'Employee',           N'User biasa (legacy: user)',                         N'none',     1, 90),
        (N'irel',              N'Industrial Relation',N'Role khusus IREL',                                  N'none',     0, 91),
        (N'meals',             N'Meals Admin',        N'Role khusus meals (legacy: admin_meals)',            N'none',     0, 92),
        (N'safety',            N'Safety Admin',       N'Role khusus safety (legacy: admin_safety)',         N'none',     0, 93),
        (N'attendance',        N'Attendance',         N'Role finger / attendance (legacy: finger*)',        N'none',     0, 94)
    ) AS v(code, name, description, approval_stage, structure_scoped, sort_order)
)
INSERT INTO hr.levels (
    by_jobsite, code, name, description, approval_stage, structure_scoped, sort_order, created_by
)
SELECT
    @JobsiteId, s.code, s.name, s.description, s.approval_stage, s.structure_scoped, s.sort_order, NULL
FROM seed s
WHERE NOT EXISTS (
    SELECT 1 FROM hr.levels l
    WHERE l.by_jobsite = @JobsiteId
      AND l.code = s.code
      AND l.deleted_at IS NULL
);
GO
