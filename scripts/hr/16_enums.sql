-- =============================================
-- Table: hr.enums — typed lookups (from dbo.enums / Azure MYHR)
-- Adapted for multi-site: by_jobsite + hr audit columns.
-- Preserve source ids (IDENTITY_INSERT on seed) for FK compatibility.
-- Run AFTER 02_jobsites.sql
-- =============================================
IF OBJECT_ID('hr.enums', 'U') IS NULL
BEGIN
    CREATE TABLE hr.enums (
        id INT IDENTITY(1,1) NOT NULL,
        by_jobsite INT NOT NULL,
        code NVARCHAR(50) NULL,
        name NVARCHAR(MAX) NOT NULL,
        category NVARCHAR(50) NULL,
        description NVARCHAR(MAX) NULL,
        type NVARCHAR(50) NOT NULL,
        ref_id BIGINT NULL,
        -- legacy dbo.enums.by_user (int user id)
        by_user INT NULL,
        created_at DATETIME2 NOT NULL
            CONSTRAINT DF_hr_enums_created_at DEFAULT (SYSUTCDATETIME()),
        created_by INT NULL,
        updated_at DATETIME2 NULL,
        updated_by INT NULL,
        deleted_at DATETIME2 NULL,
        deleted_by INT NULL,
        -- original dbo/Azure id when ids were remapped (NULL if id preserved)
        legacy_id INT NULL,
        CONSTRAINT PK_hr_enums PRIMARY KEY CLUSTERED (id),
        CONSTRAINT FK_hr_enums_jobsite
            FOREIGN KEY (by_jobsite) REFERENCES hr.jobsites (id)
    );

    CREATE INDEX IX_hr_enums_type_jobsite
        ON hr.enums (by_jobsite, type)
        WHERE deleted_at IS NULL;

    CREATE INDEX IX_hr_enums_category_jobsite
        ON hr.enums (by_jobsite, category)
        WHERE deleted_at IS NULL;

    CREATE UNIQUE INDEX UQ_hr_enums_legacy_id
        ON hr.enums (legacy_id)
        WHERE legacy_id IS NOT NULL;
END
GO
