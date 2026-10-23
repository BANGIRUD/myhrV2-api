-- =============================================
-- Sidebar menu "Enums" under Master Data (hr_enums -> /master/enums)
-- Run AFTER 13_wave1_sidebar_menus.sql and 25_enums_sp.sql
-- =============================================
DECLARE @JobsiteId INT = 1;

DECLARE @MasterId INT = (
    SELECT TOP 1 id FROM hr.menus
    WHERE by_jobsite = @JobsiteId AND menu_code = N'hr_master' AND deleted_at IS NULL
);

IF @MasterId IS NOT NULL
   AND NOT EXISTS (
       SELECT 1 FROM hr.menus
       WHERE by_jobsite = @JobsiteId AND menu_code = N'hr_enums' AND deleted_at IS NULL
   )
BEGIN
    INSERT INTO hr.menus (
        by_jobsite, menu_code, menu_name, menu_url, icon, menu_type,
        parent_id, sort_order, show_sidebar, is_active, description, created_by
    )
    VALUES (
        @JobsiteId, N'hr_enums', N'Enums', N'/master/enums', N'list', N'children',
        @MasterId, 27, 1, 1, N'hr.enums', NULL
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
    @JobsiteId,
    l.id,
    m.id,
    1,
    CASE WHEN l.approval_stage = N'all' THEN 1 ELSE 0 END,
    CASE WHEN l.approval_stage = N'all' THEN 1 ELSE 0 END,
    CASE WHEN l.approval_stage = N'all' THEN 1 ELSE 0 END,
    CASE WHEN l.approval_stage = N'all' THEN 1 ELSE 0 END,
    CASE WHEN l.approval_stage IN (N'superior', N'hr', N'all') THEN 1 ELSE 0 END,
    NULL
FROM hr.levels l
CROSS JOIN hr.menus m
WHERE l.by_jobsite = @JobsiteId
  AND l.deleted_at IS NULL
  AND l.is_active = 1
  AND m.by_jobsite = @JobsiteId
  AND m.deleted_at IS NULL
  AND m.menu_code = N'hr_enums'
  AND NOT EXISTS (
      SELECT 1
      FROM hr.level_permissions lp
      WHERE lp.by_jobsite = @JobsiteId
        AND lp.level_id = l.id
        AND lp.menu_id = m.id
        AND lp.deleted_at IS NULL
  );
GO
