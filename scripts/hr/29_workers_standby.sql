-- =============================================
-- Table: hr.workers_standby — standby / unfit periods per worker
-- Source: dbo.workers_standby (legacy MyHR CI)
-- Used by hr.DASHBOARD_SP (UNFIT now, ATTENDANCE later).
-- category → hr.enums.id (336/337 = unfit categories); nrp → hr.workers / hr.workers_vendor.
-- Same ids as dbo (IDENTITY_INSERT in the sync) so both sides stay comparable.
-- Run AFTER 02_jobsites.sql + 16_enums.sql
-- =============================================
IF OBJECT_ID('hr.workers_standby', 'U') IS NULL
BEGIN
    CREATE TABLE hr.workers_standby (
        id INT IDENTITY(1,1) NOT NULL,
        by_jobsite INT NOT NULL,
        ref_id BIGINT NULL,
        key_id NVARCHAR(100) NULL,
        [date] DATE NULL,
        nrp NVARCHAR(40) NULL,
        nrp_int NVARCHAR(50) NULL,
        full_name NVARCHAR(400) NULL,
        category INT NULL,
        start_date DATE NULL,
        end_date DATE NULL,
        path_evident NVARCHAR(MAX) NULL,
        [description] NVARCHAR(MAX) NULL,
        verify NVARCHAR(510) NULL,
        approve NVARCHAR(10) NULL,
        reject NVARCHAR(10) NULL,
        by_verified BIGINT NULL,
        by_user BIGINT NULL,
        created_at DATETIME2 NOT NULL
            CONSTRAINT DF_hr_workers_standby_created_at DEFAULT (SYSUTCDATETIME()),
        created_by INT NULL,
        updated_at DATETIME2 NULL,
        updated_by INT NULL,
        deleted_at DATETIME2 NULL,
        deleted_by INT NULL,
        legacy_id INT NULL,
        CONSTRAINT PK_hr_workers_standby PRIMARY KEY CLUSTERED (id),
        CONSTRAINT FK_hr_workers_standby_jobsite
            FOREIGN KEY (by_jobsite) REFERENCES hr.jobsites (id)
    );

    CREATE INDEX IX_hr_workers_standby_nrp
        ON hr.workers_standby (by_jobsite, nrp)
        INCLUDE (category, start_date, end_date, verify, deleted_at);

    CREATE INDEX IX_hr_workers_standby_period
        ON hr.workers_standby (by_jobsite, start_date, end_date)
        INCLUDE (nrp, category, verify)
        WHERE deleted_at IS NULL;

    CREATE UNIQUE INDEX UQ_hr_workers_standby_legacy_id
        ON hr.workers_standby (legacy_id)
        WHERE legacy_id IS NOT NULL;
END
GO
