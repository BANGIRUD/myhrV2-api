-- =============================================
-- Master Data menu for every pengajuan (hr.v_active_submissions).
-- Read: superadmin, sa, hr_administrator.
-- Run AFTER 76_active_submissions.sql
-- =============================================
DECLARE @JobsiteId INT = 1;

DECLARE @MasterId INT = (
    SELECT TOP 1 id FROM hr.menus
    WHERE by_jobsite = @JobsiteId AND menu_code = N'hr_master' AND deleted_at IS NULL
);

IF @MasterId IS NOT NULL
   AND NOT EXISTS (
       SELECT 1 FROM hr.menus
       WHERE by_jobsite = @JobsiteId AND menu_code = N'hr_submissions' AND deleted_at IS NULL
   )
BEGIN
    INSERT INTO hr.menus (
        by_jobsite, menu_code, menu_name, menu_url, icon, menu_type,
        parent_id, sort_order, show_sidebar, is_active, description, created_by
    )
    VALUES (
        @JobsiteId, N'hr_submissions', N'Submissions', N'/master/submissions', N'task', N'children',
        @MasterId, 29, 1, 1, N'All sickness and permit requests', NULL
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
    1, 0, 0, 0, 0, 0,
    NULL
FROM hr.levels l
CROSS JOIN hr.menus m
WHERE l.by_jobsite = @JobsiteId
  AND l.deleted_at IS NULL
  AND l.is_active = 1
  AND l.code IN (N'superadmin', N'sa', N'hr_administrator')
  AND m.by_jobsite = @JobsiteId
  AND m.deleted_at IS NULL
  AND m.menu_code = N'hr_submissions'
  AND NOT EXISTS (
      SELECT 1
      FROM hr.level_permissions lp
      WHERE lp.by_jobsite = @JobsiteId
        AND lp.level_id = l.id
        AND lp.menu_id = m.id
        AND lp.deleted_at IS NULL
  );
GO
