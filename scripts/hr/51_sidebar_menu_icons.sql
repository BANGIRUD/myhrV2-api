-- =============================================
-- Distinct sidebar icons for HR menus
-- Keys must match frontend src/config/sidebarIcons.tsx
-- =============================================

DECLARE @JobsiteId INT = 1;

UPDATE hr.menus SET icon = v.icon, updated_at = SYSUTCDATETIME(), updated_by = NULL
FROM hr.menus m
INNER JOIN (VALUES
    (N'hr_dashboard',        N'pie-chart'),
    (N'hr_master',           N'folder'),
    (N'hr_jobsites',         N'box'),
    (N'hr_levels',           N'table'),
    (N'hr_users',            N'group'),
    (N'hr_menus',            N'page'),
    (N'hr_enums',            N'docs'),
    (N'hr_edit_policy',      N'pencil'),
    (N'hr_menu_privilege',   N'eye'),
    (N'hr_level_permissions',N'lock'),
    (N'hr_reconciliation',   N'check-circle'),
    (N'hr_pola_kerja',       N'task'),
    (N'hr_roster_kerja',     N'calendar'),
    (N'hr_profile',          N'user-circle')
) AS v(menu_code, icon)
    ON m.menu_code = v.menu_code
WHERE m.by_jobsite = @JobsiteId
  AND m.deleted_at IS NULL;

PRINT CONCAT('sidebar icons updated: ', @@ROWCOUNT);
GO
