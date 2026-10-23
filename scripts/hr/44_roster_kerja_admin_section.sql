-- =============================================
-- Grant roster edit/export to admin_section (legacy admin).
-- Edit window H-n comes from hr.roster_edit_policy (script 45), not here.
-- Run AFTER 43_roster_kerja_menu.sql
-- =============================================
DECLARE @JobsiteId INT = 1;

UPDATE lp
SET can_read = 1,
    can_update = 1,
    can_export = 1,
    can_insert = 0,
    can_delete = 0,
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
  AND m.menu_code = N'hr_roster_kerja'
  AND l.deleted_at IS NULL
  AND l.code = N'admin_section';

PRINT CONCAT('hr_roster_kerja admin_section grants: ', @@ROWCOUNT);
GO
