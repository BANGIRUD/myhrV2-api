-- =============================================
-- Edit Policy module "sakit" (Reconciliation → Sakit)
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
        N'sakit' AS module_code,
        N'Sakit' AS module_name,
        N'Jendela Ubah/Batalkan pengajuan sakit sejak tanggal dibuat' AS description,
        20 AS sort_order
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
    N'sakit',
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
        AND e.module_code = N'sakit'
        AND LOWER(e.level_code) = LOWER(l.code)
        AND e.deleted_at IS NULL
  );

-- Other active levels: cannot edit/cancel until a policy row is changed in the UI.
INSERT INTO hr.edit_policy (
    by_jobsite, module_code, level_code, can_edit, past_days, allow_past, description, created_by
)
SELECT
    @JobsiteId,
    N'sakit',
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
        AND e.module_code = N'sakit'
        AND LOWER(e.level_code) = LOWER(l.code)
        AND e.deleted_at IS NULL
  );

PRINT 'hr.edit_policy module sakit seeded';
GO
