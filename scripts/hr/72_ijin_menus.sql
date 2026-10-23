-- =============================================
-- Ijin menus, level permissions, and edit policy module ijin
-- hr_ijin, hr_ijin_section, hr_ijin_group, hr_ijin_department, hr_ijin_hr
-- Run AFTER 71_ijin_sp.sql
-- =============================================


-- =============================================
-- Sidebar menu "Ijin" under Reconciliation
-- hr_ijin -> /reconciliation/ijin (under parent hr_reconciliation)
-- Idempotent. Fase 1: can_read for all levels; writes off.
-- Run AFTER 52_ijin_sp.sql
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
    WHERE by_jobsite = @JobsiteId AND menu_code = N'hr_ijin' AND deleted_at IS NULL
)
BEGIN
    UPDATE hr.menus
    SET menu_name = N'Ijin',
        menu_url = N'/reconciliation/ijin',
        icon = N'file',
        menu_type = N'children',
        parent_id = @ReconId,
        sort_order = 4,
        show_sidebar = 1,
        is_active = 1,
        description = N'hr.workers_sickness',
        updated_at = SYSUTCDATETIME(),
        updated_by = NULL
    WHERE by_jobsite = @JobsiteId
      AND menu_code = N'hr_ijin'
      AND deleted_at IS NULL;
END
ELSE
BEGIN
    INSERT INTO hr.menus (
        by_jobsite, menu_code, menu_name, menu_url, icon, menu_type,
        parent_id, sort_order, show_sidebar, is_active, description, created_by
    )
    VALUES (
        @JobsiteId, N'hr_ijin', N'Ijin', N'/reconciliation/ijin', N'file', N'children',
        @ReconId, 4, 1, 1, N'hr.workers_sickness', NULL
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
  AND m.menu_code = N'hr_ijin'
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
  AND m.menu_code = N'hr_ijin'
  AND l.deleted_at IS NULL;

PRINT CONCAT('hr_ijin permissions updated: ', @@ROWCOUNT);
GO

-- =============================================
-- Menu Ijin under Section → SIA Karyawan
-- hr_ijin_section → /section/ijin
-- Read + approve for section_head, and for levels that have a Unit Head login.
-- Run AFTER 59_ijin_section_approval.sql
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
    WHERE by_jobsite = @JobsiteId AND menu_code = N'hr_ijin_section' AND deleted_at IS NULL
)
BEGIN
    UPDATE hr.menus
    SET menu_name = N'Ijin',
        menu_url = N'/section/ijin',
        icon = N'file',
        menu_type = N'children',
        parent_id = @SiaId,
        sort_order = 2,
        show_sidebar = 1,
        is_active = 1,
        description = N'Section approval queue for ijin',
        updated_at = SYSUTCDATETIME(),
        updated_by = NULL
    WHERE by_jobsite = @JobsiteId AND menu_code = N'hr_ijin_section' AND deleted_at IS NULL;
END
ELSE
BEGIN
    INSERT INTO hr.menus (
        by_jobsite, menu_code, menu_name, menu_url, icon, menu_type,
        parent_id, sort_order, show_sidebar, is_active, description, created_by
    )
    VALUES (
        @JobsiteId, N'hr_ijin_section', N'Ijin', N'/section/ijin', N'file', N'children',
        @SiaId, 2, 1, 1, N'Section approval queue for ijin', NULL
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
  AND m.menu_code = N'hr_ijin_section'
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
  AND m.menu_code = N'hr_ijin_section'
  AND l.deleted_at IS NULL;

PRINT 'hr_ijin_section menu ready';
GO

-- =============================================
-- Menu Ijin under Group Leader → SIA Karyawan
-- hr_ijin_group → /group/ijin
-- Read + approve for group_leader, and for levels that have a Unit Head login.
-- Not granted to section_head.
-- Run AFTER 61_ijin_gl_approval.sql
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
      AND p.menu_name = N'Group Leader'
);

IF @SiaId IS NULL
BEGIN
    THROW 50062, 'Group Leader → SIA Karyawan menu missing.', 1;
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
    WHERE by_jobsite = @JobsiteId AND menu_code = N'hr_ijin_group' AND deleted_at IS NULL
)
BEGIN
    UPDATE hr.menus
    SET menu_name = N'Ijin',
        menu_url = N'/group/ijin',
        icon = N'file',
        menu_type = N'children',
        parent_id = @SiaId,
        sort_order = 2,
        show_sidebar = 1,
        is_active = 1,
        description = N'Group Leader approval queue for LS ijin',
        updated_at = SYSUTCDATETIME(),
        updated_by = NULL
    WHERE by_jobsite = @JobsiteId AND menu_code = N'hr_ijin_group' AND deleted_at IS NULL;
END
ELSE
BEGIN
    INSERT INTO hr.menus (
        by_jobsite, menu_code, menu_name, menu_url, icon, menu_type,
        parent_id, sort_order, show_sidebar, is_active, description, created_by
    )
    VALUES (
        @JobsiteId, N'hr_ijin_group', N'Ijin', N'/group/ijin', N'file', N'children',
        @SiaId, 2, 1, 1, N'Group Leader approval queue for LS ijin', NULL
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
  AND m.menu_code = N'hr_ijin_group'
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
  AND m.menu_code = N'hr_ijin_group'
  AND l.deleted_at IS NULL;

PRINT 'hr_ijin_group menu ready';
GO

-- =============================================
-- Menu Ijin under Department → SIA Karyawan
-- hr_ijin_department → /department/ijin
-- Read + approve for department_head only.
-- Run AFTER 63_ijin_department_approval.sql
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
    WHERE by_jobsite = @JobsiteId AND menu_code = N'hr_ijin_department' AND deleted_at IS NULL
)
BEGIN
    UPDATE hr.menus
    SET menu_name = N'Ijin',
        menu_url = N'/department/ijin',
        icon = N'file',
        menu_type = N'children',
        parent_id = @SiaId,
        sort_order = 2,
        show_sidebar = 1,
        is_active = 1,
        description = N'Department approval queue for ijin',
        updated_at = SYSUTCDATETIME(),
        updated_by = NULL
    WHERE by_jobsite = @JobsiteId AND menu_code = N'hr_ijin_department' AND deleted_at IS NULL;
END
ELSE
BEGIN
    INSERT INTO hr.menus (
        by_jobsite, menu_code, menu_name, menu_url, icon, menu_type,
        parent_id, sort_order, show_sidebar, is_active, description, created_by
    )
    VALUES (
        @JobsiteId, N'hr_ijin_department', N'Ijin', N'/department/ijin', N'file', N'children',
        @SiaId, 2, 1, 1, N'Department approval queue for ijin', NULL
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
  AND m.menu_code = N'hr_ijin_department'
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
  AND m.menu_code = N'hr_ijin_department'
  AND l.deleted_at IS NULL;

PRINT 'hr_ijin_department menu ready';
GO

-- =============================================
-- Menu Ijin under Personalia → SIA Karyawan
-- hr_ijin_hr → /personalia/ijin
-- Read + approve for hr_admin and hr_administrator.
-- Run AFTER 68_ijin_hr_approval.sql
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
    THROW 50069, 'Personalia → SIA Karyawan menu missing.', 1;
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
    WHERE by_jobsite = @JobsiteId AND menu_code = N'hr_ijin_hr' AND deleted_at IS NULL
)
BEGIN
    UPDATE hr.menus
    SET menu_name = N'Ijin',
        menu_url = N'/personalia/ijin',
        icon = N'file',
        menu_type = N'children',
        parent_id = @SiaId,
        sort_order = 2,
        show_sidebar = 1,
        is_active = 1,
        description = N'Personalia HR final approval queue for ijin',
        updated_at = SYSUTCDATETIME(),
        updated_by = NULL
    WHERE by_jobsite = @JobsiteId AND menu_code = N'hr_ijin_hr' AND deleted_at IS NULL;
END
ELSE
BEGIN
    INSERT INTO hr.menus (
        by_jobsite, menu_code, menu_name, menu_url, icon, menu_type,
        parent_id, sort_order, show_sidebar, is_active, description, created_by
    )
    VALUES (
        @JobsiteId, N'hr_ijin_hr', N'Ijin', N'/personalia/ijin', N'file', N'children',
        @SiaId, 2, 1, 1, N'Personalia HR final approval queue for ijin', NULL
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
    CASE WHEN LOWER(l.code) IN (N'hr_admin', N'hr_administrator') THEN 1 ELSE 0 END,
    0, 0, 0, 0,
    CASE WHEN LOWER(l.code) IN (N'hr_admin', N'hr_administrator') THEN 1 ELSE 0 END,
    NULL
FROM hr.levels l
CROSS JOIN hr.menus m
WHERE l.by_jobsite = @JobsiteId
  AND l.deleted_at IS NULL
  AND l.is_active = 1
  AND m.by_jobsite = @JobsiteId
  AND m.deleted_at IS NULL
  AND m.menu_code = N'hr_ijin_hr'
  AND NOT EXISTS (
      SELECT 1 FROM hr.level_permissions lp
      WHERE lp.by_jobsite = @JobsiteId
        AND lp.level_id = l.id
        AND lp.menu_id = m.id
        AND lp.deleted_at IS NULL
  );

UPDATE lp
SET can_read = CASE WHEN LOWER(l.code) IN (N'hr_admin', N'hr_administrator') THEN 1 ELSE 0 END,
    can_approve = CASE WHEN LOWER(l.code) IN (N'hr_admin', N'hr_administrator') THEN 1 ELSE 0 END,
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
  AND m.menu_code = N'hr_ijin_hr'
  AND l.deleted_at IS NULL;

PRINT 'hr_ijin_hr menu ready';
GO

-- =============================================
-- Edit Policy module "ijin" (Reconciliation → Ijin)
-- past_days = max days since created_at for Ubah + Batalkan
-- allow_past = 1 skips the day window
-- can_edit = 0 hides both actions for that level
-- Idempotent. Run AFTER 48_edit_policy.sql
-- =============================================
DECLARE @JobsiteId INT = 1;

MERGE hr.edit_policy_modules AS t
USING (
    SELECT
        @JobsiteId AS by_jobsite,
        N'ijin' AS module_code,
        N'Ijin' AS module_name,
        N'Jendela Ubah/Batalkan pengajuan ijin sejak tanggal dibuat' AS description,
        21 AS sort_order
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

-- Write levels: 3-day window. Superadmin / HR admin bypass the window.
INSERT INTO hr.edit_policy (
    by_jobsite, module_code, level_code, can_edit, past_days, allow_past, description, created_by
)
SELECT
    @JobsiteId,
    N'ijin',
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
        AND e.module_code = N'ijin'
        AND LOWER(e.level_code) = LOWER(l.code)
        AND e.deleted_at IS NULL
  );

-- Other active levels: cannot edit/cancel until a policy row is changed in the UI.
INSERT INTO hr.edit_policy (
    by_jobsite, module_code, level_code, can_edit, past_days, allow_past, description, created_by
)
SELECT
    @JobsiteId,
    N'ijin',
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
        AND e.module_code = N'ijin'
        AND LOWER(e.level_code) = LOWER(l.code)
        AND e.deleted_at IS NULL
  );

PRINT 'hr.edit_policy module ijin seeded';
GO
