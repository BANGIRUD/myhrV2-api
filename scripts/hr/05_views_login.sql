-- =============================================
-- Views: login row shapes for app (wave 1)
-- Prefer these over hardcoding joins in Node once auth switches to hr.
-- Run AFTER 04_users.sql (level_id enriched after 09_users_level_id.sql)
-- NOTE: 12_views_login_matrix.sql replaces these with level_permissions matrix.
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
    u.section,
    u.description,
    u.email,
    u.phone,
    u.activation_key,
    u.ref_id,
    u.privilege_menu,
    u.level AS legacy_level_code,
    u.legacy_level,
    u.level_id,
    lv.code AS level_code,
    lv.name AS level_name,
    lv.approval_stage,
    lv.structure_scoped,
    u.last_login,
    u.is_active,
    w.gender,
    w.department AS department_fw,
    w.section AS section_fw,
    mp.menu,
    mp.dashboard,
    mp.access_create AS [create],
    mp.access_read AS [read],
    mp.access_update AS [update],
    mp.access_delete AS [delete],
    mp.access_export AS [export]
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

-- Optional: GL login still sourced from legacy view until GL accounts move to hr.users
CREATE OR ALTER VIEW hr.v_users_gl_login
AS
SELECT
    g.*,
    w.gender,
    mp.menu,
    mp.dashboard,
    mp.access_create AS [create],
    mp.access_read AS [read],
    mp.access_update AS [update],
    mp.access_delete AS [delete],
    mp.access_export AS [export]
FROM dbo.v_users_gl_login g
LEFT JOIN hr.menu_privilege mp
    ON g.level = mp.id
   AND mp.by_jobsite = 1
   AND mp.deleted_at IS NULL
LEFT JOIN dbo.v_workers_active w
    ON g.username = w.nrp;
GO
