-- =============================================
-- Expand hr.workers_finger_error (ALTER only) + photos table
-- Run AFTER 35_attendance_sources.sql. Do NOT DROP/recreate workers_finger_error.
-- Category = hr.enums id (type workers_fingerprint), matching dbo / legacy.
-- =============================================

IF OBJECT_ID('hr.workers_finger_error', 'U') IS NULL
BEGIN
    THROW 50080, 'hr.workers_finger_error missing. Apply 35_attendance_sources.sql first.', 1;
END;
GO

IF COL_LENGTH('hr.workers_finger_error', 'ref_id') IS NULL
    ALTER TABLE hr.workers_finger_error ADD ref_id BIGINT NULL;
IF COL_LENGTH('hr.workers_finger_error', 'key_id') IS NULL
    ALTER TABLE hr.workers_finger_error ADD key_id NVARCHAR(50) NULL;
IF COL_LENGTH('hr.workers_finger_error', 'nrp_int') IS NULL
    ALTER TABLE hr.workers_finger_error ADD nrp_int NVARCHAR(25) NULL;
IF COL_LENGTH('hr.workers_finger_error', 'full_name') IS NULL
    ALTER TABLE hr.workers_finger_error ADD full_name NVARCHAR(200) NULL;
IF COL_LENGTH('hr.workers_finger_error', 'location') IS NULL
    ALTER TABLE hr.workers_finger_error ADD location NVARCHAR(200) NULL;
IF COL_LENGTH('hr.workers_finger_error', 'category') IS NULL
    ALTER TABLE hr.workers_finger_error ADD category INT NULL;
IF COL_LENGTH('hr.workers_finger_error', 'shift') IS NULL
    ALTER TABLE hr.workers_finger_error ADD shift NVARCHAR(10) NULL;
IF COL_LENGTH('hr.workers_finger_error', 'remark') IS NULL
    ALTER TABLE hr.workers_finger_error ADD remark NVARCHAR(10) NULL;
IF COL_LENGTH('hr.workers_finger_error', 'path_evident') IS NULL
    ALTER TABLE hr.workers_finger_error ADD path_evident NVARCHAR(MAX) NULL;
IF COL_LENGTH('hr.workers_finger_error', 'description') IS NULL
    ALTER TABLE hr.workers_finger_error ADD description NVARCHAR(MAX) NULL;
IF COL_LENGTH('hr.workers_finger_error', 'note') IS NULL
    ALTER TABLE hr.workers_finger_error ADD note NVARCHAR(MAX) NULL;
IF COL_LENGTH('hr.workers_finger_error', 'approve') IS NULL
    ALTER TABLE hr.workers_finger_error ADD approve NVARCHAR(5) NULL;
IF COL_LENGTH('hr.workers_finger_error', 'reject') IS NULL
    ALTER TABLE hr.workers_finger_error ADD reject NVARCHAR(5) NULL;
IF COL_LENGTH('hr.workers_finger_error', 'by_verified') IS NULL
    ALTER TABLE hr.workers_finger_error ADD by_verified BIGINT NULL;
IF COL_LENGTH('hr.workers_finger_error', 'by_user') IS NULL
    ALTER TABLE hr.workers_finger_error ADD by_user BIGINT NULL;
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE name = N'IX_hr_workers_finger_error_ref'
      AND object_id = OBJECT_ID(N'hr.workers_finger_error')
)
BEGIN
    CREATE INDEX IX_hr_workers_finger_error_ref
        ON hr.workers_finger_error (by_jobsite, ref_id)
        INCLUDE (nrp, [date], verify)
        WHERE deleted_at IS NULL;
END;
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE name = N'IX_hr_workers_finger_error_parent_date'
      AND object_id = OBJECT_ID(N'hr.workers_finger_error')
)
BEGIN
    CREATE INDEX IX_hr_workers_finger_error_parent_date
        ON hr.workers_finger_error (by_jobsite, [date])
        INCLUDE (nrp, finger_in, finger_out, verify)
        WHERE deleted_at IS NULL AND ref_id IS NULL;
END;
GO

IF OBJECT_ID('hr.workers_finger_error_photos', 'U') IS NULL
BEGIN
    CREATE TABLE hr.workers_finger_error_photos (
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
            CONSTRAINT DF_hr_workers_finger_error_photos_created_at DEFAULT (SYSUTCDATETIME()),
        created_by INT NULL,
        updated_at DATETIME2 NULL,
        updated_by INT NULL,
        deleted_at DATETIME2 NULL,
        deleted_by INT NULL,
        legacy_id INT NULL,
        CONSTRAINT PK_hr_workers_finger_error_photos PRIMARY KEY CLUSTERED (id),
        CONSTRAINT FK_hr_workers_finger_error_photos_jobsite
            FOREIGN KEY (by_jobsite) REFERENCES hr.jobsites (id)
    );

    CREATE INDEX IX_hr_workers_finger_error_photos_ref
        ON hr.workers_finger_error_photos (by_jobsite, ref_id)
        WHERE deleted_at IS NULL;

    CREATE UNIQUE INDEX UQ_hr_workers_finger_error_photos_legacy_id
        ON hr.workers_finger_error_photos (legacy_id)
        WHERE legacy_id IS NOT NULL;

    PRINT 'Created hr.workers_finger_error_photos';
END
ELSE
    PRINT 'hr.workers_finger_error_photos already exists';
GO
