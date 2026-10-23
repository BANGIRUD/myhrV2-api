-- =============================================
-- Table: hr.attendance_ratio — per worker per day plan vs actual attendance
-- Source: dbo.achievement_attendance_ratio (legacy MyHR CI; Azure has ~12M rows, refreshed by a cron).
-- Used by hr.DASHBOARD_SP (ATTENDANCE): the dashboard aggregates this table per section
-- instead of recomputing from finger / roster / cuti / sakit tables (which are not in hr).
-- plan / actual codes: D, T, N, OFF, CT, CTN, CTB, CLL, S, I, A, L, STB, TRN.
-- Only a rolling date window is synced (see 34_sync_*.sql): SQL Server Express has a 10 GB cap.
-- Same ids as dbo (IDENTITY_INSERT in the sync). department / section → hr.structure.id.
-- Run AFTER 02_jobsites.sql + 17_structure.sql
-- =============================================
IF OBJECT_ID('hr.attendance_ratio', 'U') IS NULL
BEGIN
    CREATE TABLE hr.attendance_ratio (
        id INT IDENTITY(1,1) NOT NULL,
        by_jobsite INT NOT NULL,
        nrp VARCHAR(25) NULL,
        nrp_int VARCHAR(25) NULL,
        full_name VARCHAR(200) NULL,
        job_rank INT NULL,
        department INT NULL,
        [section] INT NULL,
        [date] DATE NOT NULL,
        finger_in DATETIME NULL,
        finger_out DATETIME NULL,
        actual VARCHAR(25) NULL,
        [plan] VARCHAR(25) NULL,
        [status] VARCHAR(25) NULL,
        by_user BIGINT NULL,
        created_at DATETIME2 NOT NULL
            CONSTRAINT DF_hr_attendance_ratio_created_at DEFAULT (SYSUTCDATETIME()),
        created_by INT NULL,
        updated_at DATETIME2 NULL,
        updated_by INT NULL,
        deleted_at DATETIME2 NULL,
        deleted_by INT NULL,
        legacy_id INT NULL,
        CONSTRAINT PK_hr_attendance_ratio PRIMARY KEY CLUSTERED (id),
        CONSTRAINT FK_hr_attendance_ratio_jobsite
            FOREIGN KEY (by_jobsite) REFERENCES hr.jobsites (id)
    );

    CREATE INDEX IX_hr_attendance_ratio_date_section
        ON hr.attendance_ratio (by_jobsite, [date], [section])
        INCLUDE ([plan], actual, nrp)
        WHERE deleted_at IS NULL;

    CREATE INDEX IX_hr_attendance_ratio_nrp_date
        ON hr.attendance_ratio (by_jobsite, nrp, [date])
        WHERE deleted_at IS NULL;

    CREATE UNIQUE INDEX UQ_hr_attendance_ratio_legacy_id
        ON hr.attendance_ratio (legacy_id)
        WHERE legacy_id IS NOT NULL;
END
GO
