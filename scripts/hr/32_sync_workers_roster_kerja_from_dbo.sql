-- =============================================
-- Sync: dbo.workers_roster_kerja → hr.workers_roster_kerja (rolling window)
-- Window (must match seed_attendance_from_azure.js): first day of the month 2 months
-- ago up to (excluding) the first day of the month 2 months ahead.
-- Idempotent; safe while the legacy app still writes to dbo:
--   1) updates hr rows whose source data differs
--   2) inserts source rows missing in hr
--   3) soft-deletes hr rows in the window that no longer exist in dbo
-- hr rows that have fallen out of the window (older than @From) are left untouched;
-- purge them manually when space is needed.
-- Run AFTER 31_workers_roster_kerja.sql
-- =============================================
SET NOCOUNT ON;

DECLARE @JobsiteId INT = 1;
DECLARE @From DATE = DATEFROMPARTS(YEAR(DATEADD(MONTH, -2, GETDATE())), MONTH(DATEADD(MONTH, -2, GETDATE())), 1);
DECLARE @To DATE = DATEFROMPARTS(YEAR(DATEADD(MONTH, 2, GETDATE())), MONTH(DATEADD(MONTH, 2, GETDATE())), 1);

IF NOT EXISTS (SELECT 1 FROM hr.jobsites WHERE id = @JobsiteId AND deleted_at IS NULL)
BEGIN
    THROW 50042, 'hr.jobsites id=1 (DEFAULT) missing. Run 02_jobsites.sql first.', 1;
END;

IF OBJECT_ID('hr.workers_roster_kerja', 'U') IS NULL
BEGIN
    THROW 50043, 'hr.workers_roster_kerja missing. Run 31_workers_roster_kerja.sql first.', 1;
END;

PRINT CONCAT('roster window: ', CONVERT(VARCHAR(10), @From), ' <= date < ', CONVERT(VARCHAR(10), @To));

-- ---- update changed rows ----
UPDATE dst
SET
    [date] = src.[date],
    nrp = src.nrp,
    nrp_int = src.nrp_int,
    pola_kerja = src.pola_kerja,
    pola_cuti = src.pola_cuti,
    pola_hari = src.pola_hari,
    hari_ke = src.hari_ke,
    remark = src.remark,
    by_user = src.by_user,
    updated_at = src.updated_at,
    updated_by = TRY_CAST(src.by_user AS INT),
    deleted_at = src.deleted_at
FROM hr.workers_roster_kerja AS dst
INNER JOIN dbo.workers_roster_kerja AS src
    ON src.id = dst.id
WHERE dst.by_jobsite = @JobsiteId
  AND src.[date] >= @From AND src.[date] < @To
  AND EXISTS (
    SELECT
        src.[date], src.nrp, src.nrp_int, src.pola_kerja, src.pola_cuti, src.pola_hari,
        src.hari_ke, src.remark, src.by_user, src.updated_at, src.deleted_at
    EXCEPT
    SELECT
        dst.[date], dst.nrp, dst.nrp_int, dst.pola_kerja, dst.pola_cuti, dst.pola_hari,
        dst.hari_ke, dst.remark, dst.by_user, dst.updated_at, dst.deleted_at
  );

PRINT CONCAT('hr.workers_roster_kerja updated: ', @@ROWCOUNT);

-- ---- insert missing rows ----
SET IDENTITY_INSERT hr.workers_roster_kerja ON;

INSERT INTO hr.workers_roster_kerja (
    id, by_jobsite, [date], nrp, nrp_int, pola_kerja, pola_cuti, pola_hari, hari_ke, remark,
    by_user, created_at, created_by, updated_at, updated_by, deleted_at, deleted_by, legacy_id
)
SELECT
    src.id, @JobsiteId, src.[date], src.nrp, src.nrp_int, src.pola_kerja, src.pola_cuti, src.pola_hari,
    src.hari_ke, src.remark, src.by_user, ISNULL(src.created_at, SYSUTCDATETIME()),
    TRY_CAST(src.by_user AS INT), src.updated_at, NULL, src.deleted_at, NULL, src.id
FROM dbo.workers_roster_kerja AS src
WHERE src.[date] >= @From AND src.[date] < @To
  AND NOT EXISTS (SELECT 1 FROM hr.workers_roster_kerja AS dst WHERE dst.id = src.id);

PRINT CONCAT('hr.workers_roster_kerja inserted: ', @@ROWCOUNT);

SET IDENTITY_INSERT hr.workers_roster_kerja OFF;

-- ---- soft-delete in-window rows removed from dbo ----
-- Safety: only when dbo actually holds rows for the window. An emptied / unseeded dbo copy
-- (e.g. truncated to free space) must NOT wipe the hr data; re-run seed_attendance_from_azure.js instead.
IF EXISTS (SELECT 1 FROM dbo.workers_roster_kerja WHERE [date] >= @From AND [date] < @To)
BEGIN
    UPDATE dst
    SET deleted_at = SYSUTCDATETIME(),
        deleted_by = NULL
    FROM hr.workers_roster_kerja AS dst
    WHERE dst.by_jobsite = @JobsiteId
      AND dst.deleted_at IS NULL
      AND dst.[date] >= @From AND dst.[date] < @To
      AND NOT EXISTS (SELECT 1 FROM dbo.workers_roster_kerja AS src WHERE src.id = dst.id);

    PRINT CONCAT('hr.workers_roster_kerja soft-deleted (missing in dbo): ', @@ROWCOUNT);
END
ELSE
    PRINT 'dbo.workers_roster_kerja has no rows in the window: soft-delete step skipped.';
GO
