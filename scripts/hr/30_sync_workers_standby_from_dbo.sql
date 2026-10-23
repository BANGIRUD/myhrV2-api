-- =============================================
-- Sync: dbo.workers_standby → hr.workers_standby
-- Default site: hr.jobsites id = 1
-- Idempotent and safe while the legacy app still writes to dbo:
--   1) updates hr rows whose source data differs
--   2) inserts source rows missing in hr
--   3) soft-deletes hr rows that no longer exist in dbo
-- Ids are preserved (IDENTITY_INSERT), so hr and dbo stay row-for-row comparable.
-- Run AFTER 29_workers_standby.sql
-- =============================================
SET NOCOUNT ON;

DECLARE @JobsiteId INT = 1;

IF NOT EXISTS (SELECT 1 FROM hr.jobsites WHERE id = @JobsiteId AND deleted_at IS NULL)
BEGIN
    THROW 50040, 'hr.jobsites id=1 (DEFAULT) missing. Run 02_jobsites.sql first.', 1;
END;

IF OBJECT_ID('hr.workers_standby', 'U') IS NULL
BEGIN
    THROW 50041, 'hr.workers_standby missing. Run 29_workers_standby.sql first.', 1;
END;

-- ---- update changed rows ----
UPDATE dst
SET
    ref_id = src.ref_id,
    key_id = src.key_id,
    [date] = src.[date],
    nrp = src.nrp,
    nrp_int = src.nrp_int,
    full_name = src.full_name,
    category = src.category,
    start_date = src.start_date,
    end_date = src.end_date,
    path_evident = src.path_evident,
    [description] = src.[description],
    verify = src.verify,
    approve = src.approve,
    reject = src.reject,
    by_verified = src.by_verified,
    by_user = src.by_user,
    updated_at = src.updated_at,
    updated_by = TRY_CAST(src.by_user AS INT),
    deleted_at = src.deleted_at
FROM hr.workers_standby AS dst
INNER JOIN dbo.workers_standby AS src
    ON src.id = dst.id
WHERE dst.by_jobsite = @JobsiteId
  AND EXISTS (
    SELECT
        src.ref_id, src.key_id, src.[date], src.nrp, src.nrp_int, src.full_name, src.category,
        src.start_date, src.end_date, src.path_evident, src.[description], src.verify, src.approve,
        src.reject, src.by_verified, src.by_user, src.updated_at, src.deleted_at
    EXCEPT
    SELECT
        dst.ref_id, dst.key_id, dst.[date], dst.nrp, dst.nrp_int, dst.full_name, dst.category,
        dst.start_date, dst.end_date, dst.path_evident, dst.[description], dst.verify, dst.approve,
        dst.reject, dst.by_verified, dst.by_user, dst.updated_at, dst.deleted_at
  );

PRINT CONCAT('hr.workers_standby updated: ', @@ROWCOUNT);

-- ---- insert missing rows ----
SET IDENTITY_INSERT hr.workers_standby ON;

INSERT INTO hr.workers_standby (
    id, by_jobsite, ref_id, key_id, [date], nrp, nrp_int, full_name, category,
    start_date, end_date, path_evident, [description], verify, approve, reject,
    by_verified, by_user, created_at, created_by, updated_at, updated_by,
    deleted_at, deleted_by, legacy_id
)
SELECT
    src.id, @JobsiteId, src.ref_id, src.key_id, src.[date], src.nrp, src.nrp_int, src.full_name, src.category,
    src.start_date, src.end_date, src.path_evident, src.[description], src.verify, src.approve, src.reject,
    src.by_verified, src.by_user, ISNULL(src.created_at, SYSUTCDATETIME()), TRY_CAST(src.by_user AS INT),
    src.updated_at, NULL, src.deleted_at, NULL, src.id
FROM dbo.workers_standby AS src
WHERE NOT EXISTS (
    SELECT 1 FROM hr.workers_standby AS dst WHERE dst.id = src.id
);

PRINT CONCAT('hr.workers_standby inserted: ', @@ROWCOUNT);

SET IDENTITY_INSERT hr.workers_standby OFF;

-- ---- soft-delete rows removed from dbo ----
UPDATE dst
SET deleted_at = SYSUTCDATETIME(),
    deleted_by = NULL
FROM hr.workers_standby AS dst
WHERE dst.by_jobsite = @JobsiteId
  AND dst.deleted_at IS NULL
  AND NOT EXISTS (SELECT 1 FROM dbo.workers_standby AS src WHERE src.id = dst.id);

PRINT CONCAT('hr.workers_standby soft-deleted (missing in dbo): ', @@ROWCOUNT);
GO
