-- =============================================
-- Phase 2: grant write on hr_pola_kerja for all-access levels
-- (approval_stage = all), keep others read-only.
-- Run AFTER 40_pola_kerja_menu.sql
-- =============================================
DECLARE @JobsiteId INT = 1;

UPDATE lp
SET can_read = 1,
    can_insert = CASE WHEN l.approval_stage = N'all' THEN 1 ELSE 0 END,
    can_update = CASE WHEN l.approval_stage = N'all' THEN 1 ELSE 0 END,
    can_delete = CASE WHEN l.approval_stage = N'all' THEN 1 ELSE 0 END,
    can_export = CASE WHEN l.approval_stage = N'all' THEN 1 ELSE 0 END,
    can_approve = 0,
    updated_at = SYSUTCDATETIME(),
    updated_by = NULL
FROM hr.level_permissions lp
INNER JOIN hr.menus m
    ON m.id = lp.menu_id
   AND m.by_jobsite = lp.by_jobsite
INNER JOIN hr.levels l
    ON l.id = lp.level_id
   AND l.by_jobsite = lp.by_jobsite
WHERE lp.by_jobsite = @JobsiteId
  AND lp.deleted_at IS NULL
  AND m.deleted_at IS NULL
  AND m.menu_code = N'hr_pola_kerja'
  AND l.deleted_at IS NULL;

PRINT CONCAT('hr_pola_kerja permissions updated: ', @@ROWCOUNT);
GO
