-- =============================================
-- Menu Sakit under Department → SIA Karyawan
-- hr_sakit_department → /department/sakit
-- Read + approve for department_head only.
-- Run AFTER 63_sakit_department_approval.sql
-- =============================================
DECLARE @JobsiteId INT = 1;

DECLARE @SiaId INT = (
    SELECT TOP 1 c.id
    FROM hr.menus c
    INNER JOIN hr.menus p
        ON p.id = c.parent_id
       AND p.by_jobsite = c.by_jobsite
       AND p.deleted_at IS NULL
    WHERE c.by_jobsite = @JobsiteId
      AND c.deleted_at IS NULL
      AND c.menu_name = N'SIA Karyawan'
      AND p.menu_name = N'Department'
);

IF @SiaId IS NULL
BEGIN
    THROW 50064, 'Department → SIA Karyawan menu missing.', 1;
END;

UPDATE hr.menus
SET show_sidebar = 1, is_active = 1, updated_at = SYSUTCDATETIME(), updated_by = NULL
WHERE by_jobsite = @JobsiteId
  AND deleted_at IS NULL
  AND id IN (
      SELECT @SiaId
      UNION
      SELECT parent_id FROM hr.menus WHERE id = @SiaId
  );

IF EXISTS (
    SELECT 1 FROM hr.menus
    WHERE by_jobsite = @JobsiteId AND menu_code = N'hr_sakit_department' AND deleted_at IS NULL
)
BEGIN
    UPDATE hr.menus
    SET menu_name = N'Sakit',
        menu_url = N'/department/sakit',
        icon = N'alert',
        menu_type = N'children',
        parent_id = @SiaId,
        sort_order = 1,
        show_sidebar = 1,
        is_active = 1,
        description = N'Department approval queue for sakit',
        updated_at = SYSUTCDATETIME(),
        updated_by = NULL
    WHERE by_jobsite = @JobsiteId AND menu_code = N'hr_sakit_department' AND deleted_at IS NULL;
END
ELSE
BEGIN
    INSERT INTO hr.menus (
        by_jobsite, menu_code, menu_name, menu_url, icon, menu_type,
        parent_id, sort_order, show_sidebar, is_active, description, created_by
    )
    VALUES (
        @JobsiteId, N'hr_sakit_department', N'Sakit', N'/department/sakit', N'alert', N'children',
        @SiaId, 1, 1, 1, N'Department approval queue for sakit', NULL
    );
END;
GO

DECLARE @JobsiteId INT = 1;

INSERT INTO hr.level_permissions (
    by_jobsite, level_id, menu_id,
    can_read, can_insert, can_update, can_delete, can_export, can_approve,
    created_by
)
SELECT
    @JobsiteId, l.id, m.id,
    CASE WHEN LOWER(l.code) = N'department_head' THEN 1 ELSE 0 END,
    0, 0, 0, 0,
    CASE WHEN LOWER(l.code) = N'department_head' THEN 1 ELSE 0 END,
    NULL
FROM hr.levels l
CROSS JOIN hr.menus m
WHERE l.by_jobsite = @JobsiteId
  AND l.deleted_at IS NULL
  AND l.is_active = 1
  AND m.by_jobsite = @JobsiteId
  AND m.deleted_at IS NULL
  AND m.menu_code = N'hr_sakit_department'
  AND NOT EXISTS (
      SELECT 1 FROM hr.level_permissions lp
      WHERE lp.by_jobsite = @JobsiteId
        AND lp.level_id = l.id
        AND lp.menu_id = m.id
        AND lp.deleted_at IS NULL
  );

UPDATE lp
SET can_read = CASE WHEN LOWER(l.code) = N'department_head' THEN 1 ELSE 0 END,
    can_approve = CASE WHEN LOWER(l.code) = N'department_head' THEN 1 ELSE 0 END,
    can_insert = 0,
    can_update = 0,
    can_delete = 0,
    can_export = 0,
    updated_at = SYSUTCDATETIME(),
    updated_by = NULL
FROM hr.level_permissions lp
INNER JOIN hr.menus m ON m.id = lp.menu_id AND m.by_jobsite = lp.by_jobsite
INNER JOIN hr.levels l ON l.id = lp.level_id AND l.by_jobsite = lp.by_jobsite
WHERE lp.by_jobsite = @JobsiteId
  AND lp.deleted_at IS NULL
  AND m.menu_code = N'hr_sakit_department'
  AND l.deleted_at IS NULL;

PRINT 'hr_sakit_department menu ready';
GO
