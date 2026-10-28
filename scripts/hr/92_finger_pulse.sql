-- =============================================
-- Finger Pulse — ingest control tables (Biostar linked server)
-- Raw append-only ledger + watermark + run log + config.
-- Canonical targets remain hr.workers_finger_log / hr.workers_finger_oams (script 35).
-- Run AFTER 35_attendance_sources.sql / 02_jobsites.sql
--
-- Linked-server prerequisite (once per host, needs ALTER ANY LINKED SERVER):
--   EXEC sp_serveroption N'BIOSTAR_131_100', N'remote proc transaction promotion', N'false';
-- Without this, INSERT…EXEC of remote Biostar SPs often fails with MSDTC 0x80070057.
-- =============================================

BEGIN TRY
    EXEC master.dbo.sp_serveroption
        @server = N'BIOSTAR_131_100',
        @optname = N'remote proc transaction promotion',
        @optvalue = N'false';
END TRY
BEGIN CATCH
    PRINT N'finger_pulse: could not set remote proc transaction promotion (ok if no permission / linked server missing): '
        + ERROR_MESSAGE();
END CATCH
GO

IF OBJECT_ID(N'hr.finger_pulse_config', N'U') IS NULL
BEGIN
    CREATE TABLE hr.finger_pulse_config (
        id INT NOT NULL CONSTRAINT PK_hr_finger_pulse_config PRIMARY KEY,
        linked_server SYSNAME NOT NULL
            CONSTRAINT DF_hr_finger_pulse_config_linked DEFAULT (N'BIOSTAR_131_100'),
        remote_database SYSNAME NOT NULL
            CONSTRAINT DF_hr_finger_pulse_config_remote_db DEFAULT (N'biostar2ac'),
        by_jobsite INT NOT NULL
            CONSTRAINT DF_hr_finger_pulse_config_jobsite DEFAULT (1),
        raw_retain_days INT NOT NULL
            CONSTRAINT DF_hr_finger_pulse_config_retain DEFAULT (90),
        enabled BIT NOT NULL
            CONSTRAINT DF_hr_finger_pulse_config_enabled DEFAULT (1),
        updated_at DATETIME2 NOT NULL
            CONSTRAINT DF_hr_finger_pulse_config_updated DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT CK_hr_finger_pulse_config_singleton CHECK (id = 1),
        CONSTRAINT CK_hr_finger_pulse_config_retain CHECK (raw_retain_days >= 7),
        CONSTRAINT FK_hr_finger_pulse_config_jobsite FOREIGN KEY (by_jobsite)
            REFERENCES hr.jobsites (id)
    );
END
GO

IF NOT EXISTS (SELECT 1 FROM hr.finger_pulse_config WHERE id = 1)
BEGIN
    INSERT INTO hr.finger_pulse_config (id, linked_server, remote_database, by_jobsite, raw_retain_days, enabled)
    VALUES (1, N'BIOSTAR_131_100', N'biostar2ac', 1, 90, 1);
END
GO

IF OBJECT_ID(N'hr.finger_pulse_watermark', N'U') IS NULL
BEGIN
    CREATE TABLE hr.finger_pulse_watermark (
        stream VARCHAR(20) NOT NULL,
        by_jobsite INT NOT NULL,
        last_success_at DATETIME2 NULL,
        last_date_from DATE NULL,
        last_date_to DATE NULL,
        last_rows_in INT NULL,
        last_raw_new INT NULL,
        last_merged INT NULL,
        last_status VARCHAR(20) NULL,
        last_error NVARCHAR(1000) NULL,
        updated_at DATETIME2 NOT NULL
            CONSTRAINT DF_hr_finger_pulse_watermark_updated DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT PK_hr_finger_pulse_watermark PRIMARY KEY CLUSTERED (by_jobsite, stream),
        CONSTRAINT CK_hr_finger_pulse_watermark_stream CHECK (stream IN (N'non_oams', N'oams')),
        CONSTRAINT FK_hr_finger_pulse_watermark_jobsite FOREIGN KEY (by_jobsite)
            REFERENCES hr.jobsites (id)
    );
END
GO

IF NOT EXISTS (
    SELECT 1 FROM hr.finger_pulse_watermark WHERE by_jobsite = 1 AND stream = N'non_oams'
)
    INSERT INTO hr.finger_pulse_watermark (stream, by_jobsite) VALUES (N'non_oams', 1);
IF NOT EXISTS (
    SELECT 1 FROM hr.finger_pulse_watermark WHERE by_jobsite = 1 AND stream = N'oams'
)
    INSERT INTO hr.finger_pulse_watermark (stream, by_jobsite) VALUES (N'oams', 1);
GO

IF OBJECT_ID(N'hr.finger_pulse_run', N'U') IS NULL
BEGIN
    CREATE TABLE hr.finger_pulse_run (
        id BIGINT IDENTITY(1,1) NOT NULL,
        batch_id UNIQUEIDENTIFIER NOT NULL,
        by_jobsite INT NOT NULL,
        mode VARCHAR(20) NOT NULL,
        stream VARCHAR(20) NULL,
        date_from DATE NULL,
        date_to DATE NULL,
        started_at DATETIME2 NOT NULL
            CONSTRAINT DF_hr_finger_pulse_run_started DEFAULT (SYSUTCDATETIME()),
        finished_at DATETIME2 NULL,
        rows_in INT NULL,
        raw_new INT NULL,
        merged INT NULL,
        status VARCHAR(20) NOT NULL
            CONSTRAINT DF_hr_finger_pulse_run_status DEFAULT (N'RUNNING'),
        error_message NVARCHAR(1000) NULL,
        CONSTRAINT PK_hr_finger_pulse_run PRIMARY KEY CLUSTERED (id),
        CONSTRAINT CK_hr_finger_pulse_run_mode CHECK (mode IN (N'PULSE', N'RECONCILE', N'BACKFILL', N'PURGE')),
        CONSTRAINT CK_hr_finger_pulse_run_status CHECK (status IN (N'RUNNING', N'SUCCESS', N'FAILED', N'SKIPPED')),
        CONSTRAINT FK_hr_finger_pulse_run_jobsite FOREIGN KEY (by_jobsite)
            REFERENCES hr.jobsites (id)
    );
    CREATE INDEX IX_hr_finger_pulse_run_started
        ON hr.finger_pulse_run (by_jobsite, started_at DESC);
    CREATE INDEX IX_hr_finger_pulse_run_batch
        ON hr.finger_pulse_run (batch_id);
END
GO

IF OBJECT_ID(N'hr.finger_pulse_raw', N'U') IS NULL
BEGIN
    CREATE TABLE hr.finger_pulse_raw (
        id BIGINT IDENTITY(1,1) NOT NULL,
        by_jobsite INT NOT NULL,
        batch_id UNIQUEIDENTIFIER NOT NULL,
        stream VARCHAR(20) NOT NULL,
        pulled_at DATETIME2 NOT NULL
            CONSTRAINT DF_hr_finger_pulse_raw_pulled DEFAULT (SYSUTCDATETIME()),
        date_from DATE NOT NULL,
        date_to DATE NOT NULL,
        content_hash VARBINARY(32) NOT NULL,
        -- non_oams (SP_GET_DATA_FINGER)
        neventlogidn BIGINT NULL,
        server_name VARCHAR(50) NULL,
        ndatetime DATE NULL,
        [time] TIME(0) NULL,
        sip VARCHAR(50) NULL,
        id_mesin VARCHAR(50) NULL,
        nuserid INT NULL,
        susername VARCHAR(250) NULL,
        ntnaevent VARCHAR(10) NULL,
        -- oams (SP_GET_DATA_FINGER_OAMS)
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
        CONSTRAINT PK_hr_finger_pulse_raw PRIMARY KEY CLUSTERED (id),
        CONSTRAINT CK_hr_finger_pulse_raw_stream CHECK (stream IN (N'non_oams', N'oams')),
        CONSTRAINT FK_hr_finger_pulse_raw_jobsite FOREIGN KEY (by_jobsite)
            REFERENCES hr.jobsites (id)
    );
END
GO

IF OBJECT_ID(N'hr.finger_pulse_raw', N'U') IS NOT NULL
   AND NOT EXISTS (
       SELECT 1 FROM sys.indexes
       WHERE object_id = OBJECT_ID(N'hr.finger_pulse_raw')
         AND name = N'UQ_hr_finger_pulse_raw_hash'
   )
    CREATE UNIQUE INDEX UQ_hr_finger_pulse_raw_hash
        ON hr.finger_pulse_raw (by_jobsite, stream, content_hash);
GO

IF OBJECT_ID(N'hr.finger_pulse_raw', N'U') IS NOT NULL
   AND NOT EXISTS (
       SELECT 1 FROM sys.indexes
       WHERE object_id = OBJECT_ID(N'hr.finger_pulse_raw')
         AND name = N'IX_hr_finger_pulse_raw_batch'
   )
    CREATE INDEX IX_hr_finger_pulse_raw_batch
        ON hr.finger_pulse_raw (batch_id, stream);
GO

IF OBJECT_ID(N'hr.finger_pulse_raw', N'U') IS NOT NULL
   AND NOT EXISTS (
       SELECT 1 FROM sys.indexes
       WHERE object_id = OBJECT_ID(N'hr.finger_pulse_raw')
         AND name = N'IX_hr_finger_pulse_raw_pulled'
   )
    CREATE INDEX IX_hr_finger_pulse_raw_pulled
        ON hr.finger_pulse_raw (pulled_at);
GO

IF OBJECT_ID(N'hr.finger_pulse_raw', N'U') IS NOT NULL
   AND NOT EXISTS (
       SELECT 1 FROM sys.indexes
       WHERE object_id = OBJECT_ID(N'hr.finger_pulse_raw')
         AND name = N'IX_hr_finger_pulse_raw_non_oams_nk'
   )
    CREATE INDEX IX_hr_finger_pulse_raw_non_oams_nk
        ON hr.finger_pulse_raw (by_jobsite, stream, nuserid, ndatetime, [time], ntnaevent);
GO

IF OBJECT_ID(N'hr.finger_pulse_raw', N'U') IS NOT NULL
   AND NOT EXISTS (
       SELECT 1 FROM sys.indexes
       WHERE object_id = OBJECT_ID(N'hr.finger_pulse_raw')
         AND name = N'IX_hr_finger_pulse_raw_oams_nk'
   )
    CREATE INDEX IX_hr_finger_pulse_raw_oams_nk
        ON hr.finger_pulse_raw (by_jobsite, stream, nrp, tanggal);
GO

/* Staging for Node (or future) pull — avoids linked-server INSERT…EXEC + MSDTC */
IF OBJECT_ID(N'hr.finger_pulse_stage_non_oams', N'U') IS NULL
BEGIN
    CREATE TABLE hr.finger_pulse_stage_non_oams (
        batch_id UNIQUEIDENTIFIER NOT NULL,
        nEventLogIdn BIGINT NULL,
        nDateTime DATETIME2 NULL,
        [TIME] NVARCHAR(30) NULL,
        IP_ADDRESS NVARCHAR(50) NULL,
        sIP NVARCHAR(50) NULL,
        nUserID INT NULL,
        nUserName NVARCHAR(250) NULL,
        nTnaEvent INT NULL,
        SERVER_NAME NVARCHAR(50) NULL
    );
    CREATE INDEX IX_hr_finger_pulse_stage_non_oams_batch
        ON hr.finger_pulse_stage_non_oams (batch_id);
END
GO

IF OBJECT_ID(N'hr.finger_pulse_stage_oams', N'U') IS NULL
BEGIN
    CREATE TABLE hr.finger_pulse_stage_oams (
        batch_id UNIQUEIDENTIFIER NOT NULL,
        TANGGAL DATE NULL,
        NRP VARCHAR(25) NULL,
        NAMA VARCHAR(55) NULL,
        shift VARCHAR(10) NULL,
        FINGER_IN DATETIME NULL,
        FINGER_OUT DATETIME NULL,
        UnitJigsaw VARCHAR(20) NULL,
        Excavator VARCHAR(35) NULL,
        [Type] VARCHAR(50) NULL,
        AREA VARCHAR(100) NULL,
        STATUS_UNIT VARCHAR(15) NULL,
        HASIL_BUGSEL VARCHAR(150) NULL,
        KESIMPULAN_BUGSEL VARCHAR(35) NULL
    );
    CREATE INDEX IX_hr_finger_pulse_stage_oams_batch
        ON hr.finger_pulse_stage_oams (batch_id);
END
GO
