-- =============================================
-- Sync: dbo.workers_pola_kerja → hr.workers_pola_kerja (rolling window)
-- Window is WIDER than roster: pola rows are sparse (typically 1st-of-month
-- seed per worker), not daily. Use month-24 .. month+3 so the menu has data
-- even when the newest seed lags the current month.
-- Idempotent; safe while the legacy app still writes to dbo:
--   1) updates hr rows whose source data differs
--   2) inserts source rows missing in hr
--   3) soft-deletes hr rows in the window that no longer exist in dbo
-- hr rows that have fallen out of the window (older than @From) are left untouched;
-- purge them manually when space is needed.
-- Run AFTER 37_workers_pola_kerja.sql
-- =============================================
SET NOCOUNT ON;

DECLARE @JobsiteId INT = 1;
DECLARE @From DATE = DATEFROMPARTS(YEAR(DATEADD(MONTH, -24, GETDATE())), MONTH(DATEADD(MONTH, -24, GETDATE())), 1);
DECLARE @To DATE = DATEFROMPARTS(YEAR(DATEADD(MONTH, 3, GETDATE())), MONTH(DATEADD(MONTH, 3, GETDATE())), 1);

IF NOT EXISTS (SELECT 1 FROM hr.jobsites WHERE id = @JobsiteId AND deleted_at IS NULL)
BEGIN
    THROW 50042, 'hr.jobsites id=1 (DEFAULT) missing. Run 02_jobsites.sql first.', 1;
END;

IF OBJECT_ID('hr.workers_pola_kerja', 'U') IS NULL
BEGIN
    THROW 50043, 'hr.workers_pola_kerja missing. Run 37_workers_pola_kerja.sql first.', 1;
END;

IF OBJECT_ID('dbo.workers_pola_kerja', 'U') IS NULL
BEGIN
    PRINT 'dbo.workers_pola_kerja missing: sync skipped.';
END
ELSE
BEGIN
    PRINT CONCAT('pola_kerja window: ', CONVERT(VARCHAR(10), @From), ' <= date < ', CONVERT(VARCHAR(10), @To));

    -- ---- update changed rows ----
    UPDATE dst
    SET
        [date] = src.[date],
        nrp = src.nrp,
        nrp_int = CAST(src.nrp_int AS NVARCHAR(50)),
        pola_kerja = src.pola_kerja,
        pola_cuti = src.pola_cuti,
        pola_hari = src.pola_hari,
        hari_ke = src.hari_ke,
        remark = src.remark,
        by_user = src.by_user,
        updated_at = src.updated_at,
        updated_by = TRY_CAST(src.by_user AS INT),
        deleted_at = src.deleted_at
    FROM hr.workers_pola_kerja AS dst
    INNER JOIN dbo.workers_pola_kerja AS src
        ON src.id = dst.id
    WHERE dst.by_jobsite = @JobsiteId
      AND src.[date] >= @From AND src.[date] < @To
      AND EXISTS (
        SELECT
            src.[date], src.nrp, CAST(src.nrp_int AS NVARCHAR(50)), src.pola_kerja, src.pola_cuti, src.pola_hari,
            src.hari_ke, src.remark, src.by_user, src.updated_at, src.deleted_at
        EXCEPT
        SELECT
            dst.[date], dst.nrp, dst.nrp_int, dst.pola_kerja, dst.pola_cuti, dst.pola_hari,
            dst.hari_ke, dst.remark, dst.by_user, dst.updated_at, dst.deleted_at
      );

    PRINT CONCAT('hr.workers_pola_kerja updated: ', @@ROWCOUNT);

    -- ---- insert missing rows ----
    SET IDENTITY_INSERT hr.workers_pola_kerja ON;

    INSERT INTO hr.workers_pola_kerja (
        id, by_jobsite, [date], nrp, nrp_int, pola_kerja, pola_cuti, pola_hari, hari_ke, remark,
        by_user, created_at, created_by, updated_at, updated_by, deleted_at, deleted_by, legacy_id
    )
    SELECT
        CAST(src.id AS INT), @JobsiteId, src.[date], src.nrp, CAST(src.nrp_int AS NVARCHAR(50)),
        src.pola_kerja, src.pola_cuti, src.pola_hari, src.hari_ke, src.remark, src.by_user,
        ISNULL(src.created_at, SYSUTCDATETIME()),
        TRY_CAST(src.by_user AS INT), src.updated_at, NULL, src.deleted_at, NULL, CAST(src.id AS INT)
    FROM dbo.workers_pola_kerja AS src
    WHERE src.[date] >= @From AND src.[date] < @To
      AND NOT EXISTS (SELECT 1 FROM hr.workers_pola_kerja AS dst WHERE dst.id = CAST(src.id AS INT));

    PRINT CONCAT('hr.workers_pola_kerja inserted: ', @@ROWCOUNT);

    SET IDENTITY_INSERT hr.workers_pola_kerja OFF;

    -- ---- soft-delete in-window rows removed from dbo ----
    IF EXISTS (SELECT 1 FROM dbo.workers_pola_kerja WHERE [date] >= @From AND [date] < @To)
    BEGIN
        UPDATE dst
        SET deleted_at = SYSUTCDATETIME(),
            deleted_by = NULL
        FROM hr.workers_pola_kerja AS dst
        WHERE dst.by_jobsite = @JobsiteId
          AND dst.deleted_at IS NULL
          AND dst.[date] >= @From AND dst.[date] < @To
          AND NOT EXISTS (
              SELECT 1 FROM dbo.workers_pola_kerja AS src WHERE CAST(src.id AS INT) = dst.id
          );

        PRINT CONCAT('hr.workers_pola_kerja soft-deleted (missing in dbo): ', @@ROWCOUNT);
    END
    ELSE
        PRINT 'dbo.workers_pola_kerja has no rows in the window: soft-delete step skipped.';
END
GO
