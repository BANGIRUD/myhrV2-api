-- =============================================
-- Sidebar: Employees (parent) + Employees SIS / Employees LS
--   hr_employees      → #                    (folder)
--   hr_employees_sis  → /employees/sis       (hr.workers)
--   hr_employees_ls   → /employees/ls        (hr.workers_vendor)
-- Read grants for HR / management levels.
-- Child SIS audience = sis; child LS audience = ls (narrows hr_admin by worker_scope).
-- Run AFTER 13_wave1_sidebar_menus.sql + 11_level_permissions.sql
-- =============================================
DECLARE @JobsiteId INT = 1;

DECLARE @ParentId INT = (
    SELECT TOP 1 id FROM hr.menus
    WHERE by_jobsite = @JobsiteId AND menu_code = N'hr_employees' AND deleted_at IS NULL
);

IF @ParentId IS NULL
BEGIN
    INSERT INTO hr.menus (
        by_jobsite, menu_code, menu_name, menu_url, icon, menu_type,
        parent_id, sort_order, show_sidebar, is_active, description, created_by
    )
    VALUES (
        @JobsiteId, N'hr_employees', N'Employees', N'#', N'group', N'parents',
        NULL, 25, 1, 1, N'Employee master (SIS / LS)', NULL
    );
    SET @ParentId = SCOPE_IDENTITY();
END
ELSE
BEGIN
    UPDATE hr.menus
    SET menu_name = N'Employees',
        menu_url = N'#',
        icon = N'group',
        menu_type = N'parents',
        parent_id = NULL,
        sort_order = 25,
        show_sidebar = 1,
        is_active = 1,
        description = N'Employee master (SIS / LS)',
        updated_at = SYSUTCDATETIME(),
        updated_by = NULL
    WHERE id = @ParentId
      AND by_jobsite = @JobsiteId
      AND deleted_at IS NULL;
END;

-- Employees SIS
IF EXISTS (
    SELECT 1 FROM hr.menus
    WHERE by_jobsite = @JobsiteId AND menu_code = N'hr_employees_sis' AND deleted_at IS NULL
)
BEGIN
    UPDATE hr.menus
    SET menu_name = N'Employees SIS',
        menu_url = N'/employees/sis',
        icon = N'user',
        menu_type = N'children',
        parent_id = @ParentId,
        sort_order = 1,
        show_sidebar = 1,
        is_active = 1,
        description = N'hr.workers',
        updated_at = SYSUTCDATETIME(),
        updated_by = NULL
    WHERE by_jobsite = @JobsiteId
      AND menu_code = N'hr_employees_sis'
      AND deleted_at IS NULL;
END
ELSE
BEGIN
    INSERT INTO hr.menus (
        by_jobsite, menu_code, menu_name, menu_url, icon, menu_type,
        parent_id, sort_order, show_sidebar, is_active, description, created_by
    )
    VALUES (
        @JobsiteId, N'hr_employees_sis', N'Employees SIS', N'/employees/sis', N'user', N'children',
        @ParentId, 1, 1, 1, N'hr.workers', NULL
    );
END;

-- Employees LS
IF EXISTS (
    SELECT 1 FROM hr.menus
    WHERE by_jobsite = @JobsiteId AND menu_code = N'hr_employees_ls' AND deleted_at IS NULL
)
BEGIN
    UPDATE hr.menus
    SET menu_name = N'Employees LS',
        menu_url = N'/employees/ls',
        icon = N'user-circle',
        menu_type = N'children',
        parent_id = @ParentId,
        sort_order = 2,
        show_sidebar = 1,
        is_active = 1,
        description = N'hr.workers_vendor',
        updated_at = SYSUTCDATETIME(),
        updated_by = NULL
    WHERE by_jobsite = @JobsiteId
      AND menu_code = N'hr_employees_ls'
      AND deleted_at IS NULL;
END
ELSE
BEGIN
    INSERT INTO hr.menus (
        by_jobsite, menu_code, menu_name, menu_url, icon, menu_type,
        parent_id, sort_order, show_sidebar, is_active, description, created_by
    )
    VALUES (
        @JobsiteId, N'hr_employees_ls', N'Employees LS', N'/employees/ls', N'user-circle', N'children',
        @ParentId, 2, 1, 1, N'hr.workers_vendor', NULL
    );
END;
GO

DECLARE @JobsiteId INT = 1;

-- Parent folder: whole-level read (no audience)
INSERT INTO hr.level_permissions (
    by_jobsite, level_id, menu_id,
    can_read, can_insert, can_update, can_delete, can_export, can_approve,
    audience, created_by
)
SELECT
    @JobsiteId,
    l.id,
    m.id,
    1, 0, 0, 0, 0, 0,
    NULL,
    NULL
FROM hr.levels l
CROSS JOIN hr.menus m
WHERE l.by_jobsite = @JobsiteId
  AND l.deleted_at IS NULL
  AND l.is_active = 1
  AND l.code IN (N'superadmin', N'sa', N'management', N'hr_admin', N'hr_administrator')
  AND m.by_jobsite = @JobsiteId
  AND m.deleted_at IS NULL
  AND m.menu_code = N'hr_employees'
  AND NOT EXISTS (
      SELECT 1
      FROM hr.level_permissions lp
      WHERE lp.by_jobsite = @JobsiteId
        AND lp.level_id = l.id
        AND lp.menu_id = m.id
        AND lp.deleted_at IS NULL
  );
GO

DECLARE @JobsiteId INT = 1;

-- Employees SIS: audience sis (hr_admin with worker_scope=ls will not see this menu)
INSERT INTO hr.level_permissions (
    by_jobsite, level_id, menu_id,
    can_read, can_insert, can_update, can_delete, can_export, can_approve,
    audience, created_by
)
SELECT
    @JobsiteId,
    l.id,
    m.id,
    1, 0, 0, 0, 0, 0,
    CASE WHEN l.code = N'hr_admin' THEN N'sis' ELSE NULL END,
    NULL
FROM hr.levels l
CROSS JOIN hr.menus m
WHERE l.by_jobsite = @JobsiteId
  AND l.deleted_at IS NULL
  AND l.is_active = 1
  AND l.code IN (N'superadmin', N'sa', N'management', N'hr_admin', N'hr_administrator')
  AND m.by_jobsite = @JobsiteId
  AND m.deleted_at IS NULL
  AND m.menu_code = N'hr_employees_sis'
  AND NOT EXISTS (
      SELECT 1
      FROM hr.level_permissions lp
      WHERE lp.by_jobsite = @JobsiteId
        AND lp.level_id = l.id
        AND lp.menu_id = m.id
        AND lp.deleted_at IS NULL
  );

-- Keep audience in sync on re-run for existing hr_admin rows
UPDATE lp
SET audience = N'sis',
    updated_at = SYSUTCDATETIME()
FROM hr.level_permissions lp
INNER JOIN hr.levels l ON l.id = lp.level_id AND l.deleted_at IS NULL
INNER JOIN hr.menus m ON m.id = lp.menu_id AND m.deleted_at IS NULL
WHERE lp.by_jobsite = @JobsiteId
  AND lp.deleted_at IS NULL
  AND l.code = N'hr_admin'
  AND m.menu_code = N'hr_employees_sis';
GO

DECLARE @JobsiteId INT = 1;

-- Employees LS: audience ls
INSERT INTO hr.level_permissions (
    by_jobsite, level_id, menu_id,
    can_read, can_insert, can_update, can_delete, can_export, can_approve,
    audience, created_by
)
SELECT
    @JobsiteId,
    l.id,
    m.id,
    1, 0, 0, 0, 0, 0,
    CASE WHEN l.code = N'hr_admin' THEN N'ls' ELSE NULL END,
    NULL
FROM hr.levels l
CROSS JOIN hr.menus m
WHERE l.by_jobsite = @JobsiteId
  AND l.deleted_at IS NULL
  AND l.is_active = 1
  AND l.code IN (N'superadmin', N'sa', N'management', N'hr_admin', N'hr_administrator')
  AND m.by_jobsite = @JobsiteId
  AND m.deleted_at IS NULL
  AND m.menu_code = N'hr_employees_ls'
  AND NOT EXISTS (
      SELECT 1
      FROM hr.level_permissions lp
      WHERE lp.by_jobsite = @JobsiteId
        AND lp.level_id = l.id
        AND lp.menu_id = m.id
        AND lp.deleted_at IS NULL
  );

UPDATE lp
SET audience = N'ls',
    updated_at = SYSUTCDATETIME()
FROM hr.level_permissions lp
INNER JOIN hr.levels l ON l.id = lp.level_id AND l.deleted_at IS NULL
INNER JOIN hr.menus m ON m.id = lp.menu_id AND m.deleted_at IS NULL
WHERE lp.by_jobsite = @JobsiteId
  AND lp.deleted_at IS NULL
  AND l.code = N'hr_admin'
  AND m.menu_code = N'hr_employees_ls';
GO
