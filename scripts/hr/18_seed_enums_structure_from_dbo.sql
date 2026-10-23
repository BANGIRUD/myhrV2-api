-- =============================================
-- Seed / ETL: copy dbo.enums + dbo.structure → hr.*
-- Default site: hr.jobsites id = 1 (DEFAULT)
-- Preserves source ids (IDENTITY_INSERT) for FK compatibility.
-- Safe to re-run: skips rows already present (by id + by_jobsite).
-- Prefer scripts/hr/seed_enums_structure_from_azure.js when Azure
-- is the concrete source of truth (refreshes dbo then hr).
-- Run AFTER 16_enums.sql + 17_structure.sql
-- =============================================
SET NOCOUNT ON;

DECLARE @JobsiteId INT = 1;

IF NOT EXISTS (SELECT 1 FROM hr.jobsites WHERE id = @JobsiteId AND deleted_at IS NULL)
BEGIN
    THROW 50020, 'hr.jobsites id=1 (DEFAULT) missing. Run 02_jobsites.sql first.', 1;
END;

IF OBJECT_ID('hr.enums', 'U') IS NULL OR OBJECT_ID('hr.structure', 'U') IS NULL
BEGIN
    THROW 50021, 'hr.enums / hr.structure missing. Run 16_enums.sql and 17_structure.sql first.', 1;
END;

-- ---- enums ----
SET IDENTITY_INSERT hr.enums ON;

INSERT INTO hr.enums (
    id,
    by_jobsite,
    code,
    name,
    category,
    description,
    type,
    ref_id,
    by_user,
    created_at,
    created_by,
    updated_at,
    updated_by,
    deleted_at,
    deleted_by,
    legacy_id
)
SELECT
    src.id,
    @JobsiteId,
    src.code,
    src.name,
    src.category,
    src.description,
    src.type,
    src.ref_id,
    src.by_user,
    src.created_at,
    TRY_CAST(src.by_user AS INT),
    src.updated_at,
    NULL,
    src.deleted_at,
    NULL,
    src.id
FROM dbo.enums AS src
WHERE NOT EXISTS (
    SELECT 1
    FROM hr.enums AS dst
    WHERE dst.id = src.id
      AND dst.by_jobsite = @JobsiteId
);

PRINT CONCAT('hr.enums inserted for jobsite ', @JobsiteId, ': ', @@ROWCOUNT);

SET IDENTITY_INSERT hr.enums OFF;

-- ---- structure ----
SET IDENTITY_INSERT hr.structure ON;

INSERT INTO hr.structure (
    id,
    by_jobsite,
    key_id,
    code,
    name,
    category,
    description,
    type,
    ref_id,
    by_order,
    by_user,
    created_at,
    created_by,
    updated_at,
    updated_by,
    deleted_at,
    deleted_by,
    legacy_id
)
SELECT
    src.id,
    @JobsiteId,
    src.key_id,
    src.code,
    src.name,
    src.category,
    src.description,
    src.type,
    src.ref_id,
    src.by_order,
    src.by_user,
    src.created_at,
    TRY_CAST(src.by_user AS INT),
    src.updated_at,
    NULL,
    src.deleted_at,
    NULL,
    src.id
FROM dbo.structure AS src
WHERE NOT EXISTS (
    SELECT 1
    FROM hr.structure AS dst
    WHERE dst.id = src.id
      AND dst.by_jobsite = @JobsiteId
);

PRINT CONCAT('hr.structure inserted for jobsite ', @JobsiteId, ': ', @@ROWCOUNT);

SET IDENTITY_INSERT hr.structure OFF;
GO
