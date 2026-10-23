-- =============================================
-- Activity log: one HOT table + archive tables on ROTATE.
-- History is never purged; when hot is full, rename to archive
-- and recreate an empty hr.activity_log.
-- Run AFTER 02_jobsites.sql (FK optional — no FK to keep rotate simple)
-- =============================================

IF OBJECT_ID(N'hr.activity_log_registry', N'U') IS NULL
BEGIN
    CREATE TABLE hr.activity_log_registry (
        id INT IDENTITY(1,1) NOT NULL,
        table_name SYSNAME NOT NULL,
        is_current BIT NOT NULL
            CONSTRAINT DF_hr_activity_log_registry_is_current DEFAULT (0),
        approx_rows BIGINT NOT NULL
            CONSTRAINT DF_hr_activity_log_registry_approx_rows DEFAULT (0),
        started_at DATETIME2 NOT NULL
            CONSTRAINT DF_hr_activity_log_registry_started_at DEFAULT (SYSUTCDATETIME()),
        ended_at DATETIME2 NULL,
        CONSTRAINT PK_hr_activity_log_registry PRIMARY KEY CLUSTERED (id),
        CONSTRAINT UQ_hr_activity_log_registry_table UNIQUE (table_name)
    );

    CREATE UNIQUE INDEX UQ_hr_activity_log_registry_current
        ON hr.activity_log_registry (is_current)
        WHERE is_current = 1;
END;
GO

IF OBJECT_ID(N'hr.activity_log', N'U') IS NULL
BEGIN
    CREATE TABLE hr.activity_log (
        id BIGINT IDENTITY(1,1) NOT NULL,
        by_jobsite INT NOT NULL,
        module NVARCHAR(50) NOT NULL,
        action NVARCHAR(30) NOT NULL,
        record_id BIGINT NULL,
        record_key NVARCHAR(100) NULL,
        actor_user_id INT NULL,
        message NVARCHAR(300) NULL,
        created_at DATETIME2 NOT NULL
            CONSTRAINT DF_hr_activity_log_created_at DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT PK_hr_activity_log PRIMARY KEY NONCLUSTERED (id)
    );

    CREATE CLUSTERED INDEX IX_hr_activity_log_jobsite_created
        ON hr.activity_log (by_jobsite, created_at DESC, id DESC);

    CREATE NONCLUSTERED INDEX IX_hr_activity_log_module_record
        ON hr.activity_log (by_jobsite, module, record_id);

    CREATE NONCLUSTERED INDEX IX_hr_activity_log_actor
        ON hr.activity_log (by_jobsite, actor_user_id, created_at DESC);
END;
GO

-- Seed registry for the hot table if missing
IF NOT EXISTS (
    SELECT 1 FROM hr.activity_log_registry WHERE table_name = N'activity_log'
)
BEGIN
    INSERT INTO hr.activity_log_registry (table_name, is_current, approx_rows, started_at, ended_at)
    VALUES (N'activity_log', 1, 0, SYSUTCDATETIME(), NULL);
END
ELSE
BEGIN
    -- Ensure exactly one current row points at hot name when table exists
    IF OBJECT_ID(N'hr.activity_log', N'U') IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM hr.activity_log_registry WHERE is_current = 1)
    BEGIN
        UPDATE hr.activity_log_registry
        SET is_current = 1, ended_at = NULL
        WHERE table_name = N'activity_log';
    END
END;
GO
