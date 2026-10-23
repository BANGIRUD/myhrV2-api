-- =============================================
-- hr.SAKIT_SP — CRUD phase 2
-- Actions: SELECT | GET | LOOKUP | INSERT | UPDATE | CANCEL
-- SELECT adds evidence_paths from hr.workers_sickness_photos
-- Run AFTER 52_sakit_sp.sql + 55_workers_sickness_photos.sql
-- =============================================

IF OBJECT_ID('hr.workers_sickness', 'U') IS NULL
BEGIN
    THROW 50056, 'hr.workers_sickness missing. Apply 35/52 first.', 1;
END;
GO

CREATE OR ALTER PROCEDURE hr.SAKIT_SP
    @ACTION_SP NVARCHAR(30) = NULL,
    @ID INT = NULL,
    @MONTH NVARCHAR(7) = NULL,          -- YYYY-MM
    @DEPARTMENT NVARCHAR(250) = NULL,
    @SECTION NVARCHAR(250) = NULL,
    @JOB_RANK NVARCHAR(50) = NULL,
    @PROGRESS NVARCHAR(10) = NULL,      -- 0/'' ALL; 1 waiting SH; 2 waiting HR; 3 rejected SH; 4 rejected HR
    @STATUS_WORKER NVARCHAR(20) = NULL, -- sis | vendor (maps to v_workers_active.worker_source)
    @PAGE INT = 1,
    @PAGE_SIZE INT = 0,
    @SEARCH NVARCHAR(150) = NULL,
    @SCOPE_SECTIONS NVARCHAR(MAX) = NULL,
    @NRP NVARCHAR(40) = NULL,
    @DATE_ISSUE DATE = NULL,
    @CATEGORY NVARCHAR(150) = NULL,
    @NAME_DOCTOR NVARCHAR(150) = NULL,
    @NAME_AGENCY NVARCHAR(150) = NULL,
    @DIAGNOSA NVARCHAR(150) = NULL,
    @START_DATE DATE = NULL,
    @END_DATE DATE = NULL,
    @DESCRIPTION NVARCHAR(MAX) = NULL,
    @FULL_NAME NVARCHAR(200) = NULL,
    @LEVEL_CODE NVARCHAR(50) = NULL,
    @BY_USER INT = NULL,
    @BY_JOBSITE INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Jobsite INT = ISNULL(@BY_JOBSITE, 1);
    DECLARE @LevelKey NVARCHAR(50) = LOWER(LTRIM(RTRIM(ISNULL(@LEVEL_CODE, N''))));
    -- hr.edit_policy module sakit: past_days = max age from created_at; allow_past = no day limit.
    DECLARE @PolCanEdit BIT = 0;
    DECLARE @PolAllowPast BIT = 0;
    DECLARE @PolPastDays INT = 3;

    IF OBJECT_ID(N'hr.edit_policy', N'U') IS NOT NULL AND @LevelKey <> N''
    BEGIN
        SELECT TOP 1
            @PolCanEdit = p.can_edit,
            @PolAllowPast = p.allow_past,
            @PolPastDays = p.past_days
        FROM hr.edit_policy p
        WHERE p.by_jobsite = @Jobsite
          AND p.deleted_at IS NULL
          AND LOWER(p.module_code) = N'sakit'
          AND LOWER(p.level_code) = @LevelKey;
    END
    DECLARE @NrpClean NVARCHAR(40) = UPPER(LTRIM(RTRIM(ISNULL(@NRP, N''))));
    DECLARE @IDCHECK INT = NULL;
    DECLARE @ActorLegacy BIGINT = NULL;
    DECLARE @LevelCode NVARCHAR(50) = NULL;
    DECLARE @BypassH3 BIT = 0;
    DECLARE @Cat NVARCHAR(150) = LOWER(LTRIM(RTRIM(ISNULL(@CATEGORY, N''))));
    DECLARE @Desc NVARCHAR(MAX) = NULLIF(LTRIM(RTRIM(@DESCRIPTION)), N'');
    DECLARE @WorkerName NVARCHAR(200) = NULLIF(LTRIM(RTRIM(@FULL_NAME)), N'');
    DECLARE @EffEnd DATE = NULL;
    DECLARE @EffStart DATE = NULL;

    BEGIN TRY
        IF @ACTION_SP = N'SELECT'
        BEGIN
            DECLARE @Dept NVARCHAR(250) = ISNULL(LTRIM(RTRIM(@DEPARTMENT)), N'');
            DECLARE @Sect NVARCHAR(250) = ISNULL(LTRIM(RTRIM(@SECTION)), N'');
            DECLARE @JobRank INT = TRY_CAST(NULLIF(LTRIM(RTRIM(@JOB_RANK)), N'') AS INT);
            DECLARE @Prog NVARCHAR(10) = ISNULL(LTRIM(RTRIM(@PROGRESS)), N'');
            DECLARE @StatWorker NVARCHAR(20) = LOWER(ISNULL(LTRIM(RTRIM(@STATUS_WORKER)), N''));
            DECLARE @Scope NVARCHAR(MAX) = ISNULL(LTRIM(RTRIM(@SCOPE_SECTIONS)), N'');
            DECLARE @Q NVARCHAR(150) = NULLIF(LTRIM(RTRIM(@SEARCH)), N'');
            DECLARE @HasScope BIT = CASE WHEN @Scope = N'' THEN 0 ELSE 1 END;

            DECLARE @ScopeIds TABLE (id INT PRIMARY KEY);
            IF @HasScope = 1
            BEGIN
                INSERT INTO @ScopeIds (id)
                SELECT DISTINCT TRY_CAST(LTRIM(RTRIM(value)) AS INT)
                FROM STRING_SPLIT(@Scope, N',')
                WHERE TRY_CAST(LTRIM(RTRIM(value)) AS INT) IS NOT NULL;
            END

            DECLARE @MonthRaw NVARCHAR(7) = NULLIF(LTRIM(RTRIM(@MONTH)), N'');
            DECLARE @Year INT;
            DECLARE @Mon INT;
            DECLARE @FromDate DATE;
            DECLARE @ToDate DATE;

            IF @MonthRaw IS NOT NULL
               AND LEN(@MonthRaw) = 7
               AND SUBSTRING(@MonthRaw, 5, 1) = N'-'
            BEGIN
                SET @Year = TRY_CAST(LEFT(@MonthRaw, 4) AS INT);
                SET @Mon = TRY_CAST(RIGHT(@MonthRaw, 2) AS INT);
            END

            IF @Year IS NULL OR @Mon IS NULL OR @Mon < 1 OR @Mon > 12
            BEGIN
                SET @Year = YEAR(GETDATE());
                SET @Mon = MONTH(GETDATE());
            END

            SET @FromDate = DATEFROMPARTS(@Year, @Mon, 1);
            SET @ToDate = DATEADD(MONTH, 1, @FromDate);

            IF @PAGE IS NULL OR @PAGE < 1
                SET @PAGE = 1;
            IF @PAGE_SIZE IS NULL
                SET @PAGE_SIZE = 0;

            -- Month filter = periode pengajuan (start_date..end_date, after child merge)
            -- intersects selected month. Open end (NULL) treated as start_date only.
            ;WITH candidates AS (
                SELECT s.*
                FROM hr.workers_sickness s
                WHERE s.deleted_at IS NULL
                  AND s.by_jobsite = @Jobsite
                  AND s.ref_id IS NULL
                  AND s.start_date IS NOT NULL
                  AND s.start_date < @ToDate
                  AND (
                        -- open end: only if start falls in/after month start (legacy-safe)
                        (s.end_date IS NULL AND s.start_date >= @FromDate)
                     OR (s.end_date IS NOT NULL AND s.end_date >= @FromDate)
                      )
            ),
            latest_child AS (
                SELECT
                    c.ref_id,
                    c.start_date,
                    c.end_date,
                    c.note,
                    c.description,
                    c.verify,
                    c.approve,
                    c.reject
                FROM (
                    SELECT
                        s.id,
                        s.ref_id,
                        ROW_NUMBER() OVER (PARTITION BY s.ref_id ORDER BY s.id DESC) AS rn
                    FROM hr.workers_sickness s
                    INNER JOIN candidates p ON p.id = s.ref_id
                    WHERE s.deleted_at IS NULL
                      AND s.by_jobsite = @Jobsite
                      AND s.ref_id IS NOT NULL
                ) x
                INNER JOIN hr.workers_sickness c ON c.id = x.id
                WHERE x.rn = 1
            ),
            child_audit AS (
                SELECT
                    s.ref_id,
                    MAX(CASE WHEN s.verify = N'section' THEN s.created_at END) AS by_date_verified_section,
                    MAX(CASE WHEN s.verify = N'section' THEN s.by_user END) AS by_verified_section,
                    MAX(CASE WHEN s.verify = N'section' THEN s.updated_at END) AS updated_verified_section,
                    MAX(CASE WHEN s.verify = N'administrator' THEN s.by_user END) AS by_verified_hr,
                    MAX(CASE WHEN s.verify = N'administrator' THEN s.created_at END) AS by_date_verified_hr
                FROM hr.workers_sickness s
                INNER JOIN candidates p ON p.id = s.ref_id
                WHERE s.deleted_at IS NULL
                  AND s.by_jobsite = @Jobsite
                  AND s.ref_id IS NOT NULL
                GROUP BY s.ref_id
            ),
            merged AS (
                SELECT
                    p.id,
                    p.by_jobsite,
                    p.ref_id,
                    p.key_id,
                    p.created_at,
                    p.updated_at,
                    p.[date],
                    p.nrp,
                    p.nrp_int,
                    p.full_name AS sickness_full_name,
                    p.diagnosa,
                    p.name_doctor,
                    p.name_agency,
                    p.date_issue,
                    ISNULL(c.start_date, p.start_date) AS start_date,
                    CASE
                        WHEN c.ref_id IS NULL THEN p.end_date
                        ELSE c.end_date
                    END AS end_date,
                    p.category,
                    p.path_evident,
                    CASE
                        WHEN c.ref_id IS NULL THEN p.description
                        WHEN c.description IS NULL AND c.end_date IS NULL THEN p.description
                        ELSE c.description
                    END AS description,
                    ISNULL(c.note, p.note) AS note,
                    ISNULL(c.verify, p.verify) AS verify,
                    ISNULL(c.approve, p.approve) AS approve,
                    ISNULL(c.reject, p.reject) AS reject,
                    p.by_verified,
                    p.by_user,
                    p.kriteria,
                    p.note_dokter,
                    p.note_hr,
                    ca.by_date_verified_section,
                    ca.by_verified_section,
                    ca.updated_verified_section,
                    ca.by_verified_hr,
                    ca.by_date_verified_hr
                FROM candidates p
                LEFT JOIN latest_child c ON c.ref_id = p.id
                LEFT JOIN child_audit ca ON ca.ref_id = p.id
            ),
            parents AS (
                -- Final gate on effective (merged) start/end of the pengajuan
                SELECT m.*
                FROM merged m
                WHERE m.start_date < @ToDate
                  AND ISNULL(m.end_date, m.start_date) >= @FromDate
            ),
            base AS (
                SELECT
                    m.id,
                    m.by_jobsite,
                    m.key_id,
                    CAST(m.created_at AS DATE) AS input_date,
                    m.date_issue,
                    m.nrp,
                    ISNULL(NULLIF(LTRIM(RTRIM(wa.full_name)), N''), ISNULL(m.sickness_full_name, N'')) AS full_name,
                    ISNULL(wa.jabatan, N'') AS jabatan,
                    wa.job_rank,
                    wa.department,
                    ISNULL(wa.department_name, N'') AS department_name,
                    wa.[section],
                    ISNULL(wa.section_name, N'') AS section_name,
                    wa.worker_source AS status_worker,
                    m.category,
                    CASE
                        WHEN m.category = N'inpatient' THEN N'RAWAT INAP'
                        WHEN m.category = N'outpatient' THEN N'RAWAT JALAN'
                        ELSE N'PASCA RAWAT INAP'
                    END AS category_name,
                    m.name_doctor,
                    m.name_agency,
                    m.diagnosa,
                    m.start_date,
                    m.end_date,
                    CASE
                        WHEN m.start_date IS NULL THEN NULL
                        WHEN m.end_date IS NULL THEN DATEDIFF(DAY, m.start_date, CAST(GETDATE() AS DATE)) + 1
                        ELSE DATEDIFF(DAY, m.start_date, m.end_date) + 1
                    END AS [day],
                    m.path_evident,
                    (
                        SELECT STRING_AGG(ph.fullpath, N'|') WITHIN GROUP (ORDER BY ph.id)
                        FROM hr.workers_sickness_photos ph
                        WHERE ph.deleted_at IS NULL
                          AND ph.by_jobsite = m.by_jobsite
                          AND ph.ref_id = m.id
                          AND ph.support_attach IS NULL
                    ) AS evidence_paths,
                    m.description,
                    m.note,
                    m.verify,
                    m.approve,
                    m.reject,
                    CASE
                        WHEN m.verify = N'user' AND ISNULL(m.approve, N'false') = N'false' AND ISNULL(m.reject, N'false') = N'false'
                            THEN N'Waiting approve by ' + CASE
                                WHEN wa.job_rank = 3 THEN N'Department Head'
                                WHEN wa.job_rank = 2 THEN N'Chief Operation'
                                WHEN wa.job_rank = 1 THEN N'Personalia'
                                WHEN wa.job_rank = 13 THEN N'Group Leader'
                                ELSE N'Section Head'
                            END
                        WHEN m.verify = N'user' AND ISNULL(m.approve, N'false') = N'false' AND ISNULL(m.reject, N'false') = N'true'
                            THEN N'Rejected by ' + CASE
                                WHEN wa.job_rank = 3 THEN N'Department Head'
                                WHEN wa.job_rank = 2 THEN N'Chief Operation'
                                WHEN wa.job_rank = 1 THEN N'Personalia'
                                WHEN wa.job_rank = 13 THEN N'Group Leader'
                                ELSE N'Section Head'
                            END
                        WHEN m.verify = N'user' AND ISNULL(m.approve, N'false') = N'true' AND ISNULL(m.reject, N'false') = N'false'
                            THEN N'Approve by ' + CASE
                                WHEN wa.job_rank = 3 THEN N'Department Head'
                                WHEN wa.job_rank = 2 THEN N'Chief Operation'
                                WHEN wa.job_rank = 1 THEN N'Personalia'
                                WHEN wa.job_rank = 13 THEN N'Group Leader'
                                ELSE N'Section Head'
                            END
                        WHEN m.verify = N'section' AND ISNULL(m.approve, N'false') = N'false' AND ISNULL(m.reject, N'false') = N'false'
                            THEN N'Waiting approve by HR'
                        WHEN m.verify = N'section' AND ISNULL(m.approve, N'false') = N'false' AND ISNULL(m.reject, N'false') = N'true'
                            THEN N'Rejected by HR'
                        WHEN m.verify = N'section' AND ISNULL(m.approve, N'false') = N'true' AND ISNULL(m.reject, N'false') = N'false'
                            THEN N'Approve by HR'
                        WHEN m.verify = N'administrator' AND ISNULL(m.approve, N'false') = N'false' AND ISNULL(m.reject, N'false') = N'false'
                            THEN N'Approve by HR'
                        ELSE N'Waiting approve by Section Head'
                    END AS progress,
                    CASE
                        WHEN m.verify = N'user' AND ISNULL(m.approve, N'false') = N'false' AND ISNULL(m.reject, N'false') = N'false'
                            THEN N'false'
                        ELSE N'true'
                    END AS status_progress,
                    -- Ubah / Batalkan: pending + hr.edit_policy (module sakit) for this level
                    CASE
                        WHEN @PolCanEdit = 1
                         AND m.verify = N'user'
                         AND ISNULL(m.approve, N'false') = N'false'
                         AND ISNULL(m.reject, N'false') = N'false'
                         AND (
                                @PolAllowPast = 1
                             OR DATEDIFF(DAY, CAST(m.created_at AS DATE), CAST(GETDATE() AS DATE)) <= ISNULL(@PolPastDays, 0)
                             )
                            THEN N'true'
                        ELSE N'false'
                    END AS can_edit,
                    CASE
                        WHEN @PolCanEdit = 1
                         AND m.verify = N'user'
                         AND ISNULL(m.approve, N'false') = N'false'
                         AND ISNULL(m.reject, N'false') = N'false'
                         AND (
                                @PolAllowPast = 1
                             OR DATEDIFF(DAY, CAST(m.created_at AS DATE), CAST(GETDATE() AS DATE)) <= ISNULL(@PolPastDays, 0)
                             )
                            THEN N'true'
                        ELSE N'false'
                    END AS can_cancel,
                    ISNULL(u_in.full_name, N'') AS name_input,
                    -- SH columns blank while still Waiting Section (verify=user),
                    -- and also blank when Rejected by HR (moved to reject_* like legacy UI).
                    CASE
                        WHEN m.verify = N'user' THEN NULL
                        WHEN m.verify = N'section'
                         AND ISNULL(m.approve, N'false') = N'false'
                         AND ISNULL(m.reject, N'false') = N'true'
                            THEN NULL
                        ELSE m.by_date_verified_section
                    END AS by_date_verified_section,
                    CASE
                        WHEN m.verify = N'user' THEN NULL
                        WHEN m.verify = N'section'
                         AND ISNULL(m.approve, N'false') = N'false'
                         AND ISNULL(m.reject, N'false') = N'true'
                            THEN N''
                        ELSE ISNULL(u_sh.full_name, N'')
                    END AS by_checked_name,
                    CASE
                        WHEN m.verify = N'user' THEN NULL
                        ELSE m.by_date_verified_hr
                    END AS approved_at,
                    CASE
                        WHEN m.verify = N'user' THEN NULL
                        ELSE ISNULL(u_hr.full_name, N'')
                    END AS by_approved_name,
                    -- Legacy: reject_* filled only for Rejected by HR
                    CASE
                        WHEN m.verify = N'section'
                         AND ISNULL(m.approve, N'false') = N'false'
                         AND ISNULL(m.reject, N'false') = N'true'
                            THEN m.updated_verified_section
                        ELSE NULL
                    END AS reject_date,
                    CASE
                        WHEN m.verify = N'section'
                         AND ISNULL(m.approve, N'false') = N'false'
                         AND ISNULL(m.reject, N'false') = N'true'
                            THEN ISNULL(u_sh.full_name, N'')
                        ELSE N''
                    END AS reject_by,
                    m.created_at,
                    m.updated_at
                FROM parents m
                LEFT JOIN hr.v_workers_active wa
                    ON wa.nrp = m.nrp
                   AND wa.by_jobsite = m.by_jobsite
                -- workers_sickness.by_user stores OLD dbo.users.id → join hr.users.legacy_id
                LEFT JOIN hr.users u_in
                    ON u_in.legacy_id = TRY_CAST(m.by_user AS INT)
                   AND u_in.by_jobsite = m.by_jobsite
                   AND u_in.deleted_at IS NULL
                LEFT JOIN hr.users u_sh
                    ON u_sh.legacy_id = TRY_CAST(m.by_verified_section AS INT)
                   AND u_sh.by_jobsite = m.by_jobsite
                   AND u_sh.deleted_at IS NULL
                LEFT JOIN hr.users u_hr
                    ON u_hr.legacy_id = TRY_CAST(m.by_verified_hr AS INT)
                   AND u_hr.by_jobsite = m.by_jobsite
                   AND u_hr.deleted_at IS NULL
                WHERE (@Dept = N'' OR wa.department IN (
                        SELECT TRY_CAST(LTRIM(RTRIM(value)) AS INT)
                        FROM STRING_SPLIT(@Dept, N',')
                        WHERE TRY_CAST(LTRIM(RTRIM(value)) AS INT) IS NOT NULL
                      ))
                  AND (@Sect = N'' OR wa.[section] IN (
                        SELECT TRY_CAST(LTRIM(RTRIM(value)) AS INT)
                        FROM STRING_SPLIT(@Sect, N',')
                        WHERE TRY_CAST(LTRIM(RTRIM(value)) AS INT) IS NOT NULL
                      ))
                  AND (@JobRank IS NULL OR wa.job_rank = @JobRank)
                  AND (@StatWorker = N'' OR wa.worker_source = @StatWorker)
                  AND (
                        @HasScope = 0
                     OR wa.[section] IN (SELECT id FROM @ScopeIds)
                      )
                  AND (
                        @Prog = N'' OR @Prog = N'0'
                     OR (@Prog = N'1' AND m.verify = N'user' AND ISNULL(m.approve, N'false') = N'false' AND ISNULL(m.reject, N'false') = N'false')
                     OR (@Prog = N'2' AND m.verify = N'section' AND ISNULL(m.approve, N'false') = N'false' AND ISNULL(m.reject, N'false') = N'false')
                     OR (@Prog = N'3' AND m.verify = N'user' AND ISNULL(m.approve, N'false') = N'false' AND ISNULL(m.reject, N'false') = N'true')
                     OR (@Prog = N'4' AND m.verify = N'section' AND ISNULL(m.approve, N'false') = N'false' AND ISNULL(m.reject, N'false') = N'true')
                      )
                  AND (
                        @Q IS NULL
                     OR m.nrp LIKE N'%' + @Q + N'%'
                     OR ISNULL(wa.full_name, m.sickness_full_name) LIKE N'%' + @Q + N'%'
                     OR m.diagnosa LIKE N'%' + @Q + N'%'
                     OR m.name_doctor LIKE N'%' + @Q + N'%'
                      )
            )
            SELECT *
            FROM base
            ORDER BY start_date DESC, id DESC
            OFFSET CASE WHEN @PAGE_SIZE > 0 THEN (@PAGE - 1) * @PAGE_SIZE ELSE 0 END ROWS
            FETCH NEXT CASE WHEN @PAGE_SIZE > 0 THEN @PAGE_SIZE ELSE 100000 END ROWS ONLY;

            ;WITH candidates AS (
                SELECT s.*
                FROM hr.workers_sickness s
                WHERE s.deleted_at IS NULL
                  AND s.by_jobsite = @Jobsite
                  AND s.ref_id IS NULL
                  AND s.start_date IS NOT NULL
                  AND s.start_date < @ToDate
                  AND (
                        (s.end_date IS NULL AND s.start_date >= @FromDate)
                     OR (s.end_date IS NOT NULL AND s.end_date >= @FromDate)
                      )
            ),
            latest_child AS (
                SELECT
                    c.ref_id,
                    c.start_date,
                    c.end_date,
                    c.verify,
                    c.approve,
                    c.reject
                FROM (
                    SELECT
                        s.id,
                        s.ref_id,
                        ROW_NUMBER() OVER (PARTITION BY s.ref_id ORDER BY s.id DESC) AS rn
                    FROM hr.workers_sickness s
                    INNER JOIN candidates p ON p.id = s.ref_id
                    WHERE s.deleted_at IS NULL
                      AND s.by_jobsite = @Jobsite
                      AND s.ref_id IS NOT NULL
                ) x
                INNER JOIN hr.workers_sickness c ON c.id = x.id
                WHERE x.rn = 1
            ),
            merged AS (
                SELECT
                    p.id,
                    p.nrp,
                    p.full_name AS sickness_full_name,
                    p.diagnosa,
                    p.name_doctor,
                    ISNULL(c.start_date, p.start_date) AS start_date,
                    CASE
                        WHEN c.ref_id IS NULL THEN p.end_date
                        ELSE c.end_date
                    END AS end_date,
                    ISNULL(c.verify, p.verify) AS verify,
                    ISNULL(c.approve, p.approve) AS approve,
                    ISNULL(c.reject, p.reject) AS reject
                FROM candidates p
                LEFT JOIN latest_child c ON c.ref_id = p.id
            ),
            parents AS (
                SELECT m.*
                FROM merged m
                WHERE m.start_date < @ToDate
                  AND ISNULL(m.end_date, m.start_date) >= @FromDate
            )
            SELECT COUNT(*) AS total_count
            FROM parents m
            LEFT JOIN hr.v_workers_active wa
                ON wa.nrp = m.nrp
               AND wa.by_jobsite = @Jobsite
            WHERE (@Dept = N'' OR wa.department IN (
                    SELECT TRY_CAST(LTRIM(RTRIM(value)) AS INT)
                    FROM STRING_SPLIT(@Dept, N',')
                    WHERE TRY_CAST(LTRIM(RTRIM(value)) AS INT) IS NOT NULL
                  ))
              AND (@Sect = N'' OR wa.[section] IN (
                    SELECT TRY_CAST(LTRIM(RTRIM(value)) AS INT)
                    FROM STRING_SPLIT(@Sect, N',')
                    WHERE TRY_CAST(LTRIM(RTRIM(value)) AS INT) IS NOT NULL
                  ))
              AND (@JobRank IS NULL OR wa.job_rank = @JobRank)
              AND (@StatWorker = N'' OR wa.worker_source = @StatWorker)
              AND (
                    @HasScope = 0
                 OR wa.[section] IN (SELECT id FROM @ScopeIds)
                  )
              AND (
                    @Prog = N'' OR @Prog = N'0'
                 OR (@Prog = N'1' AND m.verify = N'user' AND ISNULL(m.approve, N'false') = N'false' AND ISNULL(m.reject, N'false') = N'false')
                 OR (@Prog = N'2' AND m.verify = N'section' AND ISNULL(m.approve, N'false') = N'false' AND ISNULL(m.reject, N'false') = N'false')
                 OR (@Prog = N'3' AND m.verify = N'user' AND ISNULL(m.approve, N'false') = N'false' AND ISNULL(m.reject, N'false') = N'true')
                 OR (@Prog = N'4' AND m.verify = N'section' AND ISNULL(m.approve, N'false') = N'false' AND ISNULL(m.reject, N'false') = N'true')
                  )
              AND (
                    @Q IS NULL
                 OR m.nrp LIKE N'%' + @Q + N'%'
                 OR ISNULL(wa.full_name, m.sickness_full_name) LIKE N'%' + @Q + N'%'
                 OR m.diagnosa LIKE N'%' + @Q + N'%'
                 OR m.name_doctor LIKE N'%' + @Q + N'%'
                  );
        END
        ELSE IF @ACTION_SP = N'GET'
        BEGIN
            SELECT
                s.id,
                s.by_jobsite,
                s.ref_id,
                s.key_id,
                s.nrp,
                ISNULL(NULLIF(LTRIM(RTRIM(wa.full_name)), N''), ISNULL(s.full_name, N'')) AS full_name,
                ISNULL(wa.jabatan, N'') AS jabatan,
                wa.department,
                ISNULL(wa.department_name, N'') AS department_name,
                wa.[section],
                ISNULL(wa.section_name, N'') AS section_name,
                s.date_issue,
                s.[date],
                s.start_date,
                s.end_date,
                s.category,
                s.name_doctor,
                s.name_agency,
                s.diagnosa,
                s.description,
                s.note,
                s.verify,
                s.approve,
                s.reject,
                s.path_evident,
                (
                    SELECT STRING_AGG(ph.fullpath, N'|') WITHIN GROUP (ORDER BY ph.id)
                    FROM hr.workers_sickness_photos ph
                    WHERE ph.deleted_at IS NULL
                      AND ph.by_jobsite = s.by_jobsite
                      AND ph.ref_id = s.id
                      AND ph.support_attach IS NULL
                ) AS evidence_paths,
                s.created_at,
                s.updated_at
            FROM hr.workers_sickness s
            LEFT JOIN hr.v_workers_active wa
                ON wa.nrp = s.nrp
               AND wa.by_jobsite = s.by_jobsite
            WHERE s.deleted_at IS NULL
              AND s.by_jobsite = @Jobsite
              AND s.id = @ID
              AND s.ref_id IS NULL;
        END
        ELSE IF @ACTION_SP = N'LOOKUP'
        BEGIN
            IF @NrpClean = N''
            BEGIN
                SELECT CAST(0 AS BIT) AS success, N'NRP is required.' AS message;
                RETURN;
            END

            DECLARE @LkScope NVARCHAR(MAX) = ISNULL(LTRIM(RTRIM(@SCOPE_SECTIONS)), N'');
            DECLARE @LkHasScope BIT = CASE WHEN @LkScope = N'' THEN 0 ELSE 1 END;
            DECLARE @LkScopeIds TABLE (id INT PRIMARY KEY);
            IF @LkHasScope = 1
            BEGIN
                INSERT INTO @LkScopeIds (id)
                SELECT DISTINCT TRY_CAST(LTRIM(RTRIM(value)) AS INT)
                FROM STRING_SPLIT(@LkScope, N',')
                WHERE TRY_CAST(LTRIM(RTRIM(value)) AS INT) IS NOT NULL;
            END

            IF NOT EXISTS (
                SELECT 1
                FROM hr.v_workers_active wa
                WHERE wa.by_jobsite = @Jobsite
                  AND wa.nrp = @NrpClean
                  AND (
                        @LkHasScope = 0
                     OR wa.[section] IN (SELECT id FROM @LkScopeIds)
                      )
            )
            BEGIN
                SELECT CAST(0 AS BIT) AS success, N'Worker not found for this NRP.' AS message;
                RETURN;
            END

            SELECT
                CAST(1 AS BIT) AS success,
                N'Worker found.' AS message,
                wa.nrp,
                wa.full_name,
                wa.jabatan,
                wa.department,
                wa.department_name,
                wa.[section],
                wa.section_name
            FROM hr.v_workers_active wa
            WHERE wa.by_jobsite = @Jobsite
              AND wa.nrp = @NrpClean
              AND (
                    @LkHasScope = 0
                 OR wa.[section] IN (SELECT id FROM @LkScopeIds)
                  );
        END
        ELSE IF @ACTION_SP = N'INSERT'
        BEGIN
            IF @NrpClean = N''
               OR @DATE_ISSUE IS NULL
               OR @Cat NOT IN (N'inpatient', N'outpatient', N'pasca')
               OR @NAME_DOCTOR IS NULL OR LTRIM(RTRIM(@NAME_DOCTOR)) = N''
               OR @NAME_AGENCY IS NULL OR LTRIM(RTRIM(@NAME_AGENCY)) = N''
               OR @DIAGNOSA IS NULL OR LTRIM(RTRIM(@DIAGNOSA)) = N''
               OR @START_DATE IS NULL
            BEGIN
                SELECT CAST(0 AS BIT) AS success,
                       N'nrp, date_issue, category, name_doctor, name_agency, diagnosa, and start_date are required.' AS message;
                RETURN;
            END

            IF NOT EXISTS (
                SELECT 1 FROM hr.v_workers_active
                WHERE by_jobsite = @Jobsite AND nrp = @NrpClean
            )
            BEGIN
                SELECT CAST(0 AS BIT) AS success, N'Worker not found for this NRP.' AS message;
                RETURN;
            END

            IF @WorkerName IS NULL
            BEGIN
                SELECT @WorkerName = wa.full_name
                FROM hr.v_workers_active wa
                WHERE wa.by_jobsite = @Jobsite AND wa.nrp = @NrpClean;
            END

            SET @EffStart = @START_DATE;
            SET @EffEnd = @END_DATE;

            IF @EffEnd IS NULL
            BEGIN
                -- Legacy: empty end → lampiran / rawat inap note in description
                IF @Desc IS NULL
                    SET @Desc = CASE
                        WHEN @Cat = N'inpatient' THEN N'RAWAT INAP (tanpa tanggal akhir)'
                        ELSE N'LAMPIRAN / tanpa tanggal akhir'
                    END;
            END
            ELSE IF @EffEnd < @EffStart
            BEGIN
                SELECT CAST(0 AS BIT) AS success, N'end_date cannot be before start_date.' AS message;
                RETURN;
            END

            -- Resolve actor legacy_id for by_user (list joins hr.users.legacy_id)
            SELECT
                @ActorLegacy = CAST(ISNULL(u.legacy_id, u.id) AS BIGINT),
                @LevelCode = LOWER(LTRIM(RTRIM(ISNULL(l.code, N''))))
            FROM hr.users u
            LEFT JOIN hr.levels l
                ON l.id = u.level_id
               AND l.by_jobsite = u.by_jobsite
               AND l.deleted_at IS NULL
            WHERE u.id = @BY_USER
              AND u.by_jobsite = @Jobsite
              AND u.deleted_at IS NULL;

            IF @LevelCode IN (N'superadmin', N'sa', N'hr_admin', N'hr_administrator')
                SET @BypassH3 = 1;

            -- H+3: reject when end_date is more than 4 days before today (non-bypass)
            IF @EffEnd IS NOT NULL AND @BypassH3 = 0
               AND DATEDIFF(DAY, @EffEnd, CAST(GETDATE() AS DATE)) > 4
            BEGIN
                SELECT CAST(0 AS BIT) AS success,
                       N'Pengajuan melewati batas H+3 (end_date terlalu lama).' AS message;
                RETURN;
            END

            -- Overlap on same NRP active parent ranges
            IF EXISTS (
                SELECT 1
                FROM hr.workers_sickness s
                WHERE s.deleted_at IS NULL
                  AND s.by_jobsite = @Jobsite
                  AND s.ref_id IS NULL
                  AND s.nrp = @NrpClean
                  AND s.start_date IS NOT NULL
                  AND @EffStart <= ISNULL(s.end_date, s.start_date)
                  AND ISNULL(@EffEnd, @EffStart) >= s.start_date
            )
            BEGIN
                SELECT CAST(0 AS BIT) AS success,
                       N'Tanggal sakit bentrok dengan pengajuan aktif untuk NRP ini.' AS message;
                RETURN;
            END

            INSERT INTO hr.workers_sickness (
                by_jobsite, ref_id, key_id, [date], nrp, nrp_int, full_name,
                diagnosa, name_doctor, name_agency, date_issue, category,
                start_date, end_date, description, note,
                verify, approve, reject, by_user,
                created_by, updated_at, updated_by
            )
            VALUES (
                @Jobsite,
                NULL,
                NULL,
                @DATE_ISSUE,
                @NrpClean,
                @NrpClean,
                @WorkerName,
                UPPER(LTRIM(RTRIM(@DIAGNOSA))),
                UPPER(LTRIM(RTRIM(@NAME_DOCTOR))),
                UPPER(LTRIM(RTRIM(@NAME_AGENCY))),
                @DATE_ISSUE,
                @Cat,
                @EffStart,
                @EffEnd,
                @Desc,
                NULL,
                N'user',
                N'false',
                N'false',
                @ActorLegacy,
                @BY_USER,
                SYSUTCDATETIME(),
                @BY_USER
            );

            SELECT CAST(1 AS BIT) AS success,
                   N'Sakit saved successfully.' AS message,
                   CAST(SCOPE_IDENTITY() AS INT) AS id;
        END
        ELSE IF @ACTION_SP = N'UPDATE'
        BEGIN
            SELECT @IDCHECK = s.id
            FROM hr.workers_sickness s
            WHERE s.deleted_at IS NULL
              AND s.id = @ID
              AND s.by_jobsite = @Jobsite
              AND s.ref_id IS NULL;

            IF @IDCHECK IS NULL
            BEGIN
                SELECT CAST(0 AS BIT) AS success, N'Sakit not found.' AS message;
                RETURN;
            END

            -- Only while pending (Waiting SH) — not yet approved by SH/HR
            IF NOT EXISTS (
                SELECT 1
                FROM hr.workers_sickness s
                WHERE s.id = @IDCHECK
                  AND s.verify = N'user'
                  AND ISNULL(s.approve, N'false') = N'false'
                  AND ISNULL(s.reject, N'false') = N'false'
            )
            BEGIN
                SELECT CAST(0 AS BIT) AS success,
                       N'Hanya pengajuan pending (Waiting Section Head) yang dapat diubah.' AS message;
                RETURN;
            END

            IF @PolCanEdit = 0
            BEGIN
                SELECT CAST(0 AS BIT) AS success,
                       N'Level ini tidak diizinkan mengubah pengajuan sakit (edit policy).' AS message;
                RETURN;
            END

            -- Window from hr.edit_policy module sakit (allow_past = unlimited)
            IF @PolAllowPast = 0
               AND EXISTS (
                SELECT 1
                FROM hr.workers_sickness s
                WHERE s.id = @IDCHECK
                  AND DATEDIFF(DAY, CAST(s.created_at AS DATE), CAST(GETDATE() AS DATE)) > ISNULL(@PolPastDays, 0)
            )
            BEGIN
                SELECT CAST(0 AS BIT) AS success,
                       N'Pengajuan melewati jendela edit policy sejak dibuat; tidak dapat diubah.' AS message;
                RETURN;
            END

            IF @NrpClean = N''
               OR @DATE_ISSUE IS NULL
               OR @Cat NOT IN (N'inpatient', N'outpatient', N'pasca')
               OR @NAME_DOCTOR IS NULL OR LTRIM(RTRIM(@NAME_DOCTOR)) = N''
               OR @NAME_AGENCY IS NULL OR LTRIM(RTRIM(@NAME_AGENCY)) = N''
               OR @DIAGNOSA IS NULL OR LTRIM(RTRIM(@DIAGNOSA)) = N''
               OR @START_DATE IS NULL
            BEGIN
                SELECT CAST(0 AS BIT) AS success,
                       N'nrp, date_issue, category, name_doctor, name_agency, diagnosa, and start_date are required.' AS message;
                RETURN;
            END

            IF @END_DATE IS NOT NULL AND @END_DATE < @START_DATE
            BEGIN
                SELECT CAST(0 AS BIT) AS success, N'end_date cannot be before start_date.' AS message;
                RETURN;
            END

            IF @WorkerName IS NULL
            BEGIN
                SELECT @WorkerName = wa.full_name
                FROM hr.v_workers_active wa
                WHERE wa.by_jobsite = @Jobsite AND wa.nrp = @NrpClean;
            END

            IF @END_DATE IS NULL AND @Desc IS NULL
                SET @Desc = CASE
                    WHEN @Cat = N'inpatient' THEN N'RAWAT INAP (tanpa tanggal akhir)'
                    ELSE N'LAMPIRAN / tanpa tanggal akhir'
                END;

            UPDATE hr.workers_sickness
            SET
                [date] = @DATE_ISSUE,
                nrp = @NrpClean,
                nrp_int = @NrpClean,
                full_name = ISNULL(@WorkerName, full_name),
                diagnosa = UPPER(LTRIM(RTRIM(@DIAGNOSA))),
                name_doctor = UPPER(LTRIM(RTRIM(@NAME_DOCTOR))),
                name_agency = UPPER(LTRIM(RTRIM(@NAME_AGENCY))),
                date_issue = @DATE_ISSUE,
                category = @Cat,
                start_date = @START_DATE,
                end_date = @END_DATE,
                description = @Desc,
                updated_at = SYSUTCDATETIME(),
                updated_by = @BY_USER
            WHERE id = @IDCHECK;

            SELECT CAST(1 AS BIT) AS success, N'Sakit updated successfully.' AS message, @IDCHECK AS id;
        END
        ELSE IF @ACTION_SP = N'CANCEL'
        BEGIN
            SELECT @IDCHECK = s.id
            FROM hr.workers_sickness s
            WHERE s.deleted_at IS NULL
              AND s.id = @ID
              AND s.by_jobsite = @Jobsite
              AND s.ref_id IS NULL;

            IF @IDCHECK IS NULL
            BEGIN
                SELECT CAST(0 AS BIT) AS success, N'Sakit not found.' AS message;
                RETURN;
            END

            IF NOT EXISTS (
                SELECT 1
                FROM hr.workers_sickness s
                WHERE s.id = @IDCHECK
                  AND s.verify = N'user'
                  AND ISNULL(s.approve, N'false') = N'false'
                  AND ISNULL(s.reject, N'false') = N'false'
            )
            BEGIN
                SELECT CAST(0 AS BIT) AS success,
                       N'Hanya pengajuan pending (Waiting Section Head) yang dapat dibatalkan.' AS message;
                RETURN;
            END

            IF @PolCanEdit = 0
            BEGIN
                SELECT CAST(0 AS BIT) AS success,
                       N'Level ini tidak diizinkan membatalkan pengajuan sakit (edit policy).' AS message;
                RETURN;
            END

            IF @PolAllowPast = 0
               AND EXISTS (
                SELECT 1
                FROM hr.workers_sickness s
                WHERE s.id = @IDCHECK
                  AND DATEDIFF(DAY, CAST(s.created_at AS DATE), CAST(GETDATE() AS DATE)) > ISNULL(@PolPastDays, 0)
            )
            BEGIN
                SELECT CAST(0 AS BIT) AS success,
                       N'Pengajuan melewati jendela edit policy sejak dibuat; tidak dapat dibatalkan.' AS message;
                RETURN;
            END

            UPDATE hr.workers_sickness
            SET
                note = N'CANCEL : INCORRECT DATA',
                deleted_at = SYSUTCDATETIME(),
                deleted_by = @BY_USER,
                updated_at = SYSUTCDATETIME(),
                updated_by = @BY_USER
            WHERE by_jobsite = @Jobsite
              AND deleted_at IS NULL
              AND (id = @IDCHECK OR ref_id = @IDCHECK);

            IF OBJECT_ID('hr.workers_sickness_photos', 'U') IS NOT NULL
            BEGIN
                UPDATE hr.workers_sickness_photos
                SET
                    deleted_at = SYSUTCDATETIME(),
                    deleted_by = @BY_USER,
                    updated_at = SYSUTCDATETIME(),
                    updated_by = @BY_USER
                WHERE by_jobsite = @Jobsite
                  AND deleted_at IS NULL
                  AND ref_id = @IDCHECK;
            END

            SELECT CAST(1 AS BIT) AS success, N'Sakit dibatalkan.' AS message, @IDCHECK AS id;
        END
        ELSE
        BEGIN
            SELECT CAST(0 AS BIT) AS success, N'Unknown ACTION_SP' AS message;
        END
    END TRY
    BEGIN CATCH
        SELECT CAST(0 AS BIT) AS success, ERROR_MESSAGE() AS message;
    END CATCH
END
GO
