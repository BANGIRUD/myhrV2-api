-- =============================================
-- Source tables for the ATTENDANCE computation inside hr.DASHBOARD_SP
-- (replaces the dbo functions fv_workers_travel / cuti_period / sickness / permit /
--  cuti_kerja / v_workers_finger / date_holiday used by dbo.fv_achievement_attendance_ratio).
-- Narrow mirrors of the dbo tables: only the columns the computation reads, same ids as dbo
-- (IDENTITY_INSERT in the sync) so hr and dbo stay row-for-row comparable.
-- Filled by: node scripts/hr/seed_attendance_from_azure.js  (Azure read-only -> dbo -> hr)
-- Already in hr: hr.workers_roster_kerja (31_), hr.workers_standby (29_), hr.v_workers_active (23_),
--                hr.enums, hr.structure.
-- Run AFTER 02_jobsites.sql
-- =============================================

-- ---- travel (code T) ----
IF OBJECT_ID('hr.workers_travel', 'U') IS NULL
BEGIN
    CREATE TABLE hr.workers_travel (
        id INT IDENTITY(1,1) NOT NULL,
        by_jobsite INT NOT NULL,
        nrp NVARCHAR(40) NULL,
        start_date DATE NULL,
        end_date DATE NULL,
        verify NVARCHAR(510) NULL,
        created_at DATETIME2 NOT NULL CONSTRAINT DF_hr_workers_travel_created_at DEFAULT (SYSUTCDATETIME()),
        created_by INT NULL, updated_at DATETIME2 NULL, updated_by INT NULL,
        deleted_at DATETIME2 NULL, deleted_by INT NULL, legacy_id INT NULL,
        CONSTRAINT PK_hr_workers_travel PRIMARY KEY CLUSTERED (id),
        CONSTRAINT FK_hr_workers_travel_jobsite FOREIGN KEY (by_jobsite) REFERENCES hr.jobsites (id)
    );
    CREATE INDEX IX_hr_workers_travel_period ON hr.workers_travel (by_jobsite, start_date, end_date)
        INCLUDE (nrp, verify) WHERE deleted_at IS NULL;
    CREATE UNIQUE INDEX UQ_hr_workers_travel_legacy_id ON hr.workers_travel (legacy_id) WHERE legacy_id IS NOT NULL;
END
GO

-- ---- cuti period master (code CT) ----
IF OBJECT_ID('hr.workers_cuti_period_master', 'U') IS NULL
BEGIN
    CREATE TABLE hr.workers_cuti_period_master (
        id INT IDENTITY(1,1) NOT NULL,
        by_jobsite INT NOT NULL,
        nrp NVARCHAR(40) NULL,
        start_date DATE NULL,
        end_date DATE NULL,
        periode INT NULL,
        created_at DATETIME2 NOT NULL CONSTRAINT DF_hr_workers_cuti_period_master_created_at DEFAULT (SYSUTCDATETIME()),
        created_by INT NULL, updated_at DATETIME2 NULL, updated_by INT NULL,
        deleted_at DATETIME2 NULL, deleted_by INT NULL, legacy_id INT NULL,
        CONSTRAINT PK_hr_workers_cuti_period_master PRIMARY KEY CLUSTERED (id),
        CONSTRAINT FK_hr_workers_cuti_period_master_jobsite FOREIGN KEY (by_jobsite) REFERENCES hr.jobsites (id)
    );
    CREATE INDEX IX_hr_workers_cuti_period_master_period ON hr.workers_cuti_period_master (by_jobsite, start_date, end_date)
        INCLUDE (nrp) WHERE deleted_at IS NULL;
    CREATE UNIQUE INDEX UQ_hr_workers_cuti_period_master_legacy_id ON hr.workers_cuti_period_master (legacy_id) WHERE legacy_id IS NOT NULL;
END
GO

-- ---- cuti period (override dates of a master row, joined on periode = master.id) ----
IF OBJECT_ID('hr.workers_cuti_period', 'U') IS NULL
BEGIN
    CREATE TABLE hr.workers_cuti_period (
        id INT IDENTITY(1,1) NOT NULL,
        by_jobsite INT NOT NULL,
        periode INT NULL,
        start_date DATE NULL,
        end_date DATE NULL,
        verify NVARCHAR(510) NULL,
        created_at DATETIME2 NOT NULL CONSTRAINT DF_hr_workers_cuti_period_created_at DEFAULT (SYSUTCDATETIME()),
        created_by INT NULL, updated_at DATETIME2 NULL, updated_by INT NULL,
        deleted_at DATETIME2 NULL, deleted_by INT NULL, legacy_id INT NULL,
        CONSTRAINT PK_hr_workers_cuti_period PRIMARY KEY CLUSTERED (id),
        CONSTRAINT FK_hr_workers_cuti_period_jobsite FOREIGN KEY (by_jobsite) REFERENCES hr.jobsites (id)
    );
    CREATE INDEX IX_hr_workers_cuti_period_periode ON hr.workers_cuti_period (by_jobsite, periode)
        INCLUDE (start_date, end_date, verify) WHERE deleted_at IS NULL;
    CREATE UNIQUE INDEX UQ_hr_workers_cuti_period_legacy_id ON hr.workers_cuti_period (legacy_id) WHERE legacy_id IS NOT NULL;
END
GO

-- ---- sickness (code S; latest row per ref_id wins, open end = end of current month) ----
IF OBJECT_ID('hr.workers_sickness', 'U') IS NULL
BEGIN
    CREATE TABLE hr.workers_sickness (
        id INT IDENTITY(1,1) NOT NULL,
        by_jobsite INT NOT NULL,
        ref_id BIGINT NULL,
        nrp NVARCHAR(40) NULL,
        start_date DATE NULL,
        end_date DATE NULL,
        verify NVARCHAR(510) NULL,
        created_at DATETIME2 NOT NULL CONSTRAINT DF_hr_workers_sickness_created_at DEFAULT (SYSUTCDATETIME()),
        created_by INT NULL, updated_at DATETIME2 NULL, updated_by INT NULL,
        deleted_at DATETIME2 NULL, deleted_by INT NULL, legacy_id INT NULL,
        CONSTRAINT PK_hr_workers_sickness PRIMARY KEY CLUSTERED (id),
        CONSTRAINT FK_hr_workers_sickness_jobsite FOREIGN KEY (by_jobsite) REFERENCES hr.jobsites (id)
    );
    CREATE INDEX IX_hr_workers_sickness_ref ON hr.workers_sickness (by_jobsite, ref_id)
        INCLUDE (nrp, start_date, end_date, verify) WHERE deleted_at IS NULL;
    CREATE UNIQUE INDEX UQ_hr_workers_sickness_legacy_id ON hr.workers_sickness (legacy_id) WHERE legacy_id IS NOT NULL;
END
GO

-- ---- permit / izin (code I) ----
IF OBJECT_ID('hr.workers_permit', 'U') IS NULL
BEGIN
    CREATE TABLE hr.workers_permit (
        id INT IDENTITY(1,1) NOT NULL,
        by_jobsite INT NOT NULL,
        nrp NVARCHAR(40) NULL,
        start_date DATE NULL,
        end_date DATE NULL,
        verify NVARCHAR(510) NULL,
        created_at DATETIME2 NOT NULL CONSTRAINT DF_hr_workers_permit_created_at DEFAULT (SYSUTCDATETIME()),
        created_by INT NULL, updated_at DATETIME2 NULL, updated_by INT NULL,
        deleted_at DATETIME2 NULL, deleted_by INT NULL, legacy_id INT NULL,
        CONSTRAINT PK_hr_workers_permit PRIMARY KEY CLUSTERED (id),
        CONSTRAINT FK_hr_workers_permit_jobsite FOREIGN KEY (by_jobsite) REFERENCES hr.jobsites (id)
    );
    CREATE INDEX IX_hr_workers_permit_period ON hr.workers_permit (by_jobsite, start_date, end_date)
        INCLUDE (nrp, verify) WHERE deleted_at IS NULL;
    CREATE UNIQUE INDEX UQ_hr_workers_permit_legacy_id ON hr.workers_permit (legacy_id) WHERE legacy_id IS NOT NULL;
END
GO

-- ---- cuti kerja (code = hr.enums.code of status: CTN / CTB / CLL / ...) ----
IF OBJECT_ID('hr.workers_cuti_kerja', 'U') IS NULL
BEGIN
    CREATE TABLE hr.workers_cuti_kerja (
        id INT IDENTITY(1,1) NOT NULL,
        by_jobsite INT NOT NULL,
        nrp NVARCHAR(50) NULL,
        start_date DATE NULL,
        end_date DATE NULL,
        [status] INT NULL,
        note NVARCHAR(MAX) NULL,
        verify NVARCHAR(510) NULL,
        created_at DATETIME2 NOT NULL CONSTRAINT DF_hr_workers_cuti_kerja_created_at DEFAULT (SYSUTCDATETIME()),
        created_by INT NULL, updated_at DATETIME2 NULL, updated_by INT NULL,
        deleted_at DATETIME2 NULL, deleted_by INT NULL, legacy_id INT NULL,
        CONSTRAINT PK_hr_workers_cuti_kerja PRIMARY KEY CLUSTERED (id),
        CONSTRAINT FK_hr_workers_cuti_kerja_jobsite FOREIGN KEY (by_jobsite) REFERENCES hr.jobsites (id)
    );
    CREATE INDEX IX_hr_workers_cuti_kerja_period ON hr.workers_cuti_kerja (by_jobsite, start_date, end_date)
        INCLUDE (nrp, [status], verify) WHERE deleted_at IS NULL;
    CREATE UNIQUE INDEX UQ_hr_workers_cuti_kerja_legacy_id ON hr.workers_cuti_kerja (legacy_id) WHERE legacy_id IS NOT NULL;
END
GO

-- ---- manual finger corrections (merged into the finger data) ----
IF OBJECT_ID('hr.workers_finger_error', 'U') IS NULL
BEGIN
    CREATE TABLE hr.workers_finger_error (
        id INT IDENTITY(1,1) NOT NULL,
        by_jobsite INT NOT NULL,
        [date] DATE NULL,
        nrp NVARCHAR(40) NULL,
        finger_in DATETIME2 NULL,
        finger_out DATETIME2 NULL,
        verify NVARCHAR(510) NULL,
        created_at DATETIME2 NOT NULL CONSTRAINT DF_hr_workers_finger_error_created_at DEFAULT (SYSUTCDATETIME()),
        created_by INT NULL, updated_at DATETIME2 NULL, updated_by INT NULL,
        deleted_at DATETIME2 NULL, deleted_by INT NULL, legacy_id INT NULL,
        CONSTRAINT PK_hr_workers_finger_error PRIMARY KEY CLUSTERED (id),
        CONSTRAINT FK_hr_workers_finger_error_jobsite FOREIGN KEY (by_jobsite) REFERENCES hr.jobsites (id)
    );
    CREATE INDEX IX_hr_workers_finger_error_date ON hr.workers_finger_error (by_jobsite, [date])
        INCLUDE (nrp, finger_in, finger_out, verify);
    CREATE UNIQUE INDEX UQ_hr_workers_finger_error_legacy_id ON hr.workers_finger_error (legacy_id) WHERE legacy_id IS NOT NULL;
END
GO

-- ---- public holidays per roster code ----
IF OBJECT_ID('hr.date_holiday', 'U') IS NULL
BEGIN
    CREATE TABLE hr.date_holiday (
        id INT IDENTITY(1,1) NOT NULL,
        by_jobsite INT NOT NULL,
        [date] DATE NULL,
        roster NVARCHAR(2) NULL,
        keterangan VARCHAR(255) NULL,
        created_at DATETIME2 NOT NULL CONSTRAINT DF_hr_date_holiday_created_at DEFAULT (SYSUTCDATETIME()),
        created_by INT NULL, updated_at DATETIME2 NULL, updated_by INT NULL,
        deleted_at DATETIME2 NULL, deleted_by INT NULL, legacy_id INT NULL,
        CONSTRAINT PK_hr_date_holiday PRIMARY KEY CLUSTERED (id),
        CONSTRAINT FK_hr_date_holiday_jobsite FOREIGN KEY (by_jobsite) REFERENCES hr.jobsites (id)
    );
    CREATE INDEX IX_hr_date_holiday_date ON hr.date_holiday (by_jobsite, [date]) INCLUDE (roster) WHERE deleted_at IS NULL;
    CREATE UNIQUE INDEX UQ_hr_date_holiday_legacy_id ON hr.date_holiday (legacy_id) WHERE legacy_id IS NOT NULL;
END
GO

-- ---- raw fingerprint events (non-OAMS machines; source dbo.replication_workers_fingers_non_oams_new) ----
IF OBJECT_ID('hr.workers_finger_log', 'U') IS NULL
BEGIN
    CREATE TABLE hr.workers_finger_log (
        id INT IDENTITY(1,1) NOT NULL,
        by_jobsite INT NOT NULL,
        ndatetime DATE NULL,
        [time] TIME NULL,
        nuserid INT NULL,
        susername VARCHAR(250) NULL,
        ntnaevent VARCHAR(10) NULL,
        created_at DATETIME2 NOT NULL CONSTRAINT DF_hr_workers_finger_log_created_at DEFAULT (SYSUTCDATETIME()),
        created_by INT NULL, updated_at DATETIME2 NULL, updated_by INT NULL,
        deleted_at DATETIME2 NULL, deleted_by INT NULL, legacy_id INT NULL,
        CONSTRAINT PK_hr_workers_finger_log PRIMARY KEY CLUSTERED (id),
        CONSTRAINT FK_hr_workers_finger_log_jobsite FOREIGN KEY (by_jobsite) REFERENCES hr.jobsites (id)
    );
    CREATE INDEX IX_hr_workers_finger_log_date ON hr.workers_finger_log (by_jobsite, ndatetime)
        INCLUDE ([time], nuserid, susername, ntnaevent);
    CREATE UNIQUE INDEX UQ_hr_workers_finger_log_legacy_id ON hr.workers_finger_log (legacy_id) WHERE legacy_id IS NOT NULL;
END
GO

-- ---- OAMS fingerprint / unit data (source dbo.replication_workers_fingers_oams) ----
IF OBJECT_ID('hr.workers_finger_oams', 'U') IS NULL
BEGIN
    CREATE TABLE hr.workers_finger_oams (
        id INT IDENTITY(1,1) NOT NULL,
        by_jobsite INT NOT NULL,
        tanggal DATE NULL,
        nrp VARCHAR(20) NULL,
        nrp_int INT NULL,
        nama VARCHAR(250) NULL,
        shift VARCHAR(10) NULL,
        finger_in DATETIME2 NULL,
        finger_out DATETIME2 NULL,
        unitjigsaw VARCHAR(100) NULL,
        excavator VARCHAR(100) NULL,
        [type] VARCHAR(100) NULL,
        area VARCHAR(100) NULL,
        statusunit VARCHAR(50) NULL,
        hasilbugsel VARCHAR(250) NULL,
        kesimpulanbugsel VARCHAR(250) NULL,
        created_at DATETIME2 NOT NULL CONSTRAINT DF_hr_workers_finger_oams_created_at DEFAULT (SYSUTCDATETIME()),
        created_by INT NULL, updated_at DATETIME2 NULL, updated_by INT NULL,
        deleted_at DATETIME2 NULL, deleted_by INT NULL, legacy_id INT NULL,
        CONSTRAINT PK_hr_workers_finger_oams PRIMARY KEY CLUSTERED (id),
        CONSTRAINT FK_hr_workers_finger_oams_jobsite FOREIGN KEY (by_jobsite) REFERENCES hr.jobsites (id)
    );
    CREATE INDEX IX_hr_workers_finger_oams_date ON hr.workers_finger_oams (by_jobsite, tanggal)
        INCLUDE (nrp, nama, shift, finger_in, finger_out);
    CREATE UNIQUE INDEX UQ_hr_workers_finger_oams_legacy_id ON hr.workers_finger_oams (legacy_id) WHERE legacy_id IS NOT NULL;
END
GO
