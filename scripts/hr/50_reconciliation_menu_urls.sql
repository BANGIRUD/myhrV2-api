-- =============================================
-- Pola Kerja / Roster Kerja URLs follow parent
-- hr_reconciliation → /reconciliation/...
-- (not under /master — Master stays for master data)
-- Run AFTER 40 + 43
-- =============================================

DECLARE @JobsiteId INT = 1;

-- Parent folder: keep non-navigable "#" (sidebar expand only)
UPDATE hr.menus
SET menu_url = N'#',
    updated_at = SYSUTCDATETIME(),
    updated_by = NULL
WHERE by_jobsite = @JobsiteId
  AND menu_code = N'hr_reconciliation'
  AND deleted_at IS NULL;

UPDATE hr.menus
SET menu_url = N'/reconciliation/pola-kerja',
    updated_at = SYSUTCDATETIME(),
    updated_by = NULL
WHERE by_jobsite = @JobsiteId
  AND menu_code = N'hr_pola_kerja'
  AND deleted_at IS NULL;

UPDATE hr.menus
SET menu_url = N'/reconciliation/roster-kerja',
    updated_at = SYSUTCDATETIME(),
    updated_by = NULL
WHERE by_jobsite = @JobsiteId
  AND menu_code = N'hr_roster_kerja'
  AND deleted_at IS NULL;

DECLARE @PolaOk INT = (
    SELECT COUNT(*) FROM hr.menus
    WHERE by_jobsite = @JobsiteId AND menu_code = N'hr_pola_kerja'
      AND menu_url = N'/reconciliation/pola-kerja' AND deleted_at IS NULL
);
DECLARE @RosterOk INT = (
    SELECT COUNT(*) FROM hr.menus
    WHERE by_jobsite = @JobsiteId AND menu_code = N'hr_roster_kerja'
      AND menu_url = N'/reconciliation/roster-kerja' AND deleted_at IS NULL
);
PRINT CONCAT('reconciliation URLs: pola=', @PolaOk, ' roster=', @RosterOk);
GO
