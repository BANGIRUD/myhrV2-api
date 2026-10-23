-- =============================================
-- Sidebar menu "Sakit" under Reconciliation
-- hr_sakit -> /reconciliation/sakit (under parent hr_reconciliation)
-- Idempotent. Fase 1: can_read for all levels; writes off.
-- Run AFTER 52_sakit_sp.sql
-- =============================================
DECLARE @JobsiteId INT = 1;

DECLARE @ReconId INT = (
    SELECT TOP 1 id FROM hr.menus
    WHERE by_jobsite = @JobsiteId AND menu_code = N'hr_reconciliation' AND deleted_at IS NULL
);

IF @ReconId IS NULL
BEGIN
    THROW 50053, 'hr_reconciliation menu missing. Seed legacy menus / wave sidebar first.', 1;
END;

UPDATE hr.menus
SET show_sidebar = 1,
    is_active = 1,
    updated_at = SYSUTCDATETIME(),
    updated_by = NULL
WHERE id = @ReconId
  AND by_jobsite = @JobsiteId
  AND deleted_at IS NULL;

IF EXISTS (
    SELECT 1 FROM hr.menus
    WHERE by_jobsite = @JobsiteId AND menu_code = N'hr_sakit' AND deleted_at IS NULL
)
BEGIN
    UPDATE hr.menus
    SET menu_name = N'Sakit',
        menu_url = N'/reconciliation/sakit',
        icon = N'alert',
        menu_type = N'children',
        parent_id = @ReconId,
        sort_order = 3,
        show_sidebar = 1,
        is_active = 1,
        description = N'hr.workers_sickness',
        updated_at = SYSUTCDATETIME(),
        updated_by = NULL
    WHERE by_jobsite = @JobsiteId
      AND menu_code = N'hr_sakit'
      AND deleted_at IS NULL;
END
ELSE
BEGIN
    INSERT INTO hr.menus (
        by_jobsite, menu_code, menu_name, menu_url, icon, menu_type,
        parent_id, sort_order, show_sidebar, is_active, description, created_by
    )
    VALUES (
        @JobsiteId, N'hr_sakit', N'Sakit', N'/reconciliation/sakit', N'alert', N'children',
        @ReconId, 3, 1, 1, N'hr.workers_sickness', NULL
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
    0,
    0,
    0,
    0,
     0,

        NULL
FROM hr.levels l
CROSS JOIN hr.menus m
WHERE l.by_jobsite = @JobsiteId
  AND l.deleted_at IS NULL
  AND l.is_active = 1
  AND m.by_jobsite = @JobsiteId
  AND m.deleted_at IS NULL
  AND m.menu_code = N'hr_sakit'
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

-- Fase 1: read-only for everyone
UPDATE lp
SET can_read = 1,
    can_insert = 0,
    can_update = 0,
    can_delete = 0,
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
