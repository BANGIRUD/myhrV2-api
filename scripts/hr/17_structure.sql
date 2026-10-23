-- =============================================
-- Table: hr.structure — org tree (department / section)
-- Source: dbo.structure / Azure MYHR
-- Adapted for multi-site: by_jobsite + hr audit columns.
-- section.ref_id → parent department id (same id space when preserved).
-- Run AFTER 02_jobsites.sql
-- =============================================
IF OBJECT_ID('hr.structure', 'U') IS NULL
BEGIN
    CREATE TABLE hr.structure (
        id INT IDENTITY(1,1) NOT NULL,
        by_jobsite INT NOT NULL,
        key_id NVARCHAR(100) NOT NULL,
        code NVARCHAR(50) NULL,
        name NVARCHAR(MAX) NOT NULL,
        category NVARCHAR(50) NULL,
        description NVARCHAR(MAX) NULL,
        type NVARCHAR(50) NOT NULL,           -- department | section
        ref_id BIGINT NULL,                   -- parent structure id
        by_order INT NOT NULL
            CONSTRAINT DF_hr_structure_by_order DEFAULT (0),
        by_user INT NULL,
        created_at DATETIME2 NOT NULL
            CONSTRAINT DF_hr_structure_created_at DEFAULT (SYSUTCDATETIME()),
        created_by INT NULL,
        updated_at DATETIME2 NULL,
        updated_by INT NULL,
        deleted_at DATETIME2 NULL,
        deleted_by INT NULL,
        legacy_id INT NULL,
        CONSTRAINT PK_hr_structure PRIMARY KEY CLUSTERED (id),
        CONSTRAINT FK_hr_structure_jobsite
            FOREIGN KEY (by_jobsite) REFERENCES hr.jobsites (id)
    );

    CREATE UNIQUE INDEX UQ_hr_structure_key_jobsite
        ON hr.structure (by_jobsite, key_id)
        WHERE deleted_at IS NULL;

    CREATE INDEX IX_hr_structure_type_jobsite
        ON hr.structure (by_jobsite, type)
        WHERE deleted_at IS NULL;

    CREATE INDEX IX_hr_structure_ref_jobsite
        ON hr.structure (by_jobsite, ref_id)
        WHERE deleted_at IS NULL;

    CREATE UNIQUE INDEX UQ_hr_structure_legacy_id
        ON hr.structure (legacy_id)
        WHERE legacy_id IS NOT NULL;
END
GO
