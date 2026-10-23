-- =============================================
-- hr.workers_sickness_photos — bukti lampiran for Sakit Reconciliation
-- Mirror of dbo.workers_sickness_photos (+ HR extras: by_jobsite, audit, legacy_id)
-- dbo seed is optional / manual (table can be large). New uploads write here.
-- Run AFTER 52_sakit_sp.sql (needs hr.workers_sickness)
-- =============================================
SET NOCOUNT ON;

IF OBJECT_ID('hr.workers_sickness', 'U') IS NULL
BEGIN
    THROW 50055, 'hr.workers_sickness missing. Apply 35/52 first.', 1;
END;
GO

IF OBJECT_ID('hr.workers_sickness_photos', 'U') IS NULL
BEGIN
    CREATE TABLE hr.workers_sickness_photos (
        id INT IDENTITY(1,1) NOT NULL,
        by_jobsite INT NOT NULL,
        ref_id BIGINT NOT NULL,
        [path] NVARCHAR(250) NOT NULL,
        name NVARCHAR(250) NOT NULL,
        fullpath NVARCHAR(250) NOT NULL,
        [type] NVARCHAR(25) NOT NULL,
        meta_key NVARCHAR(50) NOT NULL,
        meta_values NVARCHAR(MAX) NOT NULL,
        support_attach INT NULL,
        created_at DATETIME2 NOT NULL
            CONSTRAINT DF_hr_workers_sickness_photos_created_at DEFAULT (SYSUTCDATETIME()),
        created_by INT NULL,
        updated_at DATETIME2 NULL,
        updated_by INT NULL,
        deleted_at DATETIME2 NULL,
        deleted_by INT NULL,
        legacy_id INT NULL,
        CONSTRAINT PK_hr_workers_sickness_photos PRIMARY KEY CLUSTERED (id),
        CONSTRAINT FK_hr_workers_sickness_photos_jobsite
            FOREIGN KEY (by_jobsite) REFERENCES hr.jobsites (id)
    );

    CREATE INDEX IX_hr_workers_sickness_photos_ref
        ON hr.workers_sickness_photos (by_jobsite, ref_id)
        WHERE deleted_at IS NULL;

    CREATE UNIQUE INDEX UQ_hr_workers_sickness_photos_legacy_id
        ON hr.workers_sickness_photos (legacy_id)
        WHERE legacy_id IS NOT NULL;

    PRINT 'Created hr.workers_sickness_photos';
END
ELSE
    PRINT 'hr.workers_sickness_photos already exists';
GO
