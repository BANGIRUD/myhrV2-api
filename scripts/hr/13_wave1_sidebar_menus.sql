-- =============================================
-- Wave-1 sidebar: only menus for existing hr.* tables
-- Hides legacy CI menus from sidebar; keeps rows for permission ETL.
-- Run AFTER 11_level_permissions.sql
-- =============================================
DECLARE @JobsiteId INT = 1;

IF NOT EXISTS (SELECT 1 FROM hr.jobsites WHERE id = @JobsiteId AND deleted_at IS NULL)
BEGIN
    THROW 50030, 'hr.jobsites id=1 missing. Run 02_jobsites.sql first.', 1;
END;

-- Hide legacy sidebar entries (keep data; not shown in React nav)
UPDATE hr.menus
SET show_sidebar = 0,
    updated_at = SYSUTCDATETIME(),
    updated_by = NULL
WHERE by_jobsite = @JobsiteId
  AND deleted_at IS NULL
  AND show_sidebar = 1
  AND menu_code NOT LIKE N'hr_%';

PRINT CONCAT('Legacy menus hidden from sidebar: ', @@ROWCOUNT);
GO

DECLARE @JobsiteId INT = 1;

-- Parent: Master Data
IF NOT EXISTS (
    SELECT 1 FROM hr.menus
    WHERE by_jobsite = @JobsiteId AND menu_code = N'hr_master' AND deleted_at IS NULL
)
BEGIN
    INSERT INTO hr.menus (
        by_jobsite, menu_code, menu_name, menu_url, icon, menu_type,
        parent_id, sort_order, show_sidebar, is_active, description, created_by
    )
    VALUES (
        @JobsiteId, N'hr_master', N'Master Data', N'#', N'list', N'parents',
        NULL, 20, 1, 1, N'Wave-1 master based on existing hr tables', NULL
    );
END;

DECLARE @MasterId INT = (
    SELECT TOP 1 id FROM hr.menus
    WHERE by_jobsite = @JobsiteId AND menu_code = N'hr_master' AND deleted_at IS NULL
);

;WITH wave1 AS (
    SELECT * FROM (VALUES
        (N'hr_dashboard', N'Dashboard', N'/', N'grid', N'children', NULL, 10, 1, N'Home dashboard'),
        (N'hr_jobsites', N'Jobsites', N'/master/jobsites', N'table', N'children', @MasterId, 21, 1, N'hr.jobsites'),
        (N'hr_levels', N'Levels', N'/master/levels', N'table', N'children', @MasterId, 22, 1, N'hr.levels'),
        (N'hr_users', N'Users', N'/master/users', N'user', N'children', @MasterId, 23, 1, N'hr.users'),
        (N'hr_menus', N'Menus', N'/master/menus', N'list', N'children', @MasterId, 24, 1, N'hr.menus'),
        (N'hr_menu_privilege', N'Menu Privilege', N'/master/menu-privilege', N'list', N'children', @MasterId, 25, 1, N'hr.menu_privilege'),
        (N'hr_level_permissions', N'Level Permissions', N'/master/level-permissions', N'list', N'children', @MasterId, 26, 1, N'hr.level_permissions'),
        (N'hr_profile', N'User Profile', N'/profile', N'user', N'children', NULL, 90, 1, N'Signed-in profile')
    ) AS v(menu_code, menu_name, menu_url, icon, menu_type, parent_id, sort_order, show_sidebar, description)
)
INSERT INTO hr.menus (
    by_jobsite, menu_code, menu_name, menu_url, icon, menu_type,
    parent_id, sort_order, show_sidebar, is_active, description, created_by
)
SELECT
    @JobsiteId,
    w.menu_code,
    w.menu_name,
    w.menu_url,
    w.icon,
    w.menu_type,
    w.parent_id,
    w.sort_order,
    w.show_sidebar,
    1,
    w.description, NULL
FROM wave1 w
WHERE NOT EXISTS (
    SELECT 1 FROM hr.menus m
    WHERE m.by_jobsite = @JobsiteId
      AND m.menu_code = w.menu_code
      AND m.deleted_at IS NULL
);

PRINT CONCAT('Wave-1 menus inserted: ', @@ROWCOUNT);
GO

-- Ensure wave-1 rows stay visible / active (re-run safe)
UPDATE hr.menus
SET show_sidebar = 1,
    is_active = 1,
    updated_at = SYSUTCDATETIME(),
    updated_by = NULL
WHERE by_jobsite = 1
  AND deleted_at IS NULL
  AND menu_code LIKE N'hr_%';
GO

-- Grant read on wave-1 menus to every active level (temporary)
DECLARE @JobsiteId INT = 1;

INSERT INTO hr.level_permissions (
    by_jobsite, level_id, menu_id,
    can_read, can_insert, can_update, can_delete, can_export, can_approve,
    created_by
)
SELECT
    @JobsiteId,
    l.id,
    m.id,
    1,
    CASE WHEN l.approval_stage = N'all' THEN 1 ELSE 0 END,
    CASE WHEN l.approval_stage = N'all' THEN 1 ELSE 0 END,
    CASE WHEN l.approval_stage = N'all' THEN 1 ELSE 0 END,
    CASE WHEN l.approval_stage = N'all' THEN 1 ELSE 0 END,
    CASE WHEN l.approval_stage IN (N'superior', N'hr', N'all') THEN 1 ELSE 0 END, NULL
FROM hr.levels l
CROSS JOIN hr.menus m
WHERE l.by_jobsite = @JobsiteId
  AND l.deleted_at IS NULL
  AND l.is_active = 1
  AND m.by_jobsite = @JobsiteId
  AND m.deleted_at IS NULL
  AND m.menu_code LIKE N'hr_%'
  AND NOT EXISTS (
      SELECT 1
      FROM hr.level_permissions lp
      WHERE lp.by_jobsite = @JobsiteId
        AND lp.level_id = l.id
        AND lp.menu_id = m.id
        AND lp.deleted_at IS NULL
  );

PRINT CONCAT('Wave-1 level_permissions inserted: ', @@ROWCOUNT);
GO

SELECT menu_code, menu_name, menu_url, parent_id, sort_order, show_sidebar
FROM hr.menus
WHERE by_jobsite = 1 AND deleted_at IS NULL AND menu_code LIKE N'hr_%'
ORDER BY sort_order, menu_name;
GO
