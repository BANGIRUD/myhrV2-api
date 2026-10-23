-- =============================================
-- Sidebar: Roster Edit Policy under Master Data
-- hr_roster_edit_policy -> /master/roster-edit-policy
-- All levels: can_read
-- approval_stage = all: insert/update/delete
-- Run AFTER 46_roster_edit_policy_sp.sql + 45_roster_edit_policy.sql
-- =============================================
DECLARE @JobsiteId INT = 1;

DECLARE @MasterId INT = (
    SELECT TOP 1 id FROM hr.menus
    WHERE by_jobsite = @JobsiteId AND menu_code = N'hr_master' AND deleted_at IS NULL
);

IF @MasterId IS NULL
BEGIN
    THROW 50046, 'hr_master menu missing. Seed wave-1 sidebar first.', 1;
END;

IF EXISTS (
    SELECT 1 FROM hr.menus
    WHERE by_jobsite = @JobsiteId AND menu_code = N'hr_roster_edit_policy' AND deleted_at IS NULL
)
BEGIN
    UPDATE hr.menus
    SET menu_name = N'Roster Edit Policy',
        menu_url = N'/master/roster-edit-policy',
        icon = N'settings',
        menu_type = N'children',
        parent_id = @MasterId,
        sort_order = 28,
        show_sidebar = 1,
        is_active = 1,
        description = N'hr.roster_edit_policy — H-n window per level',
        updated_at = SYSUTCDATETIME(),
        updated_by = NULL
    WHERE by_jobsite = @JobsiteId
      AND menu_code = N'hr_roster_edit_policy'
      AND deleted_at IS NULL;
END
ELSE
BEGIN
    INSERT INTO hr.menus (
        by_jobsite, menu_code, menu_name, menu_url, icon, menu_type,
        parent_id, sort_order, show_sidebar, is_active, description, created_by
    )
    VALUES (
        @JobsiteId, N'hr_roster_edit_policy', N'Roster Edit Policy',
        N'/master/roster-edit-policy', N'settings', N'children',
        @MasterId, 28, 1, 1, N'hr.roster_edit_policy — H-n window per level', NULL
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
  AND m.menu_code = N'hr_roster_edit_policy'
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

UPDATE lp
SET can_read = 1,
    can_insert = CASE WHEN l.approval_stage = N'all' THEN 1 ELSE 0 END,
    can_update = CASE WHEN l.approval_stage = N'all' THEN 1 ELSE 0 END,
    can_delete = CASE WHEN l.approval_stage = N'all' THEN 1 ELSE 0 END,
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
  AND m.menu_code = N'hr_roster_edit_policy'
  AND l.deleted_at IS NULL;

PRINT CONCAT('hr_roster_edit_policy permissions updated: ', @@ROWCOUNT);
GO
