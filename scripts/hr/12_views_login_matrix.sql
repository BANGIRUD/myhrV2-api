-- =============================================
-- Views: login row shapes using hr.level_permissions matrix
-- Replaces CSV join on hr.menu_privilege for menu + access flags.
-- Dashboard path still from hr.menu_privilege (legacy) by u.level.
-- Run AFTER 11_level_permissions.sql (+ 09_users_level_id for level_id)
-- =============================================
CREATE OR ALTER VIEW hr.v_user_login
AS
SELECT
    u.id,
    u.legacy_id,
    u.by_jobsite,
    u.username,
    u.password,
    u.full_name,
    u.department,
    (
        SELECT STRING_AGG(d.name, N', ') WITHIN GROUP (ORDER BY d.by_order, d.name)
        FROM STRING_SPLIT(REPLACE(ISNULL(u.department, N''), N' ', N''), N',') ss
        INNER JOIN hr.structure d
            ON d.by_jobsite = u.by_jobsite
           AND d.deleted_at IS NULL
           AND d.type = N'department'
           AND d.id = TRY_CAST(ss.value AS INT)
        WHERE LTRIM(RTRIM(ss.value)) <> N''
    ) AS department_name,
    u.section,
    (
        SELECT STRING_AGG(s.name, N', ') WITHIN GROUP (ORDER BY s.by_order, s.name)
        FROM STRING_SPLIT(REPLACE(ISNULL(u.section, N''), N' ', N''), N',') ss
        INNER JOIN hr.structure s
            ON s.by_jobsite = u.by_jobsite
           AND s.deleted_at IS NULL
           AND s.type = N'section'
           AND s.id = TRY_CAST(ss.value AS INT)
        WHERE LTRIM(RTRIM(ss.value)) <> N''
    ) AS section_name,
    u.description,
    u.email,
    u.phone,
    u.activation_key,
    u.ref_id,
    u.privilege_menu,
    u.level AS legacy_level_code,
    u.level AS level,              -- alias for Step-1 buildUserData.level
    u.legacy_level,
    u.level_id,
    lv.code AS level_code,
    lv.name AS level_name,
    lv.approval_stage,
    lv.structure_scoped,
    u.worker_scope,
    u.module,
    u.last_login,
    u.is_active,
    w.gender,
    w.department AS department_fw,
    w.section AS section_fw,
    -- Aggregated menu ids (legacy) for FE/CI parity; * when level has all active menus
    CASE
        WHEN lv.code = N'superadmin'
             OR (
                 SELECT COUNT(*)
                 FROM hr.level_permissions lp2
                 WHERE lp2.level_id = u.level_id
                   AND lp2.by_jobsite = u.by_jobsite
                   AND lp2.deleted_at IS NULL
                   AND lp2.can_read = 1
             ) >= (
                 SELECT COUNT(*)
                 FROM hr.menus m2
                 WHERE m2.by_jobsite = u.by_jobsite
                   AND m2.deleted_at IS NULL
                   AND m2.is_active = 1
             )
        THEN N'*'
        ELSE STUFF((
            SELECT N',' + CAST(m.legacy_id AS NVARCHAR(20))
            FROM hr.level_permissions lp
            INNER JOIN hr.menus m
                ON m.id = lp.menu_id
            WHERE lp.level_id = u.level_id
              AND lp.by_jobsite = u.by_jobsite
              AND lp.deleted_at IS NULL
              AND lp.can_read = 1
              AND m.legacy_id IS NOT NULL
            ORDER BY m.legacy_id
            FOR XML PATH(N''), TYPE
        ).value(N'.', N'NVARCHAR(MAX)'), 1, 1, N'')
    END AS menu,
    ISNULL(mp.dashboard, N'') AS dashboard,
    CASE WHEN EXISTS (
        SELECT 1 FROM hr.level_permissions x
        WHERE x.level_id = u.level_id AND x.by_jobsite = u.by_jobsite
          AND x.deleted_at IS NULL AND x.can_insert = 1
    ) THEN N'true' ELSE N'false' END AS [create],
    CASE WHEN EXISTS (
        SELECT 1 FROM hr.level_permissions x
        WHERE x.level_id = u.level_id AND x.by_jobsite = u.by_jobsite
          AND x.deleted_at IS NULL AND x.can_read = 1
    ) THEN N'true' ELSE N'false' END AS [read],
    CASE WHEN EXISTS (
        SELECT 1 FROM hr.level_permissions x
        WHERE x.level_id = u.level_id AND x.by_jobsite = u.by_jobsite
          AND x.deleted_at IS NULL AND x.can_update = 1
    ) THEN N'true' ELSE N'false' END AS [update],
    CASE WHEN EXISTS (
        SELECT 1 FROM hr.level_permissions x
        WHERE x.level_id = u.level_id AND x.by_jobsite = u.by_jobsite
          AND x.deleted_at IS NULL AND x.can_delete = 1
    ) THEN N'true' ELSE N'false' END AS [delete],
    CASE WHEN EXISTS (
        SELECT 1 FROM hr.level_permissions x
        WHERE x.level_id = u.level_id AND x.by_jobsite = u.by_jobsite
          AND x.deleted_at IS NULL AND x.can_export = 1
    ) THEN N'true' ELSE N'false' END AS [export],
    CASE WHEN EXISTS (
        SELECT 1 FROM hr.level_permissions x
        WHERE x.level_id = u.level_id AND x.by_jobsite = u.by_jobsite
          AND x.deleted_at IS NULL AND x.can_approve = 1
    ) THEN N'true' ELSE N'false' END AS [approve]
FROM hr.users u
LEFT JOIN hr.levels lv
    ON lv.id = u.level_id
   AND lv.deleted_at IS NULL
LEFT JOIN hr.menu_privilege mp
    ON u.level = mp.id
   AND u.by_jobsite = mp.by_jobsite
   AND mp.deleted_at IS NULL
LEFT JOIN dbo.v_workers_active w
    ON u.full_name = w.full_name
    OR u.username = w.nrp
WHERE u.deleted_at IS NULL;
GO

-- GL login: still from dbo view; enrich with canonical level + matrix menus.
-- dbo.v_users_gl_login has no password column — auth relies on BYPASS or app rules.
CREATE OR ALTER VIEW hr.v_users_gl_login
AS
SELECT
    g.username,
    g.full_name,
    g.jabatan,
    g.section,
    (
        SELECT STRING_AGG(s.name, N', ') WITHIN GROUP (ORDER BY s.by_order, s.name)
        FROM STRING_SPLIT(REPLACE(ISNULL(CAST(g.section AS NVARCHAR(MAX)), N''), N' ', N''), N',') ss
        INNER JOIN hr.structure s
            ON s.by_jobsite = 1
           AND s.deleted_at IS NULL
           AND s.type = N'section'
           AND s.id = TRY_CAST(ss.value AS INT)
        WHERE LTRIM(RTRIM(ss.value)) <> N''
    ) AS section_name,
    g.department,
    (
        SELECT STRING_AGG(d.name, N', ') WITHIN GROUP (ORDER BY d.by_order, d.name)
        FROM STRING_SPLIT(REPLACE(ISNULL(CAST(g.department AS NVARCHAR(MAX)), N''), N' ', N''), N',') ss
        INNER JOIN hr.structure d
            ON d.by_jobsite = 1
           AND d.deleted_at IS NULL
           AND d.type = N'department'
           AND d.id = TRY_CAST(ss.value AS INT)
        WHERE LTRIM(RTRIM(ss.value)) <> N''
    ) AS department_name,
    g.LS_SEC,
    g.total,
    g.privilege_menu,
    g.ref_id,
    g.level AS legacy_level_code,
    g.level AS level,
    CAST(NULL AS NVARCHAR(255)) AS password,
    CAST(1 AS INT) AS by_jobsite,
    map.level_id,
    lv.code AS level_code,
    lv.name AS level_name,
    lv.approval_stage,
    lv.structure_scoped,
    CAST(NULL AS NVARCHAR(10)) AS worker_scope,
    CAST(NULL AS NVARCHAR(30)) AS module,
    w.gender,
    w.department AS department_fw,
    w.section AS section_fw,
    CASE
        WHEN lv.code = N'superadmin' THEN N'*'
        ELSE STUFF((
            SELECT N',' + CAST(m.legacy_id AS NVARCHAR(20))
            FROM hr.level_permissions lp
            INNER JOIN hr.menus m ON m.id = lp.menu_id
            WHERE lp.level_id = map.level_id
              AND lp.by_jobsite = 1
              AND lp.deleted_at IS NULL
              AND lp.can_read = 1
              AND m.legacy_id IS NOT NULL
            ORDER BY m.legacy_id
            FOR XML PATH(N''), TYPE
        ).value(N'.', N'NVARCHAR(MAX)'), 1, 1, N'')
    END AS menu,
    ISNULL(mp.dashboard, N'') AS dashboard,
    CASE WHEN EXISTS (
        SELECT 1 FROM hr.level_permissions x
        WHERE x.level_id = map.level_id AND x.by_jobsite = 1
          AND x.deleted_at IS NULL AND x.can_insert = 1
    ) THEN N'true' ELSE N'false' END AS [create],
    CASE WHEN EXISTS (
        SELECT 1 FROM hr.level_permissions x
        WHERE x.level_id = map.level_id AND x.by_jobsite = 1
          AND x.deleted_at IS NULL AND x.can_read = 1
    ) THEN N'true' ELSE N'false' END AS [read],
    CASE WHEN EXISTS (
        SELECT 1 FROM hr.level_permissions x
        WHERE x.level_id = map.level_id AND x.by_jobsite = 1
          AND x.deleted_at IS NULL AND x.can_update = 1
    ) THEN N'true' ELSE N'false' END AS [update],
    CASE WHEN EXISTS (
        SELECT 1 FROM hr.level_permissions x
        WHERE x.level_id = map.level_id AND x.by_jobsite = 1
          AND x.deleted_at IS NULL AND x.can_delete = 1
    ) THEN N'true' ELSE N'false' END AS [delete],
    CASE WHEN EXISTS (
        SELECT 1 FROM hr.level_permissions x
        WHERE x.level_id = map.level_id AND x.by_jobsite = 1
          AND x.deleted_at IS NULL AND x.can_export = 1
    ) THEN N'true' ELSE N'false' END AS [export],
    CASE WHEN EXISTS (
        SELECT 1 FROM hr.level_permissions x
        WHERE x.level_id = map.level_id AND x.by_jobsite = 1
          AND x.deleted_at IS NULL AND x.can_approve = 1
    ) THEN N'true' ELSE N'false' END AS [approve]
FROM dbo.v_users_gl_login g
LEFT JOIN hr.level_legacy_map map
    ON map.legacy_code = g.level
   AND map.by_jobsite = 1
LEFT JOIN hr.levels lv
    ON lv.id = map.level_id
   AND lv.deleted_at IS NULL
LEFT JOIN hr.menu_privilege mp
    ON g.level = mp.id
   AND mp.by_jobsite = 1
   AND mp.deleted_at IS NULL
LEFT JOIN dbo.v_workers_active w
    ON g.username = w.nrp;
GO
