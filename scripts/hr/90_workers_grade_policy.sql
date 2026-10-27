-- =============================================
-- Field visibility: Grade on employee detail
-- Module hr.edit_policy_modules.workers_grade
--   can_edit = 1 → level may reveal Grade (eye icon)
--   can_edit = 0 → Grade stays masked
-- Default allow: superadmin, sa, hr_administrator
-- Manage later via Master → Edit Policy (module Workers Grade).
-- Run AFTER 48_edit_policy.sql + 49_edit_policy_module_upsert.sql
-- =============================================
DECLARE @JobsiteId INT = 1;

MERGE hr.edit_policy_modules AS t
USING (
    SELECT
        @JobsiteId AS by_jobsite,
        N'workers_grade' AS module_code,
        N'Workers Grade' AS module_name,
        N'Who may reveal the Grade field on employee detail (eye icon). can_edit=1 means allowed.' AS description,
        40 AS sort_order
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
        updated_at = SYSUTCDATETIME()
WHEN NOT MATCHED THEN
    INSERT (by_jobsite, module_code, module_name, description, sort_order, is_active, created_by)
    VALUES (s.by_jobsite, s.module_code, s.module_name, s.description, s.sort_order, 1, NULL);
GO

DECLARE @JobsiteId INT = 1;

-- Ensure every active level has a row (default deny); allow-listed levels get can_edit=1
;WITH levels AS (
    SELECT LOWER(code) AS level_code
    FROM hr.levels
    WHERE by_jobsite = @JobsiteId
      AND deleted_at IS NULL
      AND is_active = 1
),
allowed AS (
    SELECT v.level_code
    FROM (VALUES (N'superadmin'), (N'sa'), (N'hr_administrator')) AS v(level_code)
)
INSERT INTO hr.edit_policy (
    by_jobsite, module_code, level_code, can_edit, past_days, allow_past,
    description, created_by
)
SELECT
    @JobsiteId,
    N'workers_grade',
    l.level_code,
    CASE WHEN a.level_code IS NOT NULL THEN 1 ELSE 0 END,
    0,
    0,
    N'Reveal Grade on employee detail',
    NULL
FROM levels l
LEFT JOIN allowed a ON a.level_code = l.level_code
WHERE NOT EXISTS (
    SELECT 1
    FROM hr.edit_policy e
    WHERE e.by_jobsite = @JobsiteId
      AND e.deleted_at IS NULL
      AND e.module_code = N'workers_grade'
      AND LOWER(e.level_code) = l.level_code
);

-- Re-assert allow-list on re-run (do not flip custom denials for other levels)
UPDATE e
SET can_edit = 1,
    updated_at = SYSUTCDATETIME()
FROM hr.edit_policy e
WHERE e.by_jobsite = @JobsiteId
  AND e.deleted_at IS NULL
  AND e.module_code = N'workers_grade'
  AND LOWER(e.level_code) IN (N'superadmin', N'sa', N'hr_administrator');
GO
