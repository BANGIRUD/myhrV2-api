-- =============================================
-- hr.v_active_submissions
-- Parent pengajuan rows. Status and dates follow the latest child row,
-- same merge as the sickness and permit lists (HR approval lives on the child).
-- A new pengajuan module: add one UNION ALL branch, use applock
-- resource absence:{jobsite}:{nrp}, and reject overlaps where
-- module_code <> the new module. Re-run this file after that edit.
-- =============================================

CREATE OR ALTER VIEW hr.v_active_submissions
AS
SELECT
    N'sickness' AS module_code,
    s.id,
    s.by_jobsite,
    s.nrp,
    s.ref_id,
    ISNULL(child.start_date, s.start_date) AS start_date,
    CASE WHEN child.child_id IS NULL THEN s.end_date ELSE child.end_date END AS end_date,
    s.deleted_at,
    CASE
        WHEN v.verify = N'user' AND ISNULL(v.approve, N'false') = N'false' AND ISNULL(v.reject, N'false') = N'false'
            THEN N'Waiting approve by ' + CASE
                WHEN wa.job_rank = 3 THEN N'Department Head'
                WHEN wa.job_rank = 2 THEN N'Chief Operation'
                WHEN wa.job_rank = 1 THEN N'Personalia'
                WHEN wa.job_rank = 13 THEN N'Group Leader'
                ELSE N'Section Head'
            END
        WHEN v.verify = N'user' AND ISNULL(v.approve, N'false') = N'false' AND ISNULL(v.reject, N'false') = N'true'
            THEN N'Rejected by ' + CASE
                WHEN wa.job_rank = 3 THEN N'Department Head'
                WHEN wa.job_rank = 2 THEN N'Chief Operation'
                WHEN wa.job_rank = 1 THEN N'Personalia'
                WHEN wa.job_rank = 13 THEN N'Group Leader'
                ELSE N'Section Head'
            END
        WHEN v.verify = N'user' AND ISNULL(v.approve, N'false') = N'true' AND ISNULL(v.reject, N'false') = N'false'
            THEN N'Approve by ' + CASE
                WHEN wa.job_rank = 3 THEN N'Department Head'
                WHEN wa.job_rank = 2 THEN N'Chief Operation'
                WHEN wa.job_rank = 1 THEN N'Personalia'
                WHEN wa.job_rank = 13 THEN N'Group Leader'
                ELSE N'Section Head'
            END
        WHEN v.verify = N'section' AND ISNULL(v.approve, N'false') = N'false' AND ISNULL(v.reject, N'false') = N'false'
            THEN N'Waiting approve by HR'
        WHEN v.verify = N'section' AND ISNULL(v.approve, N'false') = N'false' AND ISNULL(v.reject, N'false') = N'true'
            THEN N'Rejected by HR'
        WHEN v.verify = N'section' AND ISNULL(v.approve, N'false') = N'true' AND ISNULL(v.reject, N'false') = N'false'
            THEN N'Approve by HR'
        WHEN v.verify = N'administrator' AND ISNULL(v.approve, N'false') = N'false' AND ISNULL(v.reject, N'false') = N'false'
            THEN N'Approve by HR'
        ELSE N'Waiting approve by Section Head'
    END AS progress,
    ISNULL(NULLIF(LTRIM(RTRIM(u.full_name)), N''), ISNULL(u.username, N'')) AS entered_by
FROM hr.workers_sickness s
OUTER APPLY (
    SELECT TOP (1)
        c.id AS child_id,
        c.verify,
        c.approve,
        c.reject,
        c.start_date,
        c.end_date
    FROM hr.workers_sickness c
    WHERE c.deleted_at IS NULL
      AND c.by_jobsite = s.by_jobsite
      AND c.ref_id = s.id
    ORDER BY c.id DESC
) child
CROSS APPLY (
    SELECT
        ISNULL(child.verify, s.verify) AS verify,
        ISNULL(child.approve, s.approve) AS approve,
        ISNULL(child.reject, s.reject) AS reject
) v
LEFT JOIN hr.v_workers_active wa
    ON wa.by_jobsite = s.by_jobsite
   AND wa.nrp = s.nrp
LEFT JOIN hr.users u
    ON u.id = s.created_by
   AND u.deleted_at IS NULL
WHERE s.deleted_at IS NULL
  AND s.ref_id IS NULL
UNION ALL
SELECT
    N'permit' AS module_code,
    s.id,
    s.by_jobsite,
    s.nrp,
    s.ref_id,
    ISNULL(child.start_date, s.start_date) AS start_date,
    CASE WHEN child.child_id IS NULL THEN s.end_date ELSE child.end_date END AS end_date,
    s.deleted_at,
    CASE
        WHEN v.verify = N'user' AND ISNULL(v.approve, N'false') = N'false' AND ISNULL(v.reject, N'false') = N'false'
            THEN N'Waiting approve by ' + CASE
                WHEN wa.job_rank = 3 THEN N'Department Head'
                WHEN wa.job_rank = 2 THEN N'Chief Operation'
                WHEN wa.job_rank = 1 THEN N'Personalia'
                WHEN wa.job_rank = 13 THEN N'Group Leader'
                ELSE N'Section Head'
            END
        WHEN v.verify = N'user' AND ISNULL(v.approve, N'false') = N'false' AND ISNULL(v.reject, N'false') = N'true'
            THEN N'Rejected by ' + CASE
                WHEN wa.job_rank = 3 THEN N'Department Head'
                WHEN wa.job_rank = 2 THEN N'Chief Operation'
                WHEN wa.job_rank = 1 THEN N'Personalia'
                WHEN wa.job_rank = 13 THEN N'Group Leader'
                ELSE N'Section Head'
            END
        WHEN v.verify = N'user' AND ISNULL(v.approve, N'false') = N'true' AND ISNULL(v.reject, N'false') = N'false'
            THEN N'Approve by ' + CASE
                WHEN wa.job_rank = 3 THEN N'Department Head'
                WHEN wa.job_rank = 2 THEN N'Chief Operation'
                WHEN wa.job_rank = 1 THEN N'Personalia'
                WHEN wa.job_rank = 13 THEN N'Group Leader'
                ELSE N'Section Head'
            END
        WHEN v.verify = N'section' AND ISNULL(v.approve, N'false') = N'false' AND ISNULL(v.reject, N'false') = N'false'
            THEN N'Waiting approve by HR'
        WHEN v.verify = N'section' AND ISNULL(v.approve, N'false') = N'false' AND ISNULL(v.reject, N'false') = N'true'
            THEN N'Rejected by HR'
        WHEN v.verify = N'section' AND ISNULL(v.approve, N'false') = N'true' AND ISNULL(v.reject, N'false') = N'false'
            THEN N'Approve by HR'
        WHEN v.verify = N'administrator' AND ISNULL(v.approve, N'false') = N'false' AND ISNULL(v.reject, N'false') = N'false'
            THEN N'Approve by HR'
        ELSE N'Waiting approve by Section Head'
    END AS progress,
    ISNULL(NULLIF(LTRIM(RTRIM(u.full_name)), N''), ISNULL(u.username, N'')) AS entered_by
FROM hr.workers_permit s
OUTER APPLY (
    SELECT TOP (1)
        c.id AS child_id,
        c.verify,
        c.approve,
        c.reject,
        c.start_date,
        c.end_date
    FROM hr.workers_permit c
    WHERE c.deleted_at IS NULL
      AND c.by_jobsite = s.by_jobsite
      AND c.ref_id = s.id
    ORDER BY c.id DESC
) child
CROSS APPLY (
    SELECT
        ISNULL(child.verify, s.verify) AS verify,
        ISNULL(child.approve, s.approve) AS approve,
        ISNULL(child.reject, s.reject) AS reject
) v
LEFT JOIN hr.v_workers_active wa
    ON wa.by_jobsite = s.by_jobsite
   AND wa.nrp = s.nrp
LEFT JOIN hr.users u
    ON u.id = s.created_by
   AND u.deleted_at IS NULL
WHERE s.deleted_at IS NULL
  AND s.ref_id IS NULL;
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE name = N'IX_hr_workers_sickness_parent_nrp'
      AND object_id = OBJECT_ID(N'hr.workers_sickness')
)
    CREATE INDEX IX_hr_workers_sickness_parent_nrp
        ON hr.workers_sickness (by_jobsite, nrp, start_date, id)
        WHERE deleted_at IS NULL AND ref_id IS NULL;
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE name = N'IX_hr_workers_permit_parent_nrp'
      AND object_id = OBJECT_ID(N'hr.workers_permit')
)
    CREATE INDEX IX_hr_workers_permit_parent_nrp
        ON hr.workers_permit (by_jobsite, nrp, start_date, id)
        WHERE deleted_at IS NULL AND ref_id IS NULL;
GO
