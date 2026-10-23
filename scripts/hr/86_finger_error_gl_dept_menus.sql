-- =============================================
-- Fingerprint menus under Group Leader + Department → SIA Karyawan
-- hr_finger_error_group → /group/finger-error
-- hr_finger_error_department → /department/finger-error
-- sort_order 3 (after permit when present)
-- Run AFTER 85_finger_error_gl_dept.sql
-- =============================================

-- Group Leader → SIA Karyawan → Fingerprint
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
      AND p.menu_name = N'Group Leader'
);

IF @SiaId IS NULL
BEGIN
    THROW 50086, 'Group Leader → SIA Karyawan menu missing.', 1;
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
    WHERE by_jobsite = @JobsiteId AND menu_code = N'hr_finger_error_group' AND deleted_at IS NULL
)
BEGIN
    UPDATE hr.menus
    SET menu_name = N'Fingerprint',
        menu_url = N'/group/finger-error',
        icon = N'task',
        menu_type = N'children',
        parent_id = @SiaId,
        sort_order = 3,
        show_sidebar = 1,
        is_active = 1,
        description = N'Group Leader approval queue for LS fingerprint',
        updated_at = SYSUTCDATETIME(),
        updated_by = NULL
    WHERE by_jobsite = @JobsiteId AND menu_code = N'hr_finger_error_group' AND deleted_at IS NULL;
END
ELSE
BEGIN
    INSERT INTO hr.menus (
        by_jobsite, menu_code, menu_name, menu_url, icon, menu_type,
        parent_id, sort_order, show_sidebar, is_active, description, created_by
    )
    VALUES (
        @JobsiteId, N'hr_finger_error_group', N'Fingerprint', N'/group/finger-error', N'task', N'children',
        @SiaId, 3, 1, 1, N'Group Leader approval queue for LS fingerprint', NULL
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
        WHEN LOWER(l.code) = N'group_leader' THEN 1
        WHEN LOWER(l.code) <> N'section_head' AND EXISTS (
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
        WHEN LOWER(l.code) = N'group_leader' THEN 1
        WHEN LOWER(l.code) <> N'section_head' AND EXISTS (
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
  AND m.menu_code = N'hr_finger_error_group'
  AND NOT EXISTS (
      SELECT 1 FROM hr.level_permissions lp
      WHERE lp.by_jobsite = @JobsiteId
        AND lp.level_id = l.id
        AND lp.menu_id = m.id
        AND lp.deleted_at IS NULL
  );

UPDATE lp
SET can_read = CASE
        WHEN LOWER(l.code) = N'group_leader' THEN 1
        WHEN LOWER(l.code) <> N'section_head' AND EXISTS (
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
        WHEN LOWER(l.code) = N'group_leader' THEN 1
        WHEN LOWER(l.code) <> N'section_head' AND EXISTS (
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
  AND m.menu_code = N'hr_finger_error_group'
  AND l.deleted_at IS NULL;

PRINT 'hr_finger_error_group menu ready';
GO

-- Department → SIA Karyawan → Fingerprint
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
    THROW 50086, 'Department → SIA Karyawan menu missing.', 1;
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
    WHERE by_jobsite = @JobsiteId AND menu_code = N'hr_finger_error_department' AND deleted_at IS NULL
)
BEGIN
    UPDATE hr.menus
    SET menu_name = N'Fingerprint',
        menu_url = N'/department/finger-error',
        icon = N'task',
        menu_type = N'children',
        parent_id = @SiaId,
        sort_order = 3,
        show_sidebar = 1,
        is_active = 1,
        description = N'Department approval queue for fingerprint',
        updated_at = SYSUTCDATETIME(),
        updated_by = NULL
    WHERE by_jobsite = @JobsiteId AND menu_code = N'hr_finger_error_department' AND deleted_at IS NULL;
END
ELSE
BEGIN
    INSERT INTO hr.menus (
        by_jobsite, menu_code, menu_name, menu_url, icon, menu_type,
        parent_id, sort_order, show_sidebar, is_active, description, created_by
    )
    VALUES (
        @JobsiteId, N'hr_finger_error_department', N'Fingerprint', N'/department/finger-error', N'task', N'children',
        @SiaId, 3, 1, 1, N'Department approval queue for fingerprint', NULL
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
  AND m.menu_code = N'hr_finger_error_department'
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
  AND m.menu_code = N'hr_finger_error_department'
  AND l.deleted_at IS NULL;

PRINT 'hr_finger_error_department menu ready';
GO
