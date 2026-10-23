-- =============================================
-- Table: hr.workers_pola_kerja — work-pattern seed per worker
-- Source: dbo.workers_pola_kerja (legacy MyHR CI menu administrator/pola_kerja)
-- Phase 1: read-only list. Generate roster / CRUD come later.
-- Narrow mirror: full_name is not copied (join hr.v_workers_active by nrp).
-- Only a rolling date window is synced (see 38_sync_*.sql): SQL Server Express has a 10 GB cap.
-- Same ids as dbo (IDENTITY_INSERT in the sync) so both sides stay comparable.
-- Run AFTER 02_jobsites.sql
-- =============================================
IF OBJECT_ID('hr.workers_pola_kerja', 'U') IS NULL
BEGIN
    CREATE TABLE hr.workers_pola_kerja (
        id INT IDENTITY(1,1) NOT NULL,
        by_jobsite INT NOT NULL,
        [date] DATE NULL,
        nrp NVARCHAR(40) NULL,
        nrp_int NVARCHAR(50) NULL,
        pola_kerja NVARCHAR(100) NULL,
        pola_cuti NVARCHAR(100) NULL,
        pola_hari NVARCHAR(100) NULL,
        hari_ke INT NULL,
        remark NVARCHAR(20) NULL,
        by_user BIGINT NULL,
        created_at DATETIME2 NOT NULL
            CONSTRAINT DF_hr_workers_pola_kerja_created_at DEFAULT (SYSUTCDATETIME()),
        created_by INT NULL,
        updated_at DATETIME2 NULL,
        updated_by INT NULL,
        deleted_at DATETIME2 NULL,
        deleted_by INT NULL,
        legacy_id INT NULL,
        CONSTRAINT PK_hr_workers_pola_kerja PRIMARY KEY CLUSTERED (id),
        CONSTRAINT FK_hr_workers_pola_kerja_jobsite
            FOREIGN KEY (by_jobsite) REFERENCES hr.jobsites (id)
    );

    CREATE INDEX IX_hr_workers_pola_kerja_date_nrp
        ON hr.workers_pola_kerja (by_jobsite, [date], nrp)
        INCLUDE (remark, hari_ke, pola_kerja, pola_cuti)
        WHERE deleted_at IS NULL;

    CREATE UNIQUE INDEX UQ_hr_workers_pola_kerja_legacy_id
        ON hr.workers_pola_kerja (legacy_id)
        WHERE legacy_id IS NOT NULL;
END
GO
