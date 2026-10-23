-- =============================================
-- Fingerprint menus, level permissions, and edit_policy module finger_error
-- hr_finger_error, hr_finger_error_section, hr_finger_error_hr
-- (no group / department queues)
-- Run AFTER 81_finger_error_sp.sql
-- =============================================

-- =============================================
-- Sidebar menu "Fingerprint" under Reconciliation
-- hr_finger_error -> /reconciliation/finger-error
-- =============================================
DECLARE @JobsiteId INT = 1;

DECLARE @ReconId INT = (
    SELECT TOP 1 id FROM hr.menus
    WHERE by_jobsite = @JobsiteId AND menu_code = N'hr_reconciliation' AND deleted_at IS NULL
);

IF @ReconId IS NULL
BEGIN
    THROW 50082, 'hr_reconciliation menu missing. Seed legacy menus / wave sidebar first.', 1;
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
    WHERE by_jobsite = @JobsiteId AND menu_code = N'hr_finger_error' AND deleted_at IS NULL
)
BEGIN
    UPDATE hr.menus
    SET menu_name = N'Fingerprint',
        menu_url = N'/reconciliation/finger-error',
        icon = N'task',
        menu_type = N'children',
        parent_id = @ReconId,
        sort_order = 5,
        show_sidebar = 1,
        is_active = 1,
        description = N'hr.workers_finger_error',
        updated_at = SYSUTCDATETIME(),
        updated_by = NULL
    WHERE by_jobsite = @JobsiteId
      AND menu_code = N'hr_finger_error'
      AND deleted_at IS NULL;
END
ELSE
BEGIN
    INSERT INTO hr.menus (
        by_jobsite, menu_code, menu_name, menu_url, icon, menu_type,
        parent_id, sort_order, show_sidebar, is_active, description, created_by
    )
    VALUES (
        @JobsiteId, N'hr_finger_error', N'Fingerprint', N'/reconciliation/finger-error', N'task', N'children',
        @ReconId, 5, 1, 1, N'hr.workers_finger_error', NULL
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
  AND m.menu_code = N'hr_finger_error'
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
  AND m.menu_code = N'hr_finger_error'
  AND l.deleted_at IS NULL;

PRINT CONCAT('hr_finger_error permissions updated: ', @@ROWCOUNT);
GO

-- =============================================
-- Menu Fingerprint under Section → SIA Karyawan
-- hr_finger_error_section → /section/finger-error
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
    THROW 50082, 'Section → SIA Karyawan menu missing.', 1;
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
    WHERE by_jobsite = @JobsiteId AND menu_code = N'hr_finger_error_section' AND deleted_at IS NULL
)
BEGIN
    UPDATE hr.menus
    SET menu_name = N'Fingerprint',
        menu_url = N'/section/finger-error',
        icon = N'task',
        menu_type = N'children',
        parent_id = @SiaId,
        sort_order = 3,
        show_sidebar = 1,
        is_active = 1,
        description = N'Section approval queue for fingerprint',
        updated_at = SYSUTCDATETIME(),
        updated_by = NULL
    WHERE by_jobsite = @JobsiteId AND menu_code = N'hr_finger_error_section' AND deleted_at IS NULL;
END
ELSE
BEGIN
    INSERT INTO hr.menus (
        by_jobsite, menu_code, menu_name, menu_url, icon, menu_type,
        parent_id, sort_order, show_sidebar, is_active, description, created_by
    )
    VALUES (
        @JobsiteId, N'hr_finger_error_section', N'Fingerprint', N'/section/finger-error', N'task', N'children',
        @SiaId, 3, 1, 1, N'Section approval queue for fingerprint', NULL
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
  AND m.menu_code = N'hr_finger_error_section'
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
  AND m.menu_code = N'hr_finger_error_section'
  AND l.deleted_at IS NULL;

PRINT 'hr_finger_error_section menu ready';
GO

-- =============================================
-- Menu Fingerprint under Personalia → SIA Karyawan
-- hr_finger_error_hr → /personalia/finger-error
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
      AND p.menu_name = N'Personalia'
);

IF @SiaId IS NULL
BEGIN
    THROW 50082, 'Personalia → SIA Karyawan menu missing.', 1;
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
    WHERE by_jobsite = @JobsiteId AND menu_code = N'hr_finger_error_hr' AND deleted_at IS NULL
)
BEGIN
    UPDATE hr.menus
    SET menu_name = N'Fingerprint',
        menu_url = N'/personalia/finger-error',
        icon = N'task',
        menu_type = N'children',
        parent_id = @SiaId,
        sort_order = 3,
        show_sidebar = 1,
        is_active = 1,
        description = N'Personalia HR final approval queue for fingerprint',
        updated_at = SYSUTCDATETIME(),
        updated_by = NULL
    WHERE by_jobsite = @JobsiteId AND menu_code = N'hr_finger_error_hr' AND deleted_at IS NULL;
END
ELSE
BEGIN
    INSERT INTO hr.menus (
        by_jobsite, menu_code, menu_name, menu_url, icon, menu_type,
        parent_id, sort_order, show_sidebar, is_active, description, created_by
    )
    VALUES (
        @JobsiteId, N'hr_finger_error_hr', N'Fingerprint', N'/personalia/finger-error', N'task', N'children',
        @SiaId, 3, 1, 1, N'Personalia HR final approval queue for fingerprint', NULL
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
    CASE WHEN LOWER(l.code) IN (N'hr_admin', N'hr_administrator', N'superadmin', N'sa') THEN 1 ELSE 0 END,
    0, 0, 0,
    CASE WHEN LOWER(l.code) IN (N'hr_admin', N'hr_administrator', N'superadmin', N'sa') THEN 1 ELSE 0 END,
    CASE WHEN LOWER(l.code) IN (N'hr_admin', N'hr_administrator', N'superadmin', N'sa') THEN 1 ELSE 0 END,
    NULL
FROM hr.levels l
CROSS JOIN hr.menus m
WHERE l.by_jobsite = @JobsiteId
  AND l.deleted_at IS NULL
  AND l.is_active = 1
  AND m.by_jobsite = @JobsiteId
  AND m.deleted_at IS NULL
  AND m.menu_code = N'hr_finger_error_hr'
  AND NOT EXISTS (
      SELECT 1 FROM hr.level_permissions lp
      WHERE lp.by_jobsite = @JobsiteId
        AND lp.level_id = l.id
        AND lp.menu_id = m.id
        AND lp.deleted_at IS NULL
  );

UPDATE lp
SET can_read = CASE WHEN LOWER(l.code) IN (N'hr_admin', N'hr_administrator', N'superadmin', N'sa') THEN 1 ELSE 0 END,
    can_approve = CASE WHEN LOWER(l.code) IN (N'hr_admin', N'hr_administrator', N'superadmin', N'sa') THEN 1 ELSE 0 END,
    can_export = CASE WHEN LOWER(l.code) IN (N'hr_admin', N'hr_administrator', N'superadmin', N'sa') THEN 1 ELSE 0 END,
    can_insert = 0,
    can_update = 0,
    can_delete = 0,
    updated_at = SYSUTCDATETIME(),
    updated_by = NULL
FROM hr.level_permissions lp
INNER JOIN hr.menus m ON m.id = lp.menu_id AND m.by_jobsite = lp.by_jobsite
INNER JOIN hr.levels l ON l.id = lp.level_id AND l.by_jobsite = lp.by_jobsite
WHERE lp.by_jobsite = @JobsiteId
  AND lp.deleted_at IS NULL
  AND m.menu_code = N'hr_finger_error_hr'
  AND l.deleted_at IS NULL;

PRINT 'hr_finger_error_hr menu ready';
GO

-- =============================================
-- Edit Policy module "finger_error"
-- =============================================
DECLARE @JobsiteId INT = 1;

MERGE hr.edit_policy_modules AS t
USING (
    SELECT
        @JobsiteId AS by_jobsite,
        N'finger_error' AS module_code,
        N'Fingerprint' AS module_name,
        N'Jendela Ubah/Batalkan pengajuan fingerprint sejak tanggal dibuat' AS description,
        22 AS sort_order
) AS s
ON t.by_jobsite = s.by_jobsite
   AND t.module_code = s.module_code
   AND t.deleted_at IS NULL
WHEN MATCHED THEN
    UPDATE SET
        module_name = s.module_name,
        description = s.description,
        sort_order = s.sort_order,
        is_active = 1,
        updated_at = SYSUTCDATETIME(),
        updated_by = NULL
WHEN NOT MATCHED THEN
    INSERT (by_jobsite, module_code, module_name, description, sort_order, is_active, created_by)
    VALUES (s.by_jobsite, s.module_code, s.module_name, s.description, s.sort_order, 1, NULL);

INSERT INTO hr.edit_policy (
    by_jobsite, module_code, level_code, can_edit, past_days, allow_past, description, created_by
)
SELECT
    @JobsiteId,
    N'finger_error',
    LOWER(l.code),
    1,
    3,
    CASE
        WHEN LOWER(l.code) IN (N'superadmin', N'sa', N'hr_admin', N'hr_administrator') THEN 1
        ELSE 0
    END,
    CASE
        WHEN LOWER(l.code) IN (N'superadmin', N'sa', N'hr_admin', N'hr_administrator')
            THEN N'Tanpa batas hari (allow past)'
        ELSE N'Ubah/Batalkan hanya pending dan <= 3 hari sejak dibuat'
    END,
    NULL
FROM hr.levels l
WHERE l.by_jobsite = @JobsiteId
  AND l.deleted_at IS NULL
  AND l.is_active = 1
  AND l.approval_stage = N'all'
  AND NOT EXISTS (
      SELECT 1
      FROM hr.edit_policy e
      WHERE e.by_jobsite = @JobsiteId
        AND e.module_code = N'finger_error'
        AND LOWER(e.level_code) = LOWER(l.code)
        AND e.deleted_at IS NULL
  );

INSERT INTO hr.edit_policy (
    by_jobsite, module_code, level_code, can_edit, past_days, allow_past, description, created_by
)
SELECT
    @JobsiteId,
    N'finger_error',
    LOWER(l.code),
    0,
    3,
    0,
    N'Tidak boleh ubah/batalkan',
    NULL
FROM hr.levels l
WHERE l.by_jobsite = @JobsiteId
  AND l.deleted_at IS NULL
  AND l.is_active = 1
  AND ISNULL(l.approval_stage, N'') <> N'all'
  AND NOT EXISTS (
      SELECT 1
      FROM hr.edit_policy e
      WHERE e.by_jobsite = @JobsiteId
        AND e.module_code = N'finger_error'
        AND LOWER(e.level_code) = LOWER(l.code)
        AND e.deleted_at IS NULL
  );

PRINT 'hr.edit_policy module finger_error seeded';
GO
