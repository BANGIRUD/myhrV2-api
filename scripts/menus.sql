-- =============================================
-- Tables: menus + menu_permissions
-- Canonical DDL matching runtime (services/menuPermission.js)
-- and seeds (scripts/seed_enum_menus.sql):
--   menus: menu_url, icon, show_sidebar, audit columns
--   menu_permissions: can_approve, deleted_at, audit columns
-- Menu seeding itself lives in seed_enum_menus.sql.
-- =============================================
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'ticketing')
    EXEC('CREATE SCHEMA ticketing');
GO

IF OBJECT_ID('ticketing.menus', 'U') IS NULL
BEGIN
    CREATE TABLE ticketing.menus (
        id INT IDENTITY(1,1) NOT NULL,
        menu_code VARCHAR(100) NOT NULL,
        menu_name VARCHAR(150) NOT NULL,
        menu_url VARCHAR(200) NULL,
        icon VARCHAR(100) NULL,
        parent_id INT NULL,
        sort_order INT NOT NULL CONSTRAINT DF_menus_sort_order DEFAULT (0),
        show_sidebar BIT NOT NULL CONSTRAINT DF_menus_show_sidebar DEFAULT (1),
        is_active BIT NOT NULL CONSTRAINT DF_menus_is_active DEFAULT (1),
        created_at DATETIME NOT NULL CONSTRAINT DF_menus_created_at DEFAULT (GETDATE()),
        created_by VARCHAR(20) NULL,
        updated_at DATETIME NULL,
        updated_by VARCHAR(20) NULL,
        deleted_at DATETIME NULL,
        deleted_by VARCHAR(20) NULL,
        by_jobsite INT NULL,
        CONSTRAINT PK_menus PRIMARY KEY CLUSTERED (id),
        CONSTRAINT UQ_menus_menu_code UNIQUE (menu_code)
    );
END
GO

-- Upgrade path for databases created with the old menus.sql (column "path")
IF OBJECT_ID('ticketing.menus', 'U') IS NOT NULL
BEGIN
    IF COL_LENGTH('ticketing.menus', 'path') IS NOT NULL AND COL_LENGTH('ticketing.menus', 'menu_url') IS NULL
        EXEC sp_rename 'ticketing.menus.path', 'menu_url', 'COLUMN';

    IF COL_LENGTH('ticketing.menus', 'icon') IS NULL
        ALTER TABLE ticketing.menus ADD icon VARCHAR(100) NULL;

    IF COL_LENGTH('ticketing.menus', 'show_sidebar') IS NULL
        ALTER TABLE ticketing.menus ADD show_sidebar BIT NOT NULL CONSTRAINT DF_menus_show_sidebar DEFAULT (1);

    IF COL_LENGTH('ticketing.menus', 'created_by') IS NULL
        ALTER TABLE ticketing.menus ADD created_by VARCHAR(20) NULL;

    IF COL_LENGTH('ticketing.menus', 'updated_at') IS NULL
        ALTER TABLE ticketing.menus ADD updated_at DATETIME NULL;

    IF COL_LENGTH('ticketing.menus', 'updated_by') IS NULL
        ALTER TABLE ticketing.menus ADD updated_by VARCHAR(20) NULL;

    IF COL_LENGTH('ticketing.menus', 'deleted_by') IS NULL
        ALTER TABLE ticketing.menus ADD deleted_by VARCHAR(20) NULL;

    IF COL_LENGTH('ticketing.menus', 'by_jobsite') IS NULL
        ALTER TABLE ticketing.menus ADD by_jobsite INT NULL;
END
GO

IF OBJECT_ID('ticketing.menu_permissions', 'U') IS NULL
BEGIN
    CREATE TABLE ticketing.menu_permissions (
        id INT IDENTITY(1,1) NOT NULL,
        level_id INT NOT NULL,
        menu_id INT NOT NULL,
        can_read BIT NOT NULL CONSTRAINT DF_mp_can_read DEFAULT (0),
        can_insert BIT NOT NULL CONSTRAINT DF_mp_can_insert DEFAULT (0),
        can_update BIT NOT NULL CONSTRAINT DF_mp_can_update DEFAULT (0),
        can_delete BIT NOT NULL CONSTRAINT DF_mp_can_delete DEFAULT (0),
        can_approve BIT NOT NULL CONSTRAINT DF_mp_can_approve DEFAULT (0),
        can_export BIT NOT NULL CONSTRAINT DF_mp_can_export DEFAULT (0),
        can_import BIT NOT NULL CONSTRAINT DF_mp_can_import DEFAULT (0),
        by_jobsite INT NULL,
        created_at DATETIME NOT NULL CONSTRAINT DF_mp_created_at DEFAULT (GETDATE()),
        created_by VARCHAR(20) NULL,
        updated_at DATETIME NULL,
        updated_by VARCHAR(20) NULL,
        deleted_at DATETIME NULL,
        deleted_by VARCHAR(20) NULL,
        CONSTRAINT PK_menu_permissions PRIMARY KEY CLUSTERED (id),
        CONSTRAINT FK_menu_permissions_menu
            FOREIGN KEY (menu_id) REFERENCES ticketing.menus (id)
    );

    CREATE UNIQUE INDEX UQ_menu_permissions_level_menu_jobsite
        ON ticketing.menu_permissions (level_id, menu_id, by_jobsite)
        WHERE deleted_at IS NULL;
END
GO

-- Upgrade path for databases created with the old menu_permissions DDL
IF OBJECT_ID('ticketing.menu_permissions', 'U') IS NOT NULL
BEGIN
    IF COL_LENGTH('ticketing.menu_permissions', 'can_approve') IS NULL
        ALTER TABLE ticketing.menu_permissions ADD can_approve BIT NOT NULL CONSTRAINT DF_mp_can_approve DEFAULT (0);

    IF COL_LENGTH('ticketing.menu_permissions', 'created_by') IS NULL
        ALTER TABLE ticketing.menu_permissions ADD created_by VARCHAR(20) NULL;

    IF COL_LENGTH('ticketing.menu_permissions', 'updated_at') IS NULL
        ALTER TABLE ticketing.menu_permissions ADD updated_at DATETIME NULL;

    IF COL_LENGTH('ticketing.menu_permissions', 'updated_by') IS NULL
        ALTER TABLE ticketing.menu_permissions ADD updated_by VARCHAR(20) NULL;

    IF COL_LENGTH('ticketing.menu_permissions', 'deleted_at') IS NULL
        ALTER TABLE ticketing.menu_permissions ADD deleted_at DATETIME NULL;

    IF COL_LENGTH('ticketing.menu_permissions', 'deleted_by') IS NULL
        ALTER TABLE ticketing.menu_permissions ADD deleted_by VARCHAR(20) NULL;
END
GO
