-- =============================================
-- Phase 2: grant write on hr_sakit for all-access levels
-- (approval_stage = all). Cancel uses can_delete.
-- can_approve stays 0 (Section/HR approval is later).
-- Run AFTER 53_sakit_menu.sql
-- =============================================
DECLARE @JobsiteId INT = 1;

UPDATE lp
SET can_read = 1,
    can_insert = CASE WHEN l.approval_stage = N'all' THEN 1 ELSE 0 END,
    can_update = CASE WHEN l.approval_stage = N'all' THEN 1 ELSE 0 END,
    can_delete = CASE WHEN l.approval_stage = N'all' THEN 1 ELSE 0 END,
    can_export = 0,
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
  AND m.menu_code = N'hr_sakit'
  AND l.deleted_at IS NULL;

PRINT CONCAT('hr_sakit permissions updated: ', @@ROWCOUNT);
GO
