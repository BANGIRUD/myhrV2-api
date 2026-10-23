-- =============================================
-- Table: hr.menu_privilege (level / role templates)
-- Legacy dbo.menu_privilege.id is varchar level code (admin, admin_hr, …).
-- Reserved SQL names create/read/update/delete → access_* in hr.
-- by_jobsite scopes privilege templates per site.
-- Run AFTER 02_jobsites.sql
-- =============================================
IF OBJECT_ID('hr.menu_privilege', 'U') IS NULL
BEGIN
    CREATE TABLE hr.menu_privilege (
        id NVARCHAR(50) NOT NULL,              -- level code (legacy PK)
        by_jobsite INT NOT NULL,
        name NVARCHAR(100) NULL,               -- optional display label
        menu NVARCHAR(MAX) NOT NULL
            CONSTRAINT DF_hr_menu_privilege_menu DEFAULT (N''),
        dashboard NVARCHAR(MAX) NOT NULL
            CONSTRAINT DF_hr_menu_privilege_dashboard DEFAULT (N''),
        access_create NVARCHAR(50) NULL,
        access_read NVARCHAR(50) NULL,
        access_update NVARCHAR(50) NULL,
        access_delete NVARCHAR(50) NULL,
        access_export NVARCHAR(50) NULL,
        created_at DATETIME2 NOT NULL
            CONSTRAINT DF_hr_menu_privilege_created_at DEFAULT (SYSUTCDATETIME()),
        created_by INT NULL,
        updated_at DATETIME2 NULL,
        updated_by INT NULL,
        deleted_at DATETIME2 NULL,
        deleted_by INT NULL,
        CONSTRAINT PK_hr_menu_privilege PRIMARY KEY CLUSTERED (id, by_jobsite),
        CONSTRAINT FK_hr_menu_privilege_jobsite
            FOREIGN KEY (by_jobsite) REFERENCES hr.jobsites (id)
    );

    CREATE INDEX IX_hr_menu_privilege_jobsite
        ON hr.menu_privilege (by_jobsite)
        WHERE deleted_at IS NULL;
END
GO
