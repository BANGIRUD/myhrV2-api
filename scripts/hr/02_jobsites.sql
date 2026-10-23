-- =============================================
-- Table: hr.jobsites (site master for multi-site MyHR)
-- Run AFTER 01_schema.sql
-- =============================================
IF OBJECT_ID('hr.jobsites', 'U') IS NULL
BEGIN
    CREATE TABLE hr.jobsites (
        id INT IDENTITY(1,1) NOT NULL,
        code NVARCHAR(30) NOT NULL,
        name NVARCHAR(150) NOT NULL,
        description NVARCHAR(255) NULL,
        is_active BIT NOT NULL
            CONSTRAINT DF_hr_jobsites_is_active DEFAULT (1),
        created_at DATETIME2 NOT NULL
            CONSTRAINT DF_hr_jobsites_created_at DEFAULT (SYSUTCDATETIME()),
        created_by INT NULL,
        updated_at DATETIME2 NULL,
        updated_by INT NULL,
        deleted_at DATETIME2 NULL,
        deleted_by INT NULL,
        CONSTRAINT PK_hr_jobsites PRIMARY KEY CLUSTERED (id)
    );

    CREATE UNIQUE INDEX UQ_hr_jobsites_code_active
        ON hr.jobsites (code)
        WHERE deleted_at IS NULL;
END
GO

-- Default site for legacy dbo migration (id will be 1 on empty table)
IF NOT EXISTS (
    SELECT 1 FROM hr.jobsites WHERE code = N'DEFAULT' AND deleted_at IS NULL
)
BEGIN
    SET IDENTITY_INSERT hr.jobsites ON;
    INSERT INTO hr.jobsites (id, code, name, description, is_active, created_by)
    VALUES (1, N'DEFAULT', N'Default Jobsite', N'Seed site for dbo → hr migration', 1, NULL);
    SET IDENTITY_INSERT hr.jobsites OFF;
END
GO
