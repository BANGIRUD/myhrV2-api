-- =============================================
-- Expand hr.workers_permit to match dbo.workers_permit (Azure)
-- + hr.workers_permit_photos + hr.ijin_department_exception
-- Run AFTER 35_attendance_sources.sql. ALTER only — do not recreate the table.
-- =============================================

IF OBJECT_ID('hr.workers_permit', 'U') IS NULL
BEGIN
    THROW 50070, 'hr.workers_permit missing. Apply 35_attendance_sources.sql first.', 1;
END;
GO

IF COL_LENGTH('hr.workers_permit', 'ref_id') IS NULL
    ALTER TABLE hr.workers_permit ADD ref_id BIGINT NULL;
IF COL_LENGTH('hr.workers_permit', 'key_id') IS NULL
    ALTER TABLE hr.workers_permit ADD key_id NVARCHAR(50) NULL;
IF COL_LENGTH('hr.workers_permit', 'date') IS NULL
    ALTER TABLE hr.workers_permit ADD [date] DATE NULL;
IF COL_LENGTH('hr.workers_permit', 'nrp_int') IS NULL
    ALTER TABLE hr.workers_permit ADD nrp_int NVARCHAR(25) NULL;
IF COL_LENGTH('hr.workers_permit', 'full_name') IS NULL
    ALTER TABLE hr.workers_permit ADD full_name NVARCHAR(200) NULL;
IF COL_LENGTH('hr.workers_permit', 'category') IS NULL
    ALTER TABLE hr.workers_permit ADD category INT NULL;
IF COL_LENGTH('hr.workers_permit', 'day') IS NULL
    ALTER TABLE hr.workers_permit ADD [day] INT NULL;
IF COL_LENGTH('hr.workers_permit', 'path_evident') IS NULL
    ALTER TABLE hr.workers_permit ADD path_evident NVARCHAR(MAX) NULL;
IF COL_LENGTH('hr.workers_permit', 'description') IS NULL
    ALTER TABLE hr.workers_permit ADD description NVARCHAR(MAX) NULL;
IF COL_LENGTH('hr.workers_permit', 'note') IS NULL
    ALTER TABLE hr.workers_permit ADD note NVARCHAR(MAX) NULL;
IF COL_LENGTH('hr.workers_permit', 'approve') IS NULL
    ALTER TABLE hr.workers_permit ADD approve NVARCHAR(5) NULL;
IF COL_LENGTH('hr.workers_permit', 'reject') IS NULL
    ALTER TABLE hr.workers_permit ADD reject NVARCHAR(5) NULL;
IF COL_LENGTH('hr.workers_permit', 'by_verified') IS NULL
    ALTER TABLE hr.workers_permit ADD by_verified BIGINT NULL;
IF COL_LENGTH('hr.workers_permit', 'by_user') IS NULL
    ALTER TABLE hr.workers_permit ADD by_user BIGINT NULL;
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE name = N'IX_hr_workers_permit_ref'
      AND object_id = OBJECT_ID(N'hr.workers_permit')
)
BEGIN
    CREATE INDEX IX_hr_workers_permit_ref
        ON hr.workers_permit (by_jobsite, ref_id)
        INCLUDE (nrp, start_date, end_date, verify)
        WHERE deleted_at IS NULL;
END;
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE name = N'IX_hr_workers_permit_parent_start'
      AND object_id = OBJECT_ID(N'hr.workers_permit')
)
BEGIN
    CREATE INDEX IX_hr_workers_permit_parent_start
        ON hr.workers_permit (by_jobsite, start_date)
        INCLUDE (end_date, nrp)
        WHERE deleted_at IS NULL AND ref_id IS NULL;
END;
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE name = N'IX_hr_workers_permit_parent_end'
      AND object_id = OBJECT_ID(N'hr.workers_permit')
)
BEGIN
    CREATE INDEX IX_hr_workers_permit_parent_end
        ON hr.workers_permit (by_jobsite, end_date)
        INCLUDE (start_date, nrp)
        WHERE deleted_at IS NULL AND ref_id IS NULL AND end_date IS NOT NULL;
END;
GO

IF OBJECT_ID('hr.workers_permit_photos', 'U') IS NULL
BEGIN
    CREATE TABLE hr.workers_permit_photos (
        id INT IDENTITY(1,1) NOT NULL,
        by_jobsite INT NOT NULL,
        ref_id BIGINT NOT NULL,
        [path] NVARCHAR(250) NOT NULL,
        name NVARCHAR(250) NOT NULL,
        fullpath NVARCHAR(250) NOT NULL,
        [type] NVARCHAR(25) NOT NULL,
        meta_key NVARCHAR(50) NOT NULL,
        meta_values NVARCHAR(MAX) NOT NULL,
        created_at DATETIME2 NOT NULL
            CONSTRAINT DF_hr_workers_permit_photos_created_at DEFAULT (SYSUTCDATETIME()),
        created_by INT NULL,
        updated_at DATETIME2 NULL,
        updated_by INT NULL,
        deleted_at DATETIME2 NULL,
        deleted_by INT NULL,
        legacy_id INT NULL,
        CONSTRAINT PK_hr_workers_permit_photos PRIMARY KEY CLUSTERED (id),
        CONSTRAINT FK_hr_workers_permit_photos_jobsite
            FOREIGN KEY (by_jobsite) REFERENCES hr.jobsites (id)
    );

    CREATE INDEX IX_hr_workers_permit_photos_ref
        ON hr.workers_permit_photos (by_jobsite, ref_id)
        WHERE deleted_at IS NULL;

    CREATE UNIQUE INDEX UQ_hr_workers_permit_photos_legacy_id
        ON hr.workers_permit_photos (legacy_id)
        WHERE legacy_id IS NOT NULL;
END;
GO

IF OBJECT_ID(N'hr.ijin_department_exception', N'U') IS NULL
BEGIN
    CREATE TABLE hr.ijin_department_exception (
        id INT IDENTITY(1,1) NOT NULL,
        by_jobsite INT NOT NULL,
        section_id INT NOT NULL,
        job_rank INT NOT NULL,
        created_at DATETIME2 NOT NULL
            CONSTRAINT DF_hr_ijin_dept_exc_created DEFAULT (SYSUTCDATETIME()),
        created_by INT NULL,
        updated_at DATETIME2 NULL,
        updated_by INT NULL,
        deleted_at DATETIME2 NULL,
        deleted_by INT NULL,
        CONSTRAINT PK_hr_ijin_department_exception PRIMARY KEY CLUSTERED (id)
    );

    CREATE UNIQUE INDEX UQ_hr_ijin_dept_exc
        ON hr.ijin_department_exception (by_jobsite, section_id, job_rank)
        WHERE deleted_at IS NULL;
END;
GO

DECLARE @JobsiteId INT = 1;
DECLARE @AdminRank INT = (
    SELECT TOP 1 id FROM hr.enums
    WHERE by_jobsite = @JobsiteId AND deleted_at IS NULL
      AND type = N'position' AND id = 10
);
DECLARE @UhRank INT = (
    SELECT TOP 1 id FROM hr.enums
    WHERE by_jobsite = @JobsiteId AND deleted_at IS NULL
      AND type = N'position' AND id = 4
);
DECLARE @GlRank INT = (
    SELECT TOP 1 id FROM hr.enums
    WHERE by_jobsite = @JobsiteId AND deleted_at IS NULL
      AND type = N'position' AND id = 5
);

INSERT INTO hr.ijin_department_exception (by_jobsite, section_id, job_rank, created_by)
SELECT @JobsiteId, v.section_id, v.job_rank, NULL
FROM (VALUES
    (1, @AdminRank),
    (78, @UhRank),
    (13, @UhRank),
    (13, @GlRank)
) v(section_id, job_rank)
WHERE v.job_rank IS NOT NULL
  AND EXISTS (
      SELECT 1 FROM hr.structure s
      WHERE s.id = v.section_id AND s.by_jobsite = @JobsiteId AND s.deleted_at IS NULL
  )
  AND NOT EXISTS (
      SELECT 1 FROM hr.ijin_department_exception x
      WHERE x.by_jobsite = @JobsiteId
        AND x.section_id = v.section_id
        AND x.job_rank = v.job_rank
        AND x.deleted_at IS NULL
  );
GO
