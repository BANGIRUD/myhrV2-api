-- =============================================
-- Sidebar menu "Roster Kerja" under Reconciliation
-- hr_roster_kerja -> /reconciliation/roster-kerja (under parent hr_reconciliation)
-- Idempotent: re-homes / inserts under hr_reconciliation.
-- All levels: can_read=1
-- approval_stage = all: can_update + can_export (no insert/delete)
-- Run AFTER 40_pola_kerja_menu.sql + 42_roster_kerja_sp.sql
-- =============================================
DECLARE @JobsiteId INT = 1;

DECLARE @ReconId INT = (
    SELECT TOP 1 id FROM hr.menus
    WHERE by_jobsite = @JobsiteId AND menu_code = N'hr_reconciliation' AND deleted_at IS NULL
);

IF @ReconId IS NULL
BEGIN
    THROW 50045, 'hr_reconciliation menu missing. Seed legacy menus / wave sidebar first.', 1;
END;

-- Keep Reconciliation visible when hosting Roster Kerja
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
    WHERE by_jobsite = @JobsiteId AND menu_code = N'hr_roster_kerja' AND deleted_at IS NULL
)
BEGIN
    UPDATE hr.menus
    SET menu_name = N'Roster Kerja',
        menu_url = N'/reconciliation/roster-kerja',
        icon = N'calendar',
        menu_type = N'children',
        parent_id = @ReconId,
        sort_order = 2,
        show_sidebar = 1,
        is_active = 1,
        description = N'hr.workers_roster_kerja',
        updated_at = SYSUTCDATETIME(),
        updated_by = NULL
    WHERE by_jobsite = @JobsiteId
      AND menu_code = N'hr_roster_kerja'
      AND deleted_at IS NULL;
END
ELSE
BEGIN
    INSERT INTO hr.menus (
        by_jobsite, menu_code, menu_name, menu_url, icon, menu_type,
        parent_id, sort_order, show_sidebar, is_active, description, created_by
    )
    VALUES (
        @JobsiteId, N'hr_roster_kerja', N'Roster Kerja', N'/reconciliation/roster-kerja', N'calendar', N'children',
        @ReconId, 2, 1, 1, N'hr.workers_roster_kerja', NULL
    );
END;
GO

DECLARE @JobsiteId INT = 1;

-- Ensure every active level has a permission row (read at minimum)
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
  AND m.menu_code = N'hr_roster_kerja'
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

-- Grant update + export for approval_stage = all; keep insert/delete off
UPDATE lp
SET can_read = 1,
    can_insert = 0,
    can_update = CASE WHEN l.approval_stage = N'all' THEN 1 ELSE 0 END,
    can_delete = 0,
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
  AND m.menu_code = N'hr_roster_kerja'
  AND l.deleted_at IS NULL;

PRINT CONCAT('hr_roster_kerja permissions updated: ', @@ROWCOUNT);
GO
