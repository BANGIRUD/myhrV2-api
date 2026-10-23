-- =============================================
-- Consolidate hr.levels: 15 legacy-style levels -> 10 canonical levels
--
--   administrator                        -> management
--   hr_admin_ls                          -> hr_admin       (users.worker_scope = ls)
--   hr_admin                             -> hr_admin       (users.worker_scope = sis)
--   hr_administrator                     -> hr_administrator (users.worker_scope = all)
--   irel / meals / safety / attendance   -> module_admin   (users.module = ...)
--
-- Differences that used to be separate levels become per-user attributes:
--   hr.users.worker_scope  sis | ls | all
--   hr.users.module        irel | meals | safety | attendance
-- hr.level_permissions.audience narrows a (level, menu) grant to users whose
-- worker_scope/module matches one of its tokens (NULL = whole level).
--
-- Idempotent. Run AFTER 07..11 and 24 (needs levels, map, permissions, users).
-- Local DB only.
-- =============================================
DECLARE @JobsiteId INT = 1;

IF NOT EXISTS (SELECT 1 FROM hr.jobsites WHERE id = @JobsiteId AND deleted_at IS NULL)
BEGIN
    THROW 50027, 'hr.jobsites id=1 missing. Run 02_jobsites.sql first.', 1;
END;

-- ---------------------------------------------------------------
-- 1. Canonical catalog: add module_admin, refresh descriptions
-- ---------------------------------------------------------------
IF NOT EXISTS (
    SELECT 1 FROM hr.levels
    WHERE by_jobsite = @JobsiteId AND code = N'module_admin' AND deleted_at IS NULL
)
BEGIN
    INSERT INTO hr.levels (
        by_jobsite, code, name, description, approval_stage, structure_scoped, sort_order, created_by
    )
    VALUES (
        @JobsiteId, N'module_admin', N'Module Admin',
        N'Admin per modul (irel, meals, safety, attendance) lewat users.module',
        N'none', 0, 70, NULL
    );
END;

UPDATE hr.levels SET
    description = N'Pemegang PJO site: seluruh data & operasional, menu konfigurasi via matrix',
    sort_order = 2,
    updated_at = SYSUTCDATETIME(), updated_by = NULL
WHERE by_jobsite = @JobsiteId AND code = N'management' AND deleted_at IS NULL;

UPDATE hr.levels SET
    description = N'Admin operasional HR; cakupan data lewat users.worker_scope (sis | ls)',
    updated_at = SYSUTCDATETIME(), updated_by = NULL
WHERE by_jobsite = @JobsiteId AND code = N'hr_admin' AND deleted_at IS NULL;

UPDATE hr.levels SET
    description = N'Atasan HR: akses penuh domain HR; worker_scope = all',
    updated_at = SYSUTCDATETIME(), updated_by = NULL
WHERE by_jobsite = @JobsiteId AND code = N'hr_administrator' AND deleted_at IS NULL;

-- ---------------------------------------------------------------
-- 2. Legacy map -> target level + user attributes
-- ---------------------------------------------------------------
DECLARE @map TABLE (
    legacy_code NVARCHAR(50) NOT NULL,
    level_code NVARCHAR(50) NOT NULL,
    worker_scope NVARCHAR(10) NULL,
    module NVARCHAR(30) NULL,
    notes NVARCHAR(255) NULL
);

INSERT INTO @map (legacy_code, level_code, worker_scope, module, notes) VALUES
    (N'admin',            N'admin_section',   NULL,  NULL,         N'Rename semantik: inputer section'),
    (N'group_leader',     N'group_leader',    NULL,  NULL,         NULL),
    (N'section_head',     N'section_head',    NULL,  NULL,         NULL),
    (N'department_head',  N'department_head', NULL,  NULL,         NULL),
    (N'admin_hr',         N'hr_admin',        N'sis', NULL,        N'HR operasional SIS'),
    (N'admin_hr(LS)',     N'hr_admin',        N'ls',  NULL,        N'HR operasional LS (vendor)'),
    (N'administrator_hr', N'hr_administrator',N'all', NULL,        N'Atasan HR'),
    (N'superadmin',       N'superadmin',      NULL,  NULL,         NULL),
    (N'administrator',    N'management',      NULL,  NULL,         N'Digabung ke management'),
    (N'management',       N'management',      NULL,  NULL,         NULL),
    (N'user',             N'employee',        NULL,  NULL,         N'Rename: user -> employee'),
    (N'irel',             N'module_admin',    NULL,  N'irel',      NULL),
    (N'admin_irel',       N'module_admin',    NULL,  N'irel',      NULL),
    (N'admin_meals',      N'module_admin',    NULL,  N'meals',     NULL),
    (N'admin_safety',     N'module_admin',    NULL,  N'safety',    NULL),
    (N'finger_check',     N'module_admin',    NULL,  N'attendance',NULL),
    (N'finger',           N'module_admin',    NULL,  N'attendance',NULL);

UPDATE m SET
    m.level_id = l.id,
    m.worker_scope = x.worker_scope,
    m.module = x.module,
    m.notes = ISNULL(x.notes, m.notes)
FROM hr.level_legacy_map m
INNER JOIN @map x ON x.legacy_code = m.legacy_code
INNER JOIN hr.levels l
    ON l.by_jobsite = @JobsiteId AND l.code = x.level_code AND l.deleted_at IS NULL
WHERE m.by_jobsite = @JobsiteId;

INSERT INTO hr.level_legacy_map (by_jobsite, legacy_code, level_id, notes, worker_scope, module)
SELECT @JobsiteId, x.legacy_code, l.id, x.notes, x.worker_scope, x.module
FROM @map x
INNER JOIN hr.levels l
    ON l.by_jobsite = @JobsiteId AND l.code = x.level_code AND l.deleted_at IS NULL
WHERE NOT EXISTS (
    SELECT 1 FROM hr.level_legacy_map m
    WHERE m.by_jobsite = @JobsiteId AND m.legacy_code = x.legacy_code
);

-- ---------------------------------------------------------------
-- 3. Merge level_permissions of retired levels into targets
--    Only while retired levels still hold permission rows (idempotent).
-- ---------------------------------------------------------------
DECLARE @retired TABLE (code NVARCHAR(50) PRIMARY KEY);
INSERT INTO @retired (code) VALUES
    (N'administrator'), (N'hr_admin_ls'), (N'irel'), (N'meals'), (N'safety'), (N'attendance');

-- source level -> target level, token (NULL = no audience narrowing)
DECLARE @src TABLE (source_code NVARCHAR(50), target_code NVARCHAR(50), token NVARCHAR(30) NULL);
INSERT INTO @src (source_code, target_code, token) VALUES
    (N'administrator', N'management',   NULL),
    (N'management',    N'management',   NULL),
    (N'hr_admin',      N'hr_admin',     N'sis'),
    (N'hr_admin_ls',   N'hr_admin',     N'ls'),
    (N'irel',          N'module_admin', N'irel'),
    (N'meals',         N'module_admin', N'meals'),
    (N'safety',        N'module_admin', N'safety'),
    (N'attendance',    N'module_admin', N'attendance');

IF EXISTS (
    SELECT 1
    FROM hr.level_permissions lp
    INNER JOIN hr.levels l ON l.id = lp.level_id AND l.by_jobsite = @JobsiteId
    INNER JOIN @retired r ON r.code = l.code
    WHERE lp.deleted_at IS NULL AND lp.by_jobsite = @JobsiteId
)
BEGIN
    DECLARE @contrib TABLE (
        target_id INT NOT NULL,
        menu_id INT NOT NULL,
        token NVARCHAR(30) NULL,
        can_read BIT, can_insert BIT, can_update BIT,
        can_delete BIT, can_export BIT, can_approve BIT
    );

    INSERT INTO @contrib
    SELECT tl.id, lp.menu_id, s.token,
           lp.can_read, lp.can_insert, lp.can_update,
           lp.can_delete, lp.can_export, lp.can_approve
    FROM hr.level_permissions lp
    INNER JOIN hr.levels sl
        ON sl.id = lp.level_id AND sl.by_jobsite = @JobsiteId AND sl.deleted_at IS NULL
    INNER JOIN @src s ON s.source_code = sl.code
    INNER JOIN hr.levels tl
        ON tl.by_jobsite = @JobsiteId AND tl.code = s.target_code AND tl.deleted_at IS NULL
    WHERE lp.deleted_at IS NULL AND lp.by_jobsite = @JobsiteId;

    DECLARE @merged TABLE (
        target_id INT NOT NULL,
        menu_id INT NOT NULL,
        can_read BIT, can_insert BIT, can_update BIT,
        can_delete BIT, can_export BIT, can_approve BIT,
        audience NVARCHAR(100) NULL
    );

    ;WITH flags AS (
        SELECT target_id, menu_id,
               CAST(MAX(CAST(can_read AS INT)) AS BIT) AS can_read,
               CAST(MAX(CAST(can_insert AS INT)) AS BIT) AS can_insert,
               CAST(MAX(CAST(can_update AS INT)) AS BIT) AS can_update,
               CAST(MAX(CAST(can_delete AS INT)) AS BIT) AS can_delete,
               CAST(MAX(CAST(can_export AS INT)) AS BIT) AS can_export,
               CAST(MAX(CAST(can_approve AS INT)) AS BIT) AS can_approve
        FROM @contrib
        GROUP BY target_id, menu_id
    ),
    tok AS (
        SELECT DISTINCT target_id, menu_id, token
        FROM @contrib
        WHERE token IS NOT NULL
    ),
    tok_agg AS (
        SELECT target_id, menu_id,
               COUNT(*) AS n,
               STRING_AGG(token, N',') WITHIN GROUP (ORDER BY token) AS csv
        FROM tok
        GROUP BY target_id, menu_id
    ),
    tok_total AS (
        SELECT tl.id AS target_id, COUNT(DISTINCT s.token) AS total
        FROM @src s
        INNER JOIN hr.levels tl
            ON tl.by_jobsite = @JobsiteId AND tl.code = s.target_code AND tl.deleted_at IS NULL
        WHERE s.token IS NOT NULL
        GROUP BY tl.id
    )
    INSERT INTO @merged
    SELECT f.target_id, f.menu_id,
           f.can_read, f.can_insert, f.can_update,
           f.can_delete, f.can_export, f.can_approve,
           CASE
               WHEN ta.n IS NULL THEN NULL
               WHEN tt.total IS NULL OR ta.n >= tt.total THEN NULL
               ELSE ta.csv
           END
    FROM flags f
    LEFT JOIN tok_agg ta ON ta.target_id = f.target_id AND ta.menu_id = f.menu_id
    LEFT JOIN tok_total tt ON tt.target_id = f.target_id;

    UPDATE lp SET
        lp.can_read = g.can_read,
        lp.can_insert = g.can_insert,
        lp.can_update = g.can_update,
        lp.can_delete = g.can_delete,
        lp.can_export = g.can_export,
        lp.can_approve = g.can_approve,
        lp.audience = g.audience,
        lp.updated_at = SYSUTCDATETIME(),
        lp.updated_by = NULL
    FROM hr.level_permissions lp
    INNER JOIN @merged g ON g.target_id = lp.level_id AND g.menu_id = lp.menu_id
    WHERE lp.by_jobsite = @JobsiteId AND lp.deleted_at IS NULL;

    INSERT INTO hr.level_permissions (
        by_jobsite, level_id, menu_id,
        can_read, can_insert, can_update, can_delete, can_export, can_approve,
        audience, created_by
    )
    SELECT @JobsiteId, g.target_id, g.menu_id,
           g.can_read, g.can_insert, g.can_update, g.can_delete, g.can_export, g.can_approve,
           g.audience, NULL
    FROM @merged g
    WHERE NOT EXISTS (
        SELECT 1 FROM hr.level_permissions lp
        WHERE lp.by_jobsite = @JobsiteId
          AND lp.level_id = g.target_id
          AND lp.menu_id = g.menu_id
          AND lp.deleted_at IS NULL
    );

    -- retire permission rows of the merged-away levels
    UPDATE lp SET
        lp.deleted_at = SYSUTCDATETIME(),
        lp.deleted_by = NULL
    FROM hr.level_permissions lp
    INNER JOIN hr.levels l ON l.id = lp.level_id AND l.by_jobsite = @JobsiteId
    INNER JOIN @retired r ON r.code = l.code
    WHERE lp.deleted_at IS NULL AND lp.by_jobsite = @JobsiteId;
END;

-- ---------------------------------------------------------------
-- 4. Users: level_id + worker_scope / module from the map
--    (attributes are only filled when empty, so manual edits survive)
-- ---------------------------------------------------------------
UPDATE u SET
    u.level_id = m.level_id,
    u.worker_scope = ISNULL(u.worker_scope, m.worker_scope),
    u.module = ISNULL(u.module, m.module),
    u.updated_at = SYSUTCDATETIME(),
    u.updated_by = NULL
FROM hr.users u
INNER JOIN hr.level_legacy_map m
    ON m.by_jobsite = u.by_jobsite AND m.legacy_code = u.level
WHERE u.by_jobsite = @JobsiteId
  AND (
        u.level_id IS NULL
     OR u.level_id <> m.level_id
     OR (u.worker_scope IS NULL AND m.worker_scope IS NOT NULL)
     OR (u.module IS NULL AND m.module IS NOT NULL)
  );

-- ---------------------------------------------------------------
-- 5. Retire merged-away levels (only when nobody references them)
-- ---------------------------------------------------------------
UPDATE l SET
    l.deleted_at = SYSUTCDATETIME(),
    l.deleted_by = NULL,
    l.is_active = 0
FROM hr.levels l
INNER JOIN @retired r ON r.code = l.code
WHERE l.by_jobsite = @JobsiteId
  AND l.deleted_at IS NULL
  AND NOT EXISTS (
      SELECT 1 FROM hr.users u WHERE u.level_id = l.id AND u.deleted_at IS NULL
  )
  AND NOT EXISTS (
      SELECT 1 FROM hr.level_permissions lp WHERE lp.level_id = l.id AND lp.deleted_at IS NULL
  );

-- ---------------------------------------------------------------
-- 6. Verification
-- ---------------------------------------------------------------
SELECT
    l.code, l.approval_stage, l.structure_scoped,
    (SELECT COUNT(*) FROM hr.users u WHERE u.level_id = l.id AND u.deleted_at IS NULL) AS users_active,
    (SELECT COUNT(*) FROM hr.level_permissions p
      WHERE p.level_id = l.id AND p.deleted_at IS NULL AND p.can_read = 1) AS menus_read,
    (SELECT COUNT(*) FROM hr.level_permissions p
      WHERE p.level_id = l.id AND p.deleted_at IS NULL AND p.audience IS NOT NULL) AS menus_audience
FROM hr.levels l
WHERE l.by_jobsite = @JobsiteId AND l.deleted_at IS NULL
ORDER BY l.sort_order, l.code;

SELECT u.level AS legacy_level, u.worker_scope, u.module, COUNT(*) AS users_active
FROM hr.users u
WHERE u.deleted_at IS NULL
  AND (u.worker_scope IS NOT NULL OR u.module IS NOT NULL)
GROUP BY u.level, u.worker_scope, u.module
ORDER BY u.level;
GO
