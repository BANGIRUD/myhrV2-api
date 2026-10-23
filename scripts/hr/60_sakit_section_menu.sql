-- =============================================
-- Menu Sakit under Section → SIA Karyawan
-- hr_sakit_section → /section/sakit
-- Read + approve for section_head, and for levels that have a Unit Head login.
-- Run AFTER 59_sakit_section_approval.sql
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
      AND p.menu_name = N'Section'
);

IF @SiaId IS NULL
BEGIN
    THROW 50060, 'Section → SIA Karyawan menu missing.', 1;
END;

-- Show the folder path only (siblings stay hidden).
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
    WHERE by_jobsite = @JobsiteId AND menu_code = N'hr_sakit_section' AND deleted_at IS NULL
)
BEGIN
    UPDATE hr.menus
    SET menu_name = N'Sakit',
        menu_url = N'/section/sakit',
        icon = N'alert',
        menu_type = N'children',
        parent_id = @SiaId,
        sort_order = 1,
        show_sidebar = 1,
        is_active = 1,
        description = N'Section approval queue for sakit',
        updated_at = SYSUTCDATETIME(),
        updated_by = NULL
    WHERE by_jobsite = @JobsiteId AND menu_code = N'hr_sakit_section' AND deleted_at IS NULL;
END
ELSE
BEGIN
    INSERT INTO hr.menus (
        by_jobsite, menu_code, menu_name, menu_url, icon, menu_type,
        parent_id, sort_order, show_sidebar, is_active, description, created_by
    )
    VALUES (
        @JobsiteId, N'hr_sakit_section', N'Sakit', N'/section/sakit', N'alert', N'children',
        @SiaId, 1, 1, 1, N'Section approval queue for sakit', NULL
    );
END;
GO

DECLARE @JobsiteId INT = 1;
DECLARE @UhRank INT = (
    SELECT TOP 1 id FROM hr.enums
    WHERE by_jobsite = @JobsiteId AND deleted_at IS NULL
      AND type = N'position' AND LOWER(name) = N'unit head'
);

INSERT INTO hr.level_permissions (
    by_jobsite, level_id, menu_id,
    can_read, can_insert, can_update, can_delete, can_export, can_approve,
    created_by
)
SELECT
    @JobsiteId, l.id, m.id,
    CASE
        WHEN LOWER(l.code) = N'section_head' THEN 1
        WHEN EXISTS (
            SELECT 1
            FROM hr.users u
            INNER JOIN hr.v_workers_active wa
                ON wa.by_jobsite = u.by_jobsite AND wa.nrp = u.username
            WHERE u.level_id = l.id
              AND u.by_jobsite = @JobsiteId
              AND u.deleted_at IS NULL
              AND wa.job_rank = @UhRank
        ) THEN 1
        ELSE 0
    END,
    0, 0, 0, 0,
    CASE
        WHEN LOWER(l.code) = N'section_head' THEN 1
        WHEN EXISTS (
            SELECT 1
            FROM hr.users u
            INNER JOIN hr.v_workers_active wa
                ON wa.by_jobsite = u.by_jobsite AND wa.nrp = u.username
            WHERE u.level_id = l.id
              AND u.by_jobsite = @JobsiteId
              AND u.deleted_at IS NULL
              AND wa.job_rank = @UhRank
        ) THEN 1
        ELSE 0
    END,
    NULL
FROM hr.levels l
CROSS JOIN hr.menus m
WHERE l.by_jobsite = @JobsiteId
  AND l.deleted_at IS NULL
  AND l.is_active = 1
  AND m.by_jobsite = @JobsiteId
  AND m.deleted_at IS NULL
  AND m.menu_code = N'hr_sakit_section'
  AND NOT EXISTS (
      SELECT 1 FROM hr.level_permissions lp
      WHERE lp.by_jobsite = @JobsiteId
        AND lp.level_id = l.id
        AND lp.menu_id = m.id
        AND lp.deleted_at IS NULL
  );

UPDATE lp
SET can_read = CASE
        WHEN LOWER(l.code) = N'section_head' THEN 1
        WHEN EXISTS (
            SELECT 1
            FROM hr.users u
            INNER JOIN hr.v_workers_active wa
                ON wa.by_jobsite = u.by_jobsite AND wa.nrp = u.username
            WHERE u.level_id = l.id AND u.by_jobsite = @JobsiteId
              AND u.deleted_at IS NULL AND wa.job_rank = @UhRank
        ) THEN 1
        ELSE 0
    END,
    can_approve = CASE
        WHEN LOWER(l.code) = N'section_head' THEN 1
        WHEN EXISTS (
            SELECT 1
            FROM hr.users u
            INNER JOIN hr.v_workers_active wa
                ON wa.by_jobsite = u.by_jobsite AND wa.nrp = u.username
            WHERE u.level_id = l.id AND u.by_jobsite = @JobsiteId
              AND u.deleted_at IS NULL AND wa.job_rank = @UhRank
        ) THEN 1
        ELSE 0
    END,
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
  AND m.menu_code = N'hr_sakit_section'
  AND l.deleted_at IS NULL;

PRINT 'hr_sakit_section menu ready';
GO
