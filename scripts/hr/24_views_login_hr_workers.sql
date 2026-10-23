-- =============================================
-- Views: login row shapes — supersedes 12_views_login_matrix.sql
-- Same shape as 12, but worker enrichment (gender, *_fw) reads
-- hr.v_workers_active instead of dbo.v_workers_active, and picks a single
-- worker per user (nrp match first, then full_name; sis before vendor)
-- so the login view returns one row per user.
-- hr.v_users_gl_login is rebuilt from hr.v_workers_active (no dbo source).
-- Run AFTER 12_views_login_matrix.sql + 23_views_workers_active.sql
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
OUTER APPLY (
    SELECT TOP 1 wa.gender, wa.department, wa.section
    FROM hr.v_workers_active wa
    WHERE wa.by_jobsite = u.by_jobsite
      AND (wa.nrp = u.username OR wa.full_name = u.full_name)
    ORDER BY
        CASE WHEN wa.nrp = u.username THEN 0 ELSE 1 END,
        CASE WHEN wa.worker_source = N'sis' THEN 0 ELSE 1 END,
        wa.id DESC
) w
WHERE u.deleted_at IS NULL;
GO

-- GL login: group leaders derived from hr.v_workers_active (replaces
-- dbo.v_users_gl_login). A GL is an active worker with job_rank = 5 in a
-- section that has at least one job_rank = 13 worker; one row per nrp
-- (sis before vendor). No password column — auth relies on BYPASS or app rules.
CREATE OR ALTER VIEW hr.v_users_gl_login
AS
WITH leader_sections AS (
    SELECT wa.by_jobsite, wa.section, COUNT(*) AS total
    FROM hr.v_workers_active wa
    WHERE wa.job_rank = 13
    GROUP BY wa.by_jobsite, wa.section
),
gl_source AS (
    SELECT
        wa.by_jobsite,
        wa.nrp AS username,
        wa.full_name,
        wa.jabatan,
        wa.section,
        wa.section_name,
        wa.department,
        wa.department_name,
        wa.gender,
        ls.section AS LS_SEC,
        ls.total,
        ROW_NUMBER() OVER (
            PARTITION BY wa.by_jobsite, wa.nrp
            ORDER BY CASE WHEN wa.worker_source = N'sis' THEN 0 ELSE 1 END, wa.id DESC
        ) AS rn
    FROM hr.v_workers_active wa
    INNER JOIN leader_sections ls
        ON ls.by_jobsite = wa.by_jobsite
       AND ls.section = wa.section
    WHERE wa.job_rank = 5
)
SELECT
    g.username,
    g.full_name,
    g.jabatan,
    g.section,
    g.section_name,
    g.department,
    g.department_name,
    g.LS_SEC,
    g.total,
    N'' AS privilege_menu,
    N'' AS ref_id,
    N'group_leader' AS legacy_level_code,
    N'group_leader' AS level,
    CAST(NULL AS NVARCHAR(255)) AS password,
    g.by_jobsite,
    map.level_id,
    lv.code AS level_code,
    lv.name AS level_name,
    lv.approval_stage,
    lv.structure_scoped,
    CAST(NULL AS NVARCHAR(10)) AS worker_scope,
    CAST(NULL AS NVARCHAR(30)) AS module,
    g.gender,
    g.department AS department_fw,
    g.section AS section_fw,
    CASE
        WHEN lv.code = N'superadmin' THEN N'*'
        ELSE STUFF((
            SELECT N',' + CAST(m.legacy_id AS NVARCHAR(20))
            FROM hr.level_permissions lp
            INNER JOIN hr.menus m ON m.id = lp.menu_id
            WHERE lp.level_id = map.level_id
              AND lp.by_jobsite = g.by_jobsite
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
        WHERE x.level_id = map.level_id AND x.by_jobsite = g.by_jobsite
          AND x.deleted_at IS NULL AND x.can_insert = 1
    ) THEN N'true' ELSE N'false' END AS [create],
    CASE WHEN EXISTS (
        SELECT 1 FROM hr.level_permissions x
        WHERE x.level_id = map.level_id AND x.by_jobsite = g.by_jobsite
          AND x.deleted_at IS NULL AND x.can_read = 1
    ) THEN N'true' ELSE N'false' END AS [read],
    CASE WHEN EXISTS (
        SELECT 1 FROM hr.level_permissions x
        WHERE x.level_id = map.level_id AND x.by_jobsite = g.by_jobsite
          AND x.deleted_at IS NULL AND x.can_update = 1
    ) THEN N'true' ELSE N'false' END AS [update],
    CASE WHEN EXISTS (
        SELECT 1 FROM hr.level_permissions x
        WHERE x.level_id = map.level_id AND x.by_jobsite = g.by_jobsite
          AND x.deleted_at IS NULL AND x.can_delete = 1
    ) THEN N'true' ELSE N'false' END AS [delete],
    CASE WHEN EXISTS (
        SELECT 1 FROM hr.level_permissions x
        WHERE x.level_id = map.level_id AND x.by_jobsite = g.by_jobsite
          AND x.deleted_at IS NULL AND x.can_export = 1
    ) THEN N'true' ELSE N'false' END AS [export],
    CASE WHEN EXISTS (
        SELECT 1 FROM hr.level_permissions x
        WHERE x.level_id = map.level_id AND x.by_jobsite = g.by_jobsite
          AND x.deleted_at IS NULL AND x.can_approve = 1
    ) THEN N'true' ELSE N'false' END AS [approve]
FROM gl_source g
LEFT JOIN hr.level_legacy_map map
    ON map.legacy_code = N'group_leader'
   AND map.by_jobsite = g.by_jobsite
LEFT JOIN hr.levels lv
    ON lv.id = map.level_id
   AND lv.deleted_at IS NULL
LEFT JOIN hr.menu_privilege mp
    ON mp.id = N'group_leader'
   AND mp.by_jobsite = g.by_jobsite
   AND mp.deleted_at IS NULL
WHERE g.rn = 1;
GO

