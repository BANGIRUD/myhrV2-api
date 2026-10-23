-- =============================================
-- Sidebar menu "Pola Kerja" under Reconciliation (legacy home)
-- hr_pola_kerja -> /reconciliation/pola-kerja (under parent hr_reconciliation)
-- Idempotent: re-homes / inserts hr_pola_kerja under hr_reconciliation.
-- Run AFTER 13_wave1_sidebar_menus.sql and 39_pola_kerja_sp.sql
-- Write flags for approval_stage=all are applied by 41_pola_kerja_permissions_crud.sql
-- =============================================
DECLARE @JobsiteId INT = 1;

DECLARE @ReconId INT = (
    SELECT TOP 1 id FROM hr.menus
    WHERE by_jobsite = @JobsiteId AND menu_code = N'hr_reconciliation' AND deleted_at IS NULL
);

IF @ReconId IS NULL
BEGIN
    THROW 50044, 'hr_reconciliation menu missing. Seed legacy menus / wave sidebar first.', 1;
END;

-- Keep Reconciliation visible in the sidebar when hosting Pola Kerja
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
    WHERE by_jobsite = @JobsiteId AND menu_code = N'hr_pola_kerja' AND deleted_at IS NULL
)
BEGIN
    UPDATE hr.menus
    SET menu_name = N'Pola Kerja',
        menu_url = N'/reconciliation/pola-kerja',
        icon = N'task',
        menu_type = N'children',
        parent_id = @ReconId,
        sort_order = 1,
        show_sidebar = 1,
        is_active = 1,
        description = N'hr.workers_pola_kerja',
        updated_at = SYSUTCDATETIME(),
        updated_by = NULL
    WHERE by_jobsite = @JobsiteId
      AND menu_code = N'hr_pola_kerja'
      AND deleted_at IS NULL;
END
ELSE
BEGIN
    INSERT INTO hr.menus (
        by_jobsite, menu_code, menu_name, menu_url, icon, menu_type,
        parent_id, sort_order, show_sidebar, is_active, description, created_by
    )
    VALUES (
        @JobsiteId, N'hr_pola_kerja', N'Pola Kerja', N'/reconciliation/pola-kerja', N'task', N'children',
        @ReconId, 1, 1, 1, N'hr.workers_pola_kerja', NULL
    );
END;
GO

DECLARE @JobsiteId INT = 1;

-- Ensure every active level has a permission row (read at minimum; do not clamp writes)
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
  AND m.menu_code = N'hr_pola_kerja'
  AND NOT EXISTS (
      SELECT 1
      FROM hr.level_permissions lp
      WHERE lp.by_jobsite = @JobsiteId
        AND lp.level_id = l.id
        AND lp.menu_id = m.id
        AND lp.deleted_at IS NULL
  );
GO
