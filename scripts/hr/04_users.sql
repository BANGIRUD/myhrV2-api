-- =============================================
-- Table: hr.users (app login accounts — MyHR shape + multi-site)
-- Slimmer than dumping every future HR field; wave-1 auth only.
-- Unique username is per jobsite (same NRP can exist on another site).
-- Run AFTER 03_menu_privilege.sql
-- =============================================
IF OBJECT_ID('hr.users', 'U') IS NULL
BEGIN
    CREATE TABLE hr.users (
        id INT IDENTITY(1,1) NOT NULL,
        by_jobsite INT NOT NULL,
        username NVARCHAR(50) NOT NULL,
        password NVARCHAR(255) NOT NULL,
        full_name NVARCHAR(150) NOT NULL,
        email NVARCHAR(150) NULL,
        phone NVARCHAR(30) NULL,
        department NVARCHAR(100) NULL,
        section NVARCHAR(100) NULL,
        description NVARCHAR(MAX) NULL,
        level NVARCHAR(50) NOT NULL,           -- legacy privilege key (dbo.menu_privilege.id)
        level_id INT NULL,                    -- canonical → hr.levels (filled by 09_*)
        legacy_level NVARCHAR(50) NULL,       -- audit copy of original level string
        privilege_menu NVARCHAR(MAX) NULL,    -- extra menu ids (comma-separated)
        ref_id BIGINT NULL,
        activation_key NVARCHAR(100) NULL,
        last_login DATETIME2 NULL,
        is_active BIT NOT NULL
            CONSTRAINT DF_hr_users_is_active DEFAULT (1),
        created_at DATETIME2 NOT NULL
            CONSTRAINT DF_hr_users_created_at DEFAULT (SYSUTCDATETIME()),
        created_by INT NULL,
        updated_at DATETIME2 NULL,
        updated_by INT NULL,
        deleted_at DATETIME2 NULL,
        deleted_by INT NULL,
        -- preserve legacy dbo.users.id for cutover / FK mapping
        legacy_id INT NULL,
        CONSTRAINT PK_hr_users PRIMARY KEY CLUSTERED (id),
        CONSTRAINT FK_hr_users_jobsite
            FOREIGN KEY (by_jobsite) REFERENCES hr.jobsites (id),
        CONSTRAINT FK_hr_users_level
            FOREIGN KEY (level, by_jobsite)
            REFERENCES hr.menu_privilege (id, by_jobsite)
    );

    CREATE UNIQUE INDEX UQ_hr_users_username_jobsite_active
        ON hr.users (by_jobsite, username)
        WHERE deleted_at IS NULL;

    CREATE UNIQUE INDEX UQ_hr_users_legacy_id
        ON hr.users (legacy_id)
        WHERE legacy_id IS NOT NULL;

    CREATE INDEX IX_hr_users_jobsite_level
        ON hr.users (by_jobsite, level)
        WHERE deleted_at IS NULL;
END
GO
