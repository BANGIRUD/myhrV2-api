-- =============================================
-- hr.FINGER_ERROR_INBOX_SP — bell rows for fingerprint (section + HR only)
-- Run AFTER 81_finger_error_sp.sql
-- =============================================

/*
  Live fingerprint inbox. Does not replace hr.FINGER_ERROR_SP.

  LIST          waiting rows the caller should see (top 20, no photos).
  RECIPIENTS    hr.users.id values to ping for one new parent row (section ladder).
  HR_RECIPIENTS hr.users.id values to ping after section approve.

  Routing (no GL / department):
    below Section Head                  -> Section Head, or Unit Head if the section has none
    (high ranks / LS group path omitted — section queue only for fingerprint)
*/

CREATE OR ALTER PROCEDURE hr.FINGER_ERROR_INBOX_SP
    @ACTION_SP      NVARCHAR(30),
    @ID             INT = NULL,
    @SCOPE_SECTIONS NVARCHAR(MAX) = NULL,
    @LEVEL_CODE     NVARCHAR(50) = NULL,
    @WORKER_SCOPE   NVARCHAR(20) = NULL,
    @BY_USER        INT = NULL,
    @BY_JOBSITE     INT = 1
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Action NVARCHAR(30) = UPPER(LTRIM(RTRIM(ISNULL(@ACTION_SP, ''))));
    DECLARE @Jobsite INT = ISNULL(@BY_JOBSITE, 1);
    DECLARE @Scope NVARCHAR(MAX) = NULLIF(LTRIM(RTRIM(ISNULL(@SCOPE_SECTIONS, ''))), '');
    DECLARE @SectionHeadRank INT;
    DECLARE @CallerRank INT;
    DECLARE @CallerRankName NVARCHAR(100);

    SELECT @SectionHeadRank = MIN(id)
    FROM hr.enums
    WHERE type = 'position'
      AND deleted_at IS NULL
      AND LOWER(LTRIM(RTRIM(name))) = 'section head';

    SELECT TOP (1)
        @CallerRank = wa.job_rank,
        @CallerRankName = LOWER(LTRIM(RTRIM(e.name)))
    FROM hr.users AS u
    LEFT JOIN hr.v_workers_active AS wa
        ON wa.nrp = u.username
       AND wa.by_jobsite = u.by_jobsite
    LEFT JOIN hr.enums AS e
        ON e.id = wa.job_rank
       AND e.type = 'position'
    WHERE u.id = @BY_USER
      AND u.deleted_at IS NULL;

    DECLARE @Level NVARCHAR(50) = LOWER(LTRIM(RTRIM(ISNULL(@LEVEL_CODE, N''))));
    DECLARE @HrScope NVARCHAR(20) = LOWER(LTRIM(RTRIM(ISNULL(@WORKER_SCOPE, N''))));
    IF @Level IN (N'superadmin', N'sa') SET @HrScope = N'all';

    IF @Action = 'LIST'
       AND @Level IN (N'hr_admin', N'hr_administrator')
       AND @HrScope IN (N'sis', N'ls', N'all')
    BEGIN
        SELECT TOP (20)
            s.id,
            s.nrp,
            ISNULL(wa.full_name, s.nrp) AS full_name,
            ISNULL(wa.jabatan, N'') AS jabatan,
            N'hr' AS queue,
            N'/personalia/finger-error' AS url,
            s.created_at
        FROM hr.workers_finger_error AS s
        INNER JOIN hr.v_workers_active AS wa
            ON wa.nrp = s.nrp
           AND wa.by_jobsite = s.by_jobsite
        CROSS APPLY (
            SELECT TOP (1) c.verify, c.approve, c.reject
            FROM hr.workers_finger_error AS c
            WHERE c.ref_id = s.id
              AND c.by_jobsite = s.by_jobsite
              AND c.deleted_at IS NULL
            ORDER BY c.id DESC
        ) AS latest
        WHERE s.by_jobsite = @Jobsite
          AND s.deleted_at IS NULL
          AND s.ref_id IS NULL
          AND latest.verify = N'section'
          AND ISNULL(latest.approve, N'false') = N'false'
          AND ISNULL(latest.reject, N'false') = N'false'
          AND (
                @HrScope = N'all'
             OR (@HrScope = N'ls' AND LOWER(ISNULL(wa.worker_source, N'')) = N'vendor')
             OR (@HrScope = N'sis' AND LOWER(ISNULL(wa.worker_source, N'')) <> N'vendor')
          )
        ORDER BY s.id DESC;
        RETURN;
    END;

    IF @Action = 'LIST'
    BEGIN
        IF @Scope IS NULL OR @CallerRankName IS NULL
        BEGIN
            SELECT TOP (0)
                CAST(NULL AS INT) AS id,
                CAST(NULL AS NVARCHAR(50)) AS nrp,
                CAST(NULL AS NVARCHAR(200)) AS full_name,
                CAST(NULL AS NVARCHAR(200)) AS jabatan,
                CAST(NULL AS NVARCHAR(20)) AS queue,
                CAST(NULL AS NVARCHAR(40)) AS url,
                CAST(NULL AS DATETIME) AS created_at;
            RETURN;
        END;

        ;WITH waiting AS (
            SELECT
                s.id,
                s.nrp,
                ISNULL(wa.full_name, s.nrp) AS full_name,
                ISNULL(wa.jabatan, '') AS jabatan,
                wa.section AS section_id,
                LOWER(ISNULL(wa.worker_source, '')) AS worker_source,
                wa.job_rank,
                LOWER(LTRIM(RTRIM(ISNULL(e.name, '')))) AS rank_name,
                s.created_at,
                CASE
                    WHEN LOWER(LTRIM(RTRIM(ISNULL(e.name, '')))) IN
                        ('section head', 'department head', 'division head', 'chief operation', 'personalia')
                      OR (@SectionHeadRank IS NOT NULL AND wa.job_rank <= @SectionHeadRank)
                    THEN 1 ELSE 0
                END AS is_high
            FROM hr.workers_finger_error AS s
            INNER JOIN hr.v_workers_active AS wa
                ON wa.nrp = s.nrp
               AND wa.by_jobsite = s.by_jobsite
            LEFT JOIN hr.enums AS e
                ON e.id = wa.job_rank
               AND e.type = 'position'
            WHERE s.by_jobsite = @Jobsite
              AND s.deleted_at IS NULL
              AND s.ref_id IS NULL
              AND ISNULL(s.verify, N'') = N'user'
              AND ISNULL(s.approve, N'false') = N'false'
              AND ISNULL(s.reject, N'false') = N'false'
              AND NOT EXISTS (
                    SELECT 1
                    FROM hr.workers_finger_error AS child
                    WHERE child.ref_id = s.id
                      AND child.deleted_at IS NULL
              )
              AND ISNULL(s.created_by, 0) <> ISNULL(@BY_USER, 0)
              AND EXISTS (
                    SELECT 1
                    FROM STRING_SPLIT(REPLACE(@Scope, N' ', N''), N',') AS scope_row
                    WHERE TRY_CAST(LTRIM(RTRIM(scope_row.value)) AS INT) = wa.section
              )
        )
        SELECT TOP (20)
            w.id,
            w.nrp,
            w.full_name,
            w.jabatan,
            N'section' AS queue,
            N'/section/finger-error' AS url,
            w.created_at
        FROM waiting AS w
        WHERE
            w.is_high = 0
            AND (
                @CallerRankName = 'section head'
                OR (
                    @CallerRankName = 'unit head'
                    AND NOT EXISTS (
                        SELECT 1
                        FROM hr.v_workers_active AS sh
                        WHERE sh.by_jobsite = @Jobsite
                          AND sh.section = w.section_id
                          AND sh.job_rank = @SectionHeadRank
                    )
                )
            )
        ORDER BY w.id DESC;
        RETURN;
    END;

    IF @Action = 'RECIPIENTS'
    BEGIN
        DECLARE @Section INT;
        DECLARE @Department INT;
        DECLARE @IsHigh BIT = 0;
        DECLARE @Actor INT;

        SELECT
            @Section = wa.section,
            @Department = wa.department,
            @IsHigh = CASE
                WHEN LOWER(LTRIM(RTRIM(ISNULL(e.name, '')))) IN
                    ('section head', 'department head', 'division head', 'chief operation', 'personalia')
                  OR (@SectionHeadRank IS NOT NULL AND wa.job_rank <= @SectionHeadRank)
                THEN 1 ELSE 0
            END,
            @Actor = s.created_by
        FROM hr.workers_finger_error AS s
        INNER JOIN hr.v_workers_active AS wa
            ON wa.nrp = s.nrp
           AND wa.by_jobsite = s.by_jobsite
        LEFT JOIN hr.enums AS e
            ON e.id = wa.job_rank
           AND e.type = 'position'
        WHERE s.id = @ID
          AND s.by_jobsite = @Jobsite
          AND s.ref_id IS NULL
          AND s.deleted_at IS NULL;

        IF @Section IS NULL OR @IsHigh = 1
        BEGIN
            SELECT TOP (0) CAST(NULL AS INT) AS user_id;
            RETURN;
        END;

        SELECT DISTINCT
            u.id AS user_id,
            s.nrp,
            ISNULL(wa.full_name, s.nrp) AS full_name,
            ISNULL(wa.jabatan, '') AS jabatan,
            N'section' AS queue,
            N'/section/finger-error' AS url
        FROM hr.workers_finger_error AS s
        INNER JOIN hr.v_workers_active AS wa
            ON wa.nrp = s.nrp
           AND wa.by_jobsite = s.by_jobsite
        CROSS JOIN hr.users AS u
        INNER JOIN hr.v_workers_active AS boss
            ON boss.nrp = u.username
           AND boss.by_jobsite = u.by_jobsite
        INNER JOIN hr.enums AS er
            ON er.id = boss.job_rank
           AND er.type = 'position'
        WHERE s.id = @ID
          AND s.by_jobsite = @Jobsite
          AND u.deleted_at IS NULL
          AND u.by_jobsite = @Jobsite
          AND u.id <> ISNULL(@Actor, 0)
          AND (
                EXISTS (
                    SELECT 1
                    FROM STRING_SPLIT(REPLACE(ISNULL(u.section, N''), N' ', N''), N',') AS sec
                    WHERE TRY_CAST(LTRIM(RTRIM(sec.value)) AS INT) = @Section
                )
                OR (
                    NULLIF(LTRIM(RTRIM(ISNULL(u.section, ''))), '') IS NULL
                    AND EXISTS (
                        SELECT 1
                        FROM STRING_SPLIT(REPLACE(ISNULL(u.department, N''), N' ', N''), N',') AS dep
                        WHERE TRY_CAST(LTRIM(RTRIM(dep.value)) AS INT) = @Department
                    )
                )
          )
          AND (
                LOWER(LTRIM(RTRIM(er.name))) = 'section head'
                OR (
                    LOWER(LTRIM(RTRIM(er.name))) = 'unit head'
                    AND NOT EXISTS (
                        SELECT 1
                        FROM hr.v_workers_active AS sh
                        WHERE sh.by_jobsite = @Jobsite
                          AND sh.section = @Section
                          AND sh.job_rank = @SectionHeadRank
                    )
                )
          );
        RETURN;
    END;

    IF @Action = 'HR_RECIPIENTS'
    BEGIN
        SELECT DISTINCT
            u.id AS user_id,
            s.nrp,
            ISNULL(wa.full_name, s.nrp) AS full_name,
            ISNULL(wa.jabatan, N'') AS jabatan,
            N'hr' AS queue,
            N'/personalia/finger-error' AS url
        FROM hr.workers_finger_error AS s
        INNER JOIN hr.v_workers_active AS wa
            ON wa.nrp = s.nrp
           AND wa.by_jobsite = s.by_jobsite
        INNER JOIN hr.users AS u
            ON u.by_jobsite = s.by_jobsite
           AND u.deleted_at IS NULL
        INNER JOIN hr.levels AS lv
            ON lv.id = u.level_id
           AND lv.by_jobsite = u.by_jobsite
           AND lv.deleted_at IS NULL
        WHERE s.id = @ID
          AND s.by_jobsite = @Jobsite
          AND s.deleted_at IS NULL
          AND LOWER(lv.code) IN (N'hr_admin', N'hr_administrator')
          AND u.id <> ISNULL(s.created_by, 0)
          AND (
                LOWER(LTRIM(RTRIM(ISNULL(u.worker_scope, N'')))) = N'all'
             OR (
                    LOWER(ISNULL(wa.worker_source, N'')) = N'vendor'
                AND LOWER(LTRIM(RTRIM(ISNULL(u.worker_scope, N'')))) = N'ls'
                )
             OR (
                    LOWER(ISNULL(wa.worker_source, N'')) <> N'vendor'
                AND LOWER(LTRIM(RTRIM(ISNULL(u.worker_scope, N'')))) = N'sis'
                )
          );
        RETURN;
    END;

    SELECT CAST(0 AS BIT) AS success, 'Unknown ACTION_SP' AS message;
END;
GO
