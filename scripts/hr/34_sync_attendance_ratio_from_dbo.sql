-- =============================================
-- Sync: dbo.achievement_attendance_ratio → hr.attendance_ratio (rolling window)
-- Window (must match seed_attendance_from_azure.js): first day of the month 2 months ago
-- up to and including today. Future days are not synced: the cron only keeps a few
-- placeholder rows there, so hr.DASHBOARD_SP falls back to the dbo bridge for them.
-- Idempotent; safe to re-run:
--   1) updates hr rows whose source data differs
--   2) inserts source rows missing in hr
--   3) soft-deletes hr rows in the window that no longer exist in dbo
-- hr rows that fell out of the window are left untouched; purge them manually when needed.
-- Run AFTER 33_attendance_ratio.sql
-- =============================================
SET NOCOUNT ON;

DECLARE @JobsiteId INT = 1;
DECLARE @From DATE = DATEFROMPARTS(YEAR(DATEADD(MONTH, -2, GETDATE())), MONTH(DATEADD(MONTH, -2, GETDATE())), 1);
DECLARE @To DATE = DATEADD(DAY, 1, CAST(GETDATE() AS DATE));   -- exclusive

IF NOT EXISTS (SELECT 1 FROM hr.jobsites WHERE id = @JobsiteId AND deleted_at IS NULL)
BEGIN
    THROW 50044, 'hr.jobsites id=1 (DEFAULT) missing. Run 02_jobsites.sql first.', 1;
END;

IF OBJECT_ID('hr.attendance_ratio', 'U') IS NULL
BEGIN
    THROW 50045, 'hr.attendance_ratio missing. Run 33_attendance_ratio.sql first.', 1;
END;

PRINT CONCAT('attendance window: ', CONVERT(VARCHAR(10), @From), ' <= date < ', CONVERT(VARCHAR(10), @To));

-- ---- update changed rows ----
UPDATE dst
SET
    nrp = src.nrp,
    nrp_int = src.nrp_int,
    full_name = src.full_name,
    job_rank = src.job_rank,
    department = src.department,
    [section] = src.[section],
    [date] = src.[date],
    finger_in = src.finger_in,
    finger_out = src.finger_out,
    actual = src.actual,
    [plan] = src.[plan],
    [status] = src.[status],
    by_user = src.by_user,
    updated_at = src.updated_at,
    deleted_at = src.deleted_at
FROM hr.attendance_ratio AS dst
INNER JOIN dbo.achievement_attendance_ratio AS src
    ON src.id = dst.id
WHERE dst.by_jobsite = @JobsiteId
  AND src.[date] >= @From AND src.[date] < @To
  AND EXISTS (
    SELECT
        src.nrp, src.nrp_int, src.full_name, src.job_rank, src.department, src.[section], src.[date],
        src.finger_in, src.finger_out, src.actual, src.[plan], src.[status], src.by_user,
        src.updated_at, src.deleted_at
    EXCEPT
    SELECT
        dst.nrp, dst.nrp_int, dst.full_name, dst.job_rank, dst.department, dst.[section], dst.[date],
        dst.finger_in, dst.finger_out, dst.actual, dst.[plan], dst.[status], dst.by_user,
        dst.updated_at, dst.deleted_at
  );

PRINT CONCAT('hr.attendance_ratio updated: ', @@ROWCOUNT);

-- ---- insert missing rows ----
SET IDENTITY_INSERT hr.attendance_ratio ON;

INSERT INTO hr.attendance_ratio (
    id, by_jobsite, nrp, nrp_int, full_name, job_rank, department, [section], [date],
    finger_in, finger_out, actual, [plan], [status], by_user,
    created_at, created_by, updated_at, updated_by, deleted_at, deleted_by, legacy_id
)
SELECT
    src.id, @JobsiteId, src.nrp, src.nrp_int, src.full_name, src.job_rank, src.department, src.[section], src.[date],
    src.finger_in, src.finger_out, src.actual, src.[plan], src.[status], src.by_user,
    ISNULL(src.created_at, SYSUTCDATETIME()), TRY_CAST(src.by_user AS INT),
    src.updated_at, NULL, src.deleted_at, NULL, src.id
FROM dbo.achievement_attendance_ratio AS src
WHERE src.[date] >= @From AND src.[date] < @To
  AND NOT EXISTS (SELECT 1 FROM hr.attendance_ratio AS dst WHERE dst.id = src.id);

PRINT CONCAT('hr.attendance_ratio inserted: ', @@ROWCOUNT);

SET IDENTITY_INSERT hr.attendance_ratio OFF;

-- ---- soft-delete in-window rows removed from dbo ----
-- Safety: only when dbo actually holds rows for the window. An emptied / unseeded dbo copy
-- (e.g. truncated to free space) must NOT wipe the hr data; re-run seed_attendance_from_azure.js instead.
IF EXISTS (SELECT 1 FROM dbo.achievement_attendance_ratio WHERE [date] >= @From AND [date] < @To)
BEGIN
    UPDATE dst
    SET deleted_at = SYSUTCDATETIME(),
        deleted_by = NULL
    FROM hr.attendance_ratio AS dst
    WHERE dst.by_jobsite = @JobsiteId
      AND dst.deleted_at IS NULL
      AND dst.[date] >= @From AND dst.[date] < @To
      AND NOT EXISTS (SELECT 1 FROM dbo.achievement_attendance_ratio AS src WHERE src.id = dst.id);

    PRINT CONCAT('hr.attendance_ratio soft-deleted (missing in dbo): ', @@ROWCOUNT);
END
ELSE
    PRINT 'dbo.achievement_attendance_ratio has no rows in the window: soft-delete step skipped.';
GO
