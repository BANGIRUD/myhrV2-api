-- =============================================
-- English menu labels, codes, and URLs
-- Work Pattern, Roster, Sickness, Permit
-- Idempotent. Does not rename tables, procedures, or edit_policy module_code.
-- Run AFTER 73_ijin_inbox.sql
-- =============================================

UPDATE m
SET
    menu_code = v.new_code,
    menu_name = v.new_name,
    menu_url = v.new_url,
    updated_at = SYSUTCDATETIME(),
    updated_by = NULL
FROM hr.menus AS m
INNER JOIN (
    VALUES
        (N'hr_pola_kerja', N'hr_work_pattern', N'Work Pattern', N'/reconciliation/work-pattern'),
        (N'hr_roster_kerja', N'hr_roster', N'Roster', N'/reconciliation/roster'),
        (N'hr_sakit', N'hr_sickness', N'Sickness', N'/reconciliation/sickness'),
        (N'hr_sakit_section', N'hr_sickness_section', N'Sickness', N'/section/sickness'),
        (N'hr_sakit_group', N'hr_sickness_group', N'Sickness', N'/group/sickness'),
        (N'hr_sakit_department', N'hr_sickness_department', N'Sickness', N'/department/sickness'),
        (N'hr_sakit_hr', N'hr_sickness_hr', N'Sickness', N'/personalia/sickness'),
        (N'hr_ijin', N'hr_permit', N'Permit', N'/reconciliation/permit'),
        (N'hr_ijin_section', N'hr_permit_section', N'Permit', N'/section/permit'),
        (N'hr_ijin_group', N'hr_permit_group', N'Permit', N'/group/permit'),
        (N'hr_ijin_department', N'hr_permit_department', N'Permit', N'/department/permit'),
        (N'hr_ijin_hr', N'hr_permit_hr', N'Permit', N'/personalia/permit')
) AS v(old_code, new_code, new_name, new_url)
    ON m.menu_code = v.old_code
   AND m.deleted_at IS NULL
WHERE NOT EXISTS (
    SELECT 1
    FROM hr.menus AS taken
    WHERE taken.by_jobsite = m.by_jobsite
      AND taken.menu_code = v.new_code
      AND taken.deleted_at IS NULL
      AND taken.id <> m.id
);

UPDATE m
SET
    menu_name = v.new_name,
    menu_url = v.new_url,
    updated_at = SYSUTCDATETIME(),
    updated_by = NULL
FROM hr.menus AS m
INNER JOIN (
    VALUES
        (N'hr_work_pattern', N'Work Pattern', N'/reconciliation/work-pattern'),
        (N'hr_roster', N'Roster', N'/reconciliation/roster'),
        (N'hr_sickness', N'Sickness', N'/reconciliation/sickness'),
        (N'hr_sickness_section', N'Sickness', N'/section/sickness'),
        (N'hr_sickness_group', N'Sickness', N'/group/sickness'),
        (N'hr_sickness_department', N'Sickness', N'/department/sickness'),
        (N'hr_sickness_hr', N'Sickness', N'/personalia/sickness'),
        (N'hr_permit', N'Permit', N'/reconciliation/permit'),
        (N'hr_permit_section', N'Permit', N'/section/permit'),
        (N'hr_permit_group', N'Permit', N'/group/permit'),
        (N'hr_permit_department', N'Permit', N'/department/permit'),
        (N'hr_permit_hr', N'Permit', N'/personalia/permit')
) AS v(new_code, new_name, new_url)
    ON m.menu_code = v.new_code
   AND m.deleted_at IS NULL
WHERE m.menu_name <> v.new_name
   OR m.menu_url <> v.new_url;
GO
