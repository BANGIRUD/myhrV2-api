-- =============================================
-- hr.FINGER_ERROR_SP — Fingerprint queues (reconciliation, section, HR)
-- Cloned/simplified from hr.IJIN_SP (71). Category = hr.enums id (type workers_fingerprint).
-- Single-day attendance — no GL/dept queues, no dept exceptions, no active_submissions overlap.
-- Run AFTER 80_finger_error_table.sql
-- =============================================

CREATE OR ALTER PROCEDURE hr.FINGER_ERROR_SP
    @ACTION_SP NVARCHAR(30) = NULL,
    @ID INT = NULL,
    @MONTH NVARCHAR(7) = NULL,          -- YYYY-MM
    @DEPARTMENT NVARCHAR(250) = NULL,
    @SECTION NVARCHAR(250) = NULL,
    @JOB_RANK NVARCHAR(50) = NULL,
    @PROGRESS NVARCHAR(10) = NULL,      -- 0/'' ALL; 1 waiting SH; 2 waiting HR; 3 rejected SH; 4 rejected HR
    @STATUS_WORKER NVARCHAR(20) = NULL, -- sis | vendor (maps to v_workers_active.worker_source)
    @WORKER_SCOPE NVARCHAR(20) = NULL,  -- sis | ls | all (HR queue)
    @PAGE INT = 1,
    @PAGE_SIZE INT = 0,
    @SEARCH NVARCHAR(150) = NULL,
    @SCOPE_SECTIONS NVARCHAR(MAX) = NULL,
    @NRP NVARCHAR(40) = NULL,
    @CATEGORY NVARCHAR(150) = NULL,
    @DATE DATE = NULL,
    @FINGER_IN DATETIME2 = NULL,
    @FINGER_OUT DATETIME2 = NULL,
    @LOCATION NVARCHAR(200) = NULL,
    @SHIFT NVARCHAR(10) = NULL,
    @REMARK NVARCHAR(10) = NULL,
    @DESCRIPTION NVARCHAR(MAX) = NULL,
    @NOTE NVARCHAR(MAX) = NULL,
    @FULL_NAME NVARCHAR(200) = NULL,
    @LEVEL_CODE NVARCHAR(50) = NULL,
    @BY_USER INT = NULL,
    @BY_JOBSITE INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Jobsite INT = ISNULL(@BY_JOBSITE, 1);
    DECLARE @LevelKey NVARCHAR(50) = LOWER(LTRIM(RTRIM(ISNULL(@LEVEL_CODE, N''))));
    -- hr.edit_policy module finger_error: past_days = max age from created_at; allow_past = no day limit.
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
          AND LOWER(p.module_code) = N'finger_error'
          AND LOWER(p.level_code) = @LevelKey;
    END
    DECLARE @NrpClean NVARCHAR(40) = UPPER(LTRIM(RTRIM(ISNULL(@NRP, N''))));
    DECLARE @IDCHECK INT = NULL;
    DECLARE @ActorLegacy BIGINT = NULL;
    DECLARE @LevelCode NVARCHAR(50) = NULL;
    DECLARE @BypassH3 BIT = 0;
    DECLARE @CatId INT = TRY_CAST(NULLIF(LTRIM(RTRIM(ISNULL(@CATEGORY, N''))), N'') AS INT);
    DECLARE @Desc NVARCHAR(MAX) = NULLIF(LTRIM(RTRIM(@DESCRIPTION)), N'');
    DECLARE @WorkerName NVARCHAR(200) = NULLIF(LTRIM(RTRIM(@FULL_NAME)), N'');
    DECLARE @FingerIn DATETIME2 = @FINGER_IN;
    DECLARE @FingerOut DATETIME2 = @FINGER_OUT;
    DECLARE @Loc NVARCHAR(200) = NULLIF(LTRIM(RTRIM(@LOCATION)), N'');
    DECLARE @ShiftVal NVARCHAR(10) = NULLIF(LTRIM(RTRIM(@SHIFT)), N'');
    DECLARE @RemarkVal NVARCHAR(10) = NULLIF(LTRIM(RTRIM(@REMARK)), N'');

    DECLARE @IsSectionQueue BIT = 0;
    DECLARE @IsHrQueue BIT = 0;
    DECLARE @EligibleSections TABLE (id INT PRIMARY KEY);
    DECLARE @HighRanks TABLE (id INT PRIMARY KEY);

    BEGIN TRY
        IF @ACTION_SP IN (N'SELECT_SECTION', N'SELECT_HR')
        BEGIN
            DECLARE @ShRank INT = (
                SELECT TOP 1 id FROM hr.enums
                WHERE by_jobsite = @Jobsite AND deleted_at IS NULL
                  AND type = N'position' AND LOWER(name) = N'section head'
            );
            DECLARE @UhRank INT = (
                SELECT TOP 1 id FROM hr.enums
                WHERE by_jobsite = @Jobsite AND deleted_at IS NULL
                  AND type = N'position' AND LOWER(name) = N'unit head'
            );
            DECLARE @CallerRank INT = NULL;

            SELECT TOP 1 @CallerRank = wa.job_rank
            FROM hr.users u
            INNER JOIN hr.v_workers_active wa
                ON wa.by_jobsite = u.by_jobsite
               AND wa.nrp = u.username
            WHERE u.id = @BY_USER
              AND u.by_jobsite = @Jobsite
              AND u.deleted_at IS NULL;

            INSERT INTO @HighRanks (id)
            SELECT e.id
            FROM hr.enums e
            WHERE e.by_jobsite = @Jobsite
              AND e.deleted_at IS NULL
              AND e.type = N'position'
              AND (
                    LOWER(e.name) IN (
                        N'section head', N'department head', N'division head',
                        N'chief operation', N'personalia'
                    )
                 OR (@ShRank IS NOT NULL AND e.id <= @ShRank AND e.id > 0)
                  );

            DECLARE @SecScope NVARCHAR(MAX) = ISNULL(LTRIM(RTRIM(@SCOPE_SECTIONS)), N'');
            IF @SecScope <> N''
            BEGIN
                INSERT INTO @EligibleSections (id)
                SELECT DISTINCT TRY_CAST(LTRIM(RTRIM(value)) AS INT)
                FROM STRING_SPLIT(@SecScope, N',')
                WHERE TRY_CAST(LTRIM(RTRIM(value)) AS INT) IS NOT NULL
                  AND TRY_CAST(LTRIM(RTRIM(value)) AS INT) > 0;
            END
            ELSE
            BEGIN
                INSERT INTO @EligibleSections (id)
                SELECT DISTINCT wa.[section]
                FROM hr.v_workers_active wa
                WHERE wa.by_jobsite = @Jobsite
                  AND wa.[section] IS NOT NULL
                  AND wa.[section] > 0;
            END

            IF @ACTION_SP = N'SELECT_HR'
            BEGIN
                SET @IsHrQueue = 1;
                IF @LevelKey NOT IN (N'hr_admin', N'hr_administrator', N'superadmin', N'sa')
                BEGIN
                    DELETE FROM @EligibleSections;
                END
            END
            ELSE IF @CallerRank = @UhRank AND @UhRank IS NOT NULL
            BEGIN
                DELETE es
                FROM @EligibleSections es
                WHERE EXISTS (
                    SELECT 1
                    FROM hr.v_workers_active w
                    WHERE w.by_jobsite = @Jobsite
                      AND w.[section] = es.id
                      AND w.job_rank = @ShRank
                );
            END
            ELSE IF @SecScope <> N'' AND (@CallerRank IS NULL OR @CallerRank <> @ShRank)
            BEGIN
                DELETE FROM @EligibleSections;
            END

            SET @IsSectionQueue = 1;
        END

        IF @ACTION_SP = N'SELECT' OR @IsSectionQueue = 1
        BEGIN
            DECLARE @Dept NVARCHAR(250) = ISNULL(LTRIM(RTRIM(@DEPARTMENT)), N'');
            DECLARE @Sect NVARCHAR(250) = ISNULL(LTRIM(RTRIM(@SECTION)), N'');
            DECLARE @JobRank INT = TRY_CAST(NULLIF(LTRIM(RTRIM(@JOB_RANK)), N'') AS INT);
            DECLARE @Prog NVARCHAR(10) = ISNULL(LTRIM(RTRIM(@PROGRESS)), N'');
            DECLARE @StatWorker NVARCHAR(20) = LOWER(ISNULL(LTRIM(RTRIM(@STATUS_WORKER)), N''));
            DECLARE @HrScope NVARCHAR(20) = LOWER(LTRIM(RTRIM(ISNULL(@WORKER_SCOPE, N''))));
            IF @HrScope NOT IN (N'sis', N'ls', N'all') SET @HrScope = N'none';
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

            -- Month filter on parent [date] (single-day attendance).
            IF OBJECT_ID(N'tempdb..#finger_error_ids') IS NOT NULL DROP TABLE #finger_error_ids;
            SELECT s.id
            INTO #finger_error_ids
            FROM hr.workers_finger_error s
            WHERE s.deleted_at IS NULL
              AND s.by_jobsite = @Jobsite
              AND s.ref_id IS NULL
              AND s.[date] >= @FromDate
              AND s.[date] < @ToDate;
            CREATE CLUSTERED INDEX IX_finger_error_ids ON #finger_error_ids (id);

            ;WITH candidates AS (
                SELECT s.*
                FROM #finger_error_ids i
                INNER JOIN hr.workers_finger_error s ON s.id = i.id
            ),
            latest_child AS (
                SELECT
                    c.ref_id,
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
                    FROM hr.workers_finger_error s
                    INNER JOIN candidates p ON p.id = s.ref_id
                    WHERE s.deleted_at IS NULL
                      AND s.by_jobsite = @Jobsite
                      AND s.ref_id IS NOT NULL
                ) x
                INNER JOIN hr.workers_finger_error c ON c.id = x.id
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
                FROM hr.workers_finger_error s
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
                    p.full_name AS finger_full_name,
                    p.location,
                    p.finger_in,
                    p.finger_out,
                    p.shift,
                    p.remark,
                    p.category,
                    p.path_evident,
                    CASE
                        WHEN c.ref_id IS NULL THEN p.description
                        WHEN c.description IS NULL THEN p.description
                        ELSE c.description
                    END AS description,
                    ISNULL(c.note, p.note) AS note,
                    ISNULL(c.verify, p.verify) AS verify,
                    ISNULL(c.approve, p.approve) AS approve,
                    ISNULL(c.reject, p.reject) AS reject,
                    p.approve AS parent_approve,
                    p.by_verified,
                    p.by_user,
                    p.created_by,
                    p.updated_by,
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
                SELECT m.*
                FROM merged m
                WHERE m.[date] >= @FromDate
                  AND m.[date] < @ToDate
            ),
            base AS (
                SELECT
                    m.id,
                    m.by_jobsite,
                    m.key_id,
                    CAST(m.created_at AS DATE) AS input_date,
                    m.nrp,
                    ISNULL(NULLIF(LTRIM(RTRIM(wa.full_name)), N''), ISNULL(m.finger_full_name, N'')) AS full_name,
                    ISNULL(wa.jabatan, N'') AS jabatan,
                    wa.job_rank,
                    wa.department,
                    ISNULL(wa.department_name, N'') AS department_name,
                    wa.[section],
                    ISNULL(wa.section_name, N'') AS section_name,
                    wa.worker_source AS status_worker,
                    m.category,
                    ISNULL(ecat.name, N'') AS category_name,
                    m.[date],
                    m.location,
                    m.finger_in,
                    m.finger_out,
                    m.shift,
                    m.remark,
                    m.path_evident,
                    (
                        SELECT STRING_AGG(ph.fullpath, N'|') WITHIN GROUP (ORDER BY ph.id)
                        FROM hr.workers_finger_error_photos ph
                        WHERE ph.deleted_at IS NULL
                          AND ph.by_jobsite = m.by_jobsite
                          AND ph.ref_id = m.id
                         
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
                    -- Ubah / Batalkan: pending + hr.edit_policy (module finger_error) for this level
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
                    ISNULL(NULLIF(LTRIM(RTRIM(u_creator.full_name)), N''), ISNULL(u_in.full_name, N'')) AS name_input,
                    -- Atasan stays visible after HR rejects. The name is the parent
                    -- verifier; the section child by_user is later overwritten by HR.
                    CASE
                        WHEN ISNULL(m.parent_approve, N'false') = N'true'
                            THEN m.by_date_verified_section
                        ELSE NULL
                    END AS by_date_verified_section,
                    CASE
                        WHEN ISNULL(m.parent_approve, N'false') = N'true'
                            THEN ISNULL(u_atasan.full_name, N'')
                        ELSE N''
                    END AS by_checked_name,
                    CASE
                        WHEN ISNULL(m.parent_approve, N'false') <> N'true' THEN N''
                        WHEN LOWER(e_atasan.name) = N'section head' THEN N'SH'
                        WHEN LOWER(e_atasan.name) = N'group leader' THEN N'GL'
                        WHEN LOWER(e_atasan.name) = N'unit head' THEN N'UH'
                        WHEN LOWER(e_atasan.name) = N'department head' THEN N'DH'
                        WHEN LOWER(e_atasan.name) = N'division head' THEN N'Div'
                        WHEN LOWER(e_atasan.name) IN (N'chief operation', N'personalia') THEN N'CO'
                        WHEN NULLIF(LTRIM(RTRIM(e_atasan.name)), N'') IS NULL THEN N''
                        ELSE e_atasan.name
                    END AS by_checked_role,
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
                        WHEN ISNULL(m.reject, N'false') = N'true'
                         AND m.verify = N'section'
                            THEN m.updated_verified_section
                        WHEN ISNULL(m.reject, N'false') = N'true'
                            THEN m.updated_at
                        ELSE NULL
                    END AS reject_date,
                    CASE
                        WHEN ISNULL(m.reject, N'false') = N'true'
                         AND m.verify = N'section'
                            THEN ISNULL(u_sh.full_name, N'')
                        WHEN ISNULL(m.reject, N'false') = N'true'
                            THEN ISNULL(u_rej.full_name, N'')
                        ELSE N''
                    END AS reject_by,
                    m.created_at,
                    m.updated_at
                FROM parents m
                LEFT JOIN hr.v_workers_active wa
                    ON wa.nrp = m.nrp
                   AND wa.by_jobsite = m.by_jobsite
                LEFT JOIN hr.enums ecat
                    ON ecat.id = m.category
                   AND ecat.by_jobsite = m.by_jobsite
                   AND ecat.deleted_at IS NULL
                   AND ecat.type = N'workers_fingerprint'
                -- by_user stores OLD dbo.users.id → join hr.users.legacy_id
                LEFT JOIN hr.users u_in
                    ON u_in.legacy_id = TRY_CAST(m.by_user AS INT)
                   AND u_in.by_jobsite = m.by_jobsite
                   AND u_in.deleted_at IS NULL
                LEFT JOIN hr.users u_creator
                    ON u_creator.id = m.created_by
                   AND u_creator.deleted_at IS NULL
                LEFT JOIN hr.users u_rej
                    ON u_rej.id = m.updated_by
                   AND u_rej.deleted_at IS NULL
                LEFT JOIN hr.users u_atasan
                    ON u_atasan.legacy_id = TRY_CAST(m.by_verified AS INT)
                   AND u_atasan.by_jobsite = m.by_jobsite
                   AND u_atasan.deleted_at IS NULL
                LEFT JOIN hr.v_workers_active wa_atasan
                    ON wa_atasan.by_jobsite = u_atasan.by_jobsite
                   AND wa_atasan.nrp = u_atasan.username
                LEFT JOIN hr.enums e_atasan
                    ON e_atasan.id = wa_atasan.job_rank
                   AND e_atasan.by_jobsite = wa_atasan.by_jobsite
                   AND e_atasan.deleted_at IS NULL
                   AND e_atasan.type = N'position'
                LEFT JOIN hr.users u_sh
                    ON u_sh.legacy_id = TRY_CAST(m.by_verified_section AS INT)
                   AND u_sh.by_jobsite = m.by_jobsite
                   AND u_sh.deleted_at IS NULL
                LEFT JOIN hr.v_workers_active wa_sh
                    ON wa_sh.by_jobsite = u_sh.by_jobsite
                   AND wa_sh.nrp = u_sh.username
                LEFT JOIN hr.enums e_sh
                    ON e_sh.id = wa_sh.job_rank
                   AND e_sh.by_jobsite = wa_sh.by_jobsite
                   AND e_sh.deleted_at IS NULL
                   AND e_sh.type = N'position'
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
                        @IsSectionQueue = 0
                     OR (
                            @IsHrQueue = 1
                        AND wa.[section] IN (SELECT id FROM @EligibleSections)
                        AND (
                                @HrScope = N'all'
                             OR (@HrScope = N'ls' AND wa.worker_source = N'vendor')
                             OR (@HrScope = N'sis' AND ISNULL(wa.worker_source, N'') <> N'vendor')
                            )
                        )
                     OR (
                            @IsHrQueue = 0
                        AND wa.[section] IN (SELECT id FROM @EligibleSections)
                        AND wa.job_rank IS NOT NULL
                        AND wa.job_rank NOT IN (SELECT id FROM @HighRanks)
                        )
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
                     OR ISNULL(wa.full_name, m.finger_full_name) LIKE N'%' + @Q + N'%'
                     OR m.description LIKE N'%' + @Q + N'%'
                      )
            )
            SELECT *
            FROM base
            ORDER BY
                CASE
                    WHEN @IsHrQueue = 1
                     AND verify = N'section'
                     AND ISNULL(approve, N'false') = N'false'
                     AND ISNULL(reject, N'false') = N'false' THEN 0
                    WHEN @IsHrQueue = 1 THEN 1
                    WHEN @IsSectionQueue = 1
                     AND verify = N'user'
                     AND ISNULL(approve, N'false') = N'false'
                     AND ISNULL(reject, N'false') = N'false'
                     AND ISNULL(job_rank, 0) <> 13 THEN 0
                    WHEN @IsSectionQueue = 1
                     AND verify = N'user'
                     AND ISNULL(approve, N'false') = N'false'
                     AND ISNULL(reject, N'false') = N'false'
                     AND job_rank = 13 THEN 1
                    WHEN @IsSectionQueue = 1 THEN 2
                    WHEN verify = N'user'
                     AND ISNULL(approve, N'false') = N'false'
                     AND ISNULL(reject, N'false') = N'false'
                     AND ISNULL(job_rank, 0) <> 13 THEN 0
                    WHEN verify = N'user'
                     AND ISNULL(approve, N'false') = N'false'
                     AND ISNULL(reject, N'false') = N'false'
                     AND job_rank = 13 THEN 1
                    WHEN verify = N'section'
                     AND ISNULL(approve, N'false') = N'false'
                     AND ISNULL(reject, N'false') = N'false' THEN 2
                    WHEN ISNULL(reject, N'false') = N'true' THEN 3
                    ELSE 4
                END,
                created_at ASC,
                id ASC
            OFFSET CASE WHEN @PAGE_SIZE > 0 THEN (@PAGE - 1) * @PAGE_SIZE ELSE 0 END ROWS
            FETCH NEXT CASE WHEN @PAGE_SIZE > 0 THEN @PAGE_SIZE ELSE 100000 END ROWS ONLY;

            ;WITH candidates AS (
                SELECT s.*
                FROM #finger_error_ids i
                INNER JOIN hr.workers_finger_error s ON s.id = i.id
            ),
            latest_child AS (
                SELECT
                    c.ref_id,
                    c.verify,
                    c.approve,
                    c.reject
                FROM (
                    SELECT
                        s.id,
                        s.ref_id,
                        ROW_NUMBER() OVER (PARTITION BY s.ref_id ORDER BY s.id DESC) AS rn
                    FROM hr.workers_finger_error s
                    INNER JOIN candidates p ON p.id = s.ref_id
                    WHERE s.deleted_at IS NULL
                      AND s.by_jobsite = @Jobsite
                      AND s.ref_id IS NOT NULL
                ) x
                INNER JOIN hr.workers_finger_error c ON c.id = x.id
                WHERE x.rn = 1
            ),
            merged AS (
                SELECT
                    p.id,
                    p.nrp,
                    p.full_name AS finger_full_name,
                    p.description,
                    p.[date],
                    ISNULL(c.verify, p.verify) AS verify,
                    ISNULL(c.approve, p.approve) AS approve,
                    ISNULL(c.reject, p.reject) AS reject
                FROM candidates p
                LEFT JOIN latest_child c ON c.ref_id = p.id
            ),
            parents AS (
                SELECT m.*
                FROM merged m
                WHERE m.[date] >= @FromDate
                  AND m.[date] < @ToDate
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
                    @IsSectionQueue = 0
                 OR (
                        @IsHrQueue = 1
                    AND wa.[section] IN (SELECT id FROM @EligibleSections)
                    AND (
                            @HrScope = N'all'
                         OR (@HrScope = N'ls' AND wa.worker_source = N'vendor')
                         OR (@HrScope = N'sis' AND ISNULL(wa.worker_source, N'') <> N'vendor')
                        )
                    )
                 OR (
                        @IsHrQueue = 0
                    AND wa.[section] IN (SELECT id FROM @EligibleSections)
                    AND wa.job_rank IS NOT NULL
                    AND wa.job_rank NOT IN (SELECT id FROM @HighRanks)
                    )
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
                 OR ISNULL(wa.full_name, m.finger_full_name) LIKE N'%' + @Q + N'%'
                 OR m.description LIKE N'%' + @Q + N'%'
                  );

            -- Status badges: same scope/month/filters, ignores status-pengajuan filter.
            ;WITH candidates AS (
                SELECT s.*
                FROM #finger_error_ids i
                INNER JOIN hr.workers_finger_error s ON s.id = i.id
            ),
            latest_child AS (
                SELECT
                    c.ref_id,
                    c.verify,
                    c.approve,
                    c.reject
                FROM (
                    SELECT
                        s.id,
                        s.ref_id,
                        ROW_NUMBER() OVER (PARTITION BY s.ref_id ORDER BY s.id DESC) AS rn
                    FROM hr.workers_finger_error s
                    INNER JOIN candidates p ON p.id = s.ref_id
                    WHERE s.deleted_at IS NULL
                      AND s.by_jobsite = @Jobsite
                      AND s.ref_id IS NOT NULL
                ) x
                INNER JOIN hr.workers_finger_error c ON c.id = x.id
                WHERE x.rn = 1
            ),
            merged AS (
                SELECT
                    p.id,
                    p.nrp,
                    p.full_name AS finger_full_name,
                    p.description,
                    p.category,
                    p.[date],
                    ISNULL(c.verify, p.verify) AS verify,
                    ISNULL(c.approve, p.approve) AS approve,
                    ISNULL(c.reject, p.reject) AS reject
                FROM candidates p
                LEFT JOIN latest_child c ON c.ref_id = p.id
            ),
            parents AS (
                SELECT m.*
                FROM merged m
                WHERE m.[date] >= @FromDate
                  AND m.[date] < @ToDate
            ),
            labeled AS (
                SELECT
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
                    m.nrp,
                    ISNULL(NULLIF(LTRIM(RTRIM(wa.full_name)), N''), ISNULL(m.finger_full_name, N'')) AS full_name,
                    ISNULL(wa.section_name, N'') AS section_name,
                    CONVERT(NVARCHAR(10), m.[date], 23) AS [date],
                    ISNULL((
                        SELECT TOP 1 e.name
                        FROM hr.enums e
                        WHERE e.id = m.category
                          AND e.by_jobsite = @Jobsite
                          AND e.deleted_at IS NULL
                          AND e.type = N'workers_fingerprint'
                    ), N'') AS category_name
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
                        @IsSectionQueue = 0
                     OR (
                            @IsHrQueue = 1
                        AND wa.[section] IN (SELECT id FROM @EligibleSections)
                        AND (
                                @HrScope = N'all'
                             OR (@HrScope = N'ls' AND wa.worker_source = N'vendor')
                             OR (@HrScope = N'sis' AND ISNULL(wa.worker_source, N'') <> N'vendor')
                            )
                        )
                     OR (
                            @IsHrQueue = 0
                        AND wa.[section] IN (SELECT id FROM @EligibleSections)
                        AND wa.job_rank IS NOT NULL
                        AND wa.job_rank NOT IN (SELECT id FROM @HighRanks)
                        )
                      )
                  AND (
                        @Q IS NULL
                     OR m.nrp LIKE N'%' + @Q + N'%'
                     OR ISNULL(wa.full_name, m.finger_full_name) LIKE N'%' + @Q + N'%'
                     OR m.description LIKE N'%' + @Q + N'%'
                      )
            )
            SELECT
                progress,
                COUNT(*) AS total,
                STRING_AGG(
                    CAST(
                        ISNULL(nrp, N'') + N'|' + ISNULL(full_name, N'') + N'|' + ISNULL(section_name, N'')
                        + N'|' + ISNULL([date], N'') + N'|' + ISNULL(category_name, N'')
                        AS NVARCHAR(MAX)
                    ),
                    N';;'
                ) WITHIN GROUP (ORDER BY full_name, nrp) AS people
            FROM labeled
            GROUP BY progress
            ORDER BY
                CASE
                    WHEN progress LIKE N'Waiting%' THEN 0
                    WHEN progress LIKE N'Approve%' THEN 1
                    WHEN progress LIKE N'Rejected%' THEN 2
                    ELSE 3
                END,
                progress;
            DROP TABLE #finger_error_ids;
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
                s.[date],
                s.location,
                s.finger_in,
                s.finger_out,
                s.shift,
                s.remark,
                s.category,
                ISNULL(ecat.name, N'') AS category_name,
                s.description,
                s.note,
                s.verify,
                s.approve,
                s.reject,
                s.path_evident,
                (
                    SELECT STRING_AGG(ph.fullpath, N'|') WITHIN GROUP (ORDER BY ph.id)
                    FROM hr.workers_finger_error_photos ph
                    WHERE ph.deleted_at IS NULL
                      AND ph.by_jobsite = s.by_jobsite
                      AND ph.ref_id = s.id
                     
                ) AS evidence_paths,
                s.created_at,
                s.updated_at
            FROM hr.workers_finger_error s
            LEFT JOIN hr.v_workers_active wa
                ON wa.nrp = s.nrp
               AND wa.by_jobsite = s.by_jobsite
            LEFT JOIN hr.enums ecat
                ON ecat.id = s.category
               AND ecat.by_jobsite = s.by_jobsite
               AND ecat.deleted_at IS NULL
               AND ecat.type = N'workers_fingerprint'
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
               OR @CatId IS NULL
               OR @DATE IS NULL
            BEGIN
                SELECT CAST(0 AS BIT) AS success,
                       N'nrp, category, and date are required.' AS message;
                RETURN;
            END

            IF @FingerIn IS NULL AND @FingerOut IS NULL
            BEGIN
                SELECT CAST(0 AS BIT) AS success,
                       N'At least one of finger_in or finger_out is required.' AS message;
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

            INSERT INTO hr.workers_finger_error (
                by_jobsite, ref_id, key_id, [date], nrp, nrp_int, full_name,
                location, finger_in, finger_out, category, shift, remark,
                path_evident, description, note,
                verify, approve, reject, by_user,
                created_by, updated_at, updated_by
            )
            VALUES (
                @Jobsite,
                NULL,
                UPPER(CONVERT(VARCHAR(40), HASHBYTES(
                    'SHA1',
                    CONCAT(@NrpClean, N'_', CONVERT(VARCHAR(19), GETDATE(), 120))
                ), 2)),
                @DATE,
                @NrpClean,
                @NrpClean,
                @WorkerName,
                @Loc,
                @FingerIn,
                @FingerOut,
                @CatId,
                @ShiftVal,
                @RemarkVal,
                NULL,
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
                   N'Fingerprint saved successfully.' AS message,
                   CAST(SCOPE_IDENTITY() AS INT) AS id;
        END
        ELSE IF @ACTION_SP = N'UPDATE'
        BEGIN
            SELECT @IDCHECK = s.id
            FROM hr.workers_finger_error s
            WHERE s.deleted_at IS NULL
              AND s.id = @ID
              AND s.by_jobsite = @Jobsite
              AND s.ref_id IS NULL;

            IF @IDCHECK IS NULL
            BEGIN
                SELECT CAST(0 AS BIT) AS success, N'Fingerprint not found.' AS message;
                RETURN;
            END

            IF NOT EXISTS (
                SELECT 1
                FROM hr.workers_finger_error s
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
                       N'Level ini tidak diizinkan mengubah pengajuan fingerprint (edit policy).' AS message;
                RETURN;
            END

            IF @PolAllowPast = 0
               AND EXISTS (
                SELECT 1
                FROM hr.workers_finger_error s
                WHERE s.id = @IDCHECK
                  AND DATEDIFF(DAY, CAST(s.created_at AS DATE), CAST(GETDATE() AS DATE)) > ISNULL(@PolPastDays, 0)
            )
            BEGIN
                SELECT CAST(0 AS BIT) AS success,
                       N'Pengajuan melewati jendela edit policy sejak dibuat; tidak dapat diubah.' AS message;
                RETURN;
            END

            IF @NrpClean = N''
               OR @CatId IS NULL
               OR @DATE IS NULL
            BEGIN
                SELECT CAST(0 AS BIT) AS success,
                       N'nrp, category, and date are required.' AS message;
                RETURN;
            END

            IF @FingerIn IS NULL AND @FingerOut IS NULL
            BEGIN
                SELECT CAST(0 AS BIT) AS success,
                       N'At least one of finger_in or finger_out is required.' AS message;
                RETURN;
            END

            IF @WorkerName IS NULL
            BEGIN
                SELECT @WorkerName = wa.full_name
                FROM hr.v_workers_active wa
                WHERE wa.by_jobsite = @Jobsite AND wa.nrp = @NrpClean;
            END

            UPDATE hr.workers_finger_error
            SET
                [date] = @DATE,
                nrp = @NrpClean,
                nrp_int = @NrpClean,
                full_name = ISNULL(@WorkerName, full_name),
                location = COALESCE(@Loc, location),
                finger_in = @FingerIn,
                finger_out = @FingerOut,
                category = @CatId,
                shift = COALESCE(@ShiftVal, shift),
                remark = COALESCE(@RemarkVal, remark),
                description = COALESCE(@Desc, description),
                updated_at = SYSUTCDATETIME(),
                updated_by = @BY_USER
            WHERE id = @IDCHECK;

            SELECT CAST(1 AS BIT) AS success, N'Fingerprint updated successfully.' AS message, @IDCHECK AS id;
        END
        ELSE IF @ACTION_SP = N'CANCEL'
        BEGIN
            SELECT @IDCHECK = s.id
            FROM hr.workers_finger_error s
            WHERE s.deleted_at IS NULL
              AND s.id = @ID
              AND s.by_jobsite = @Jobsite
              AND s.ref_id IS NULL;

            IF @IDCHECK IS NULL
            BEGIN
                SELECT CAST(0 AS BIT) AS success, N'Fingerprint not found.' AS message;
                RETURN;
            END

            IF NOT EXISTS (
                SELECT 1
                FROM hr.workers_finger_error s
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
                       N'Level ini tidak diizinkan membatalkan pengajuan fingerprint (edit policy).' AS message;
                RETURN;
            END

            IF @PolAllowPast = 0
               AND EXISTS (
                SELECT 1
                FROM hr.workers_finger_error s
                WHERE s.id = @IDCHECK
                  AND DATEDIFF(DAY, CAST(s.created_at AS DATE), CAST(GETDATE() AS DATE)) > ISNULL(@PolPastDays, 0)
            )
            BEGIN
                SELECT CAST(0 AS BIT) AS success,
                       N'Pengajuan melewati jendela edit policy sejak dibuat; tidak dapat dibatalkan.' AS message;
                RETURN;
            END

            UPDATE hr.workers_finger_error
            SET
                note = N'CANCEL : INCORRECT DATA',
                deleted_at = SYSUTCDATETIME(),
                deleted_by = @BY_USER,
                updated_at = SYSUTCDATETIME(),
                updated_by = @BY_USER
            WHERE by_jobsite = @Jobsite
              AND deleted_at IS NULL
              AND (id = @IDCHECK OR ref_id = @IDCHECK);

            IF OBJECT_ID('hr.workers_finger_error_photos', 'U') IS NOT NULL
            BEGIN
                UPDATE hr.workers_finger_error_photos
                SET
                    deleted_at = SYSUTCDATETIME(),
                    deleted_by = @BY_USER,
                    updated_at = SYSUTCDATETIME(),
                    updated_by = @BY_USER
                WHERE by_jobsite = @Jobsite
                  AND deleted_at IS NULL
                  AND ref_id = @IDCHECK;
            END

            SELECT CAST(1 AS BIT) AS success, N'Fingerprint dibatalkan.' AS message, @IDCHECK AS id;
        END
        ELSE IF @ACTION_SP IN (N'APPROVE_SECTION', N'REJECT_SECTION', N'APPROVE_HR', N'REJECT_HR')
        BEGIN
            DECLARE @WantReject BIT = CASE WHEN @ACTION_SP = N'REJECT_SECTION' THEN 1 ELSE 0 END;
            DECLARE @SecSh INT = (
                SELECT TOP 1 id FROM hr.enums
                WHERE by_jobsite = @Jobsite AND deleted_at IS NULL
                  AND type = N'position' AND LOWER(name) = N'section head'
            );
            DECLARE @SecUh INT = (
                SELECT TOP 1 id FROM hr.enums
                WHERE by_jobsite = @Jobsite AND deleted_at IS NULL
                  AND type = N'position' AND LOWER(name) = N'unit head'
            );
            DECLARE @ActorRank INT = NULL;
            DECLARE @RowSection INT = NULL;
            DECLARE @RowRank INT = NULL;
            DECLARE @RowSource NVARCHAR(20) = NULL;

            SELECT TOP 1 @ActorRank = wa.job_rank
            FROM hr.users u
            INNER JOIN hr.v_workers_active wa
                ON wa.by_jobsite = u.by_jobsite AND wa.nrp = u.username
            WHERE u.id = @BY_USER AND u.deleted_at IS NULL AND u.by_jobsite = @Jobsite;

            SELECT
                @IDCHECK = s.id,
                @RowSection = wa.[section],
                @RowRank = wa.job_rank,
                @RowSource = wa.worker_source
            FROM hr.workers_finger_error s
            LEFT JOIN hr.v_workers_active wa
                ON wa.nrp = s.nrp AND wa.by_jobsite = s.by_jobsite
            WHERE s.deleted_at IS NULL
              AND s.id = @ID
              AND s.by_jobsite = @Jobsite
              AND s.ref_id IS NULL;

            IF @IDCHECK IS NULL
            BEGIN
                SELECT CAST(0 AS BIT) AS success, N'Fingerprint not found.' AS message;
                RETURN;
            END

            IF @ACTION_SP IN (N'APPROVE_HR', N'REJECT_HR')
            BEGIN
                DECLARE @HrActScope NVARCHAR(20) = LOWER(LTRIM(RTRIM(ISNULL(@WORKER_SCOPE, N''))));
                IF @LevelKey IN (N'superadmin', N'sa') SET @HrActScope = N'all';

                IF @LevelKey NOT IN (N'hr_admin', N'hr_administrator', N'superadmin', N'sa')
                   OR @HrActScope NOT IN (N'sis', N'ls', N'all')
                BEGIN
                    SELECT CAST(0 AS BIT) AS success, N'Hanya Personalia HR yang dapat memproses.' AS message;
                    RETURN;
                END

                IF (@HrActScope = N'ls' AND ISNULL(@RowSource, N'') <> N'vendor')
                   OR (@HrActScope = N'sis' AND ISNULL(@RowSource, N'') = N'vendor')
                BEGIN
                    SELECT CAST(0 AS BIT) AS success, N'Pengajuan di luar kelompok SIS/LS Anda.' AS message;
                    RETURN;
                END

                IF NOT EXISTS (
                    SELECT 1
                    FROM (
                        SELECT TOP (1) c.verify, c.approve, c.reject
                        FROM hr.workers_finger_error c
                        WHERE c.ref_id = @IDCHECK
                          AND c.by_jobsite = @Jobsite
                          AND c.deleted_at IS NULL
                        ORDER BY c.id DESC
                    ) latest
                    WHERE latest.verify = N'section'
                      AND ISNULL(latest.approve, N'false') = N'false'
                      AND ISNULL(latest.reject, N'false') = N'false'
                )
                BEGIN
                    SELECT CAST(0 AS BIT) AS success,
                           N'Hanya pengajuan Waiting approve by HR yang dapat diproses.' AS message;
                    RETURN;
                END

                SELECT @ActorLegacy = CAST(ISNULL(u.legacy_id, u.id) AS BIGINT)
                FROM hr.users u
                WHERE u.id = @BY_USER AND u.deleted_at IS NULL;

                IF @ACTION_SP = N'APPROVE_HR'
                BEGIN
                    INSERT INTO hr.workers_finger_error (
                        by_jobsite, ref_id, key_id, [date], nrp, nrp_int, full_name,
                        location, finger_in, finger_out, category, shift, remark,
                        path_evident, description, note,
                        verify, approve, reject, by_user,
                        created_by, updated_at, updated_by
                    )
                    SELECT
                        s.by_jobsite, s.id,
                        UPPER(CONVERT(VARCHAR(40), HASHBYTES(
                            'SHA1',
                            CONCAT(CAST(s.id AS NVARCHAR(20)), N'_', CONVERT(VARCHAR(19), GETDATE(), 120))
                        ), 2)),
                        s.[date], s.nrp, s.nrp_int, s.full_name,
                        s.location, s.finger_in, s.finger_out, s.category, s.shift, s.remark,
                        s.path_evident, s.description, s.note,
                        N'administrator', N'false', N'false',
                        @ActorLegacy,
                        @BY_USER, SYSUTCDATETIME(), @BY_USER
                    FROM hr.workers_finger_error s
                    WHERE s.id = @IDCHECK;

                    UPDATE hr.workers_finger_error
                    SET approve = N'true',
                        reject = N'false',
                        by_verified = @ActorLegacy,
                        updated_at = SYSUTCDATETIME(),
                        updated_by = @BY_USER
                    WHERE ref_id = @IDCHECK
                      AND by_jobsite = @Jobsite
                      AND deleted_at IS NULL
                      AND verify = N'section';

                    SELECT CAST(1 AS BIT) AS success, N'Pengajuan disetujui HR.' AS message, @IDCHECK AS id;
                    RETURN;
                END

                UPDATE hr.workers_finger_error
                SET approve = N'false',
                    reject = N'true',
                    note = ISNULL(NULLIF(LTRIM(RTRIM(@NOTE)), N''), note),
                    by_user = @ActorLegacy,
                    updated_at = SYSUTCDATETIME(),
                    updated_by = @BY_USER
                WHERE ref_id = @IDCHECK
                  AND by_jobsite = @Jobsite
                  AND deleted_at IS NULL
                  AND verify = N'section';

                UPDATE hr.workers_finger_error
                SET note = ISNULL(NULLIF(LTRIM(RTRIM(@NOTE)), N''), note),
                    updated_at = SYSUTCDATETIME(),
                    updated_by = @BY_USER
                WHERE id = @IDCHECK
                  AND verify = N'user';

                SELECT CAST(1 AS BIT) AS success, N'Pengajuan ditolak HR.' AS message, @IDCHECK AS id;
                RETURN;
            END

            IF NOT EXISTS (
                SELECT 1 FROM hr.workers_finger_error s
                WHERE s.id = @IDCHECK
                  AND s.verify = N'user'
                  AND ISNULL(s.approve, N'false') = N'false'
                  AND ISNULL(s.reject, N'false') = N'false'
            )
            BEGIN
                SELECT CAST(0 AS BIT) AS success,
                       N'Hanya pengajuan yang masih menunggu yang dapat diproses.' AS message;
                RETURN;
            END

            IF @LevelKey IN (N'superadmin', N'sa')
            BEGIN
                SET @ActorLegacy = @ActorLegacy;
            END
            ELSE IF @ActorRank = @SecSh AND @SecSh IS NOT NULL
            BEGIN
                IF @RowSection IS NULL
                   OR @SCOPE_SECTIONS IS NULL
                   OR LTRIM(RTRIM(@SCOPE_SECTIONS)) = N''
                   OR @RowSection NOT IN (
                        SELECT TRY_CAST(LTRIM(RTRIM(value)) AS INT)
                        FROM STRING_SPLIT(@SCOPE_SECTIONS, N',')
                   )
                BEGIN
                    SELECT CAST(0 AS BIT) AS success, N'Section di luar scope Anda.' AS message;
                    RETURN;
                END
            END
            ELSE IF @ActorRank = @SecUh AND @SecUh IS NOT NULL
            BEGIN
                IF @RowSection IS NULL
                   OR @SCOPE_SECTIONS IS NULL
                   OR LTRIM(RTRIM(@SCOPE_SECTIONS)) = N''
                   OR @RowSection NOT IN (
                        SELECT TRY_CAST(LTRIM(RTRIM(value)) AS INT)
                        FROM STRING_SPLIT(@SCOPE_SECTIONS, N',')
                   )
                BEGIN
                    SELECT CAST(0 AS BIT) AS success, N'Section di luar scope Anda.' AS message;
                    RETURN;
                END

                IF EXISTS (
                    SELECT 1 FROM hr.v_workers_active w
                    WHERE w.by_jobsite = @Jobsite AND w.[section] = @RowSection AND w.job_rank = @SecSh
                )
                BEGIN
                    SELECT CAST(0 AS BIT) AS success,
                           N'Section ini punya Section Head; Unit Head tidak dapat approve.' AS message;
                    RETURN;
                END
            END
            ELSE
            BEGIN
                SELECT CAST(0 AS BIT) AS success,
                       N'Hanya Section Head atau Unit Head (section tanpa Section Head) yang dapat approve.' AS message;
                RETURN;
            END

            SELECT @ActorLegacy = CAST(ISNULL(u.legacy_id, u.id) AS BIGINT)
            FROM hr.users u
            WHERE u.id = @BY_USER AND u.deleted_at IS NULL;

            -- Same as legacy section action_save: child stays verify=section
            -- with approve/reject false so the list reads "Waiting approve by HR".
            -- Parent approve=true records that Section already agreed.
            -- Reject does not insert a child (legacy action_reject updates the parent only).
            IF @WantReject = 0
            BEGIN
                INSERT INTO hr.workers_finger_error (
                    by_jobsite, ref_id, key_id, [date], nrp, nrp_int, full_name,
                    location, finger_in, finger_out, category, shift, remark,
                    path_evident, description, note,
                    verify, approve, reject, by_user,
                    created_by, updated_at, updated_by
                )
                SELECT
                    s.by_jobsite, s.id,
                    UPPER(CONVERT(VARCHAR(40), HASHBYTES(
                        'SHA1',
                        CONCAT(CAST(s.id AS NVARCHAR(20)), N'_', CONVERT(VARCHAR(19), GETDATE(), 120))
                    ), 2)),
                    s.[date], s.nrp, s.nrp_int, s.full_name,
                    s.location, s.finger_in, s.finger_out, s.category, s.shift, s.remark,
                    s.path_evident, s.description, s.note,
                    N'section', N'false', N'false',
                    @ActorLegacy,
                    @BY_USER, SYSUTCDATETIME(), @BY_USER
                FROM hr.workers_finger_error s
                WHERE s.id = @IDCHECK;
            END

            UPDATE hr.workers_finger_error
            SET
                approve = CASE WHEN @WantReject = 1 THEN N'false' ELSE N'true' END,
                reject = CASE WHEN @WantReject = 1 THEN N'true' ELSE N'false' END,
                by_verified = @ActorLegacy,
                note = CASE
                    WHEN @WantReject = 1 THEN ISNULL(NULLIF(LTRIM(RTRIM(@NOTE)), N''), note)
                    ELSE note
                END,
                updated_at = SYSUTCDATETIME(),
                updated_by = @BY_USER
            WHERE id = @IDCHECK;

            SELECT CAST(1 AS BIT) AS success,
                   CASE WHEN @WantReject = 1 THEN N'Pengajuan ditolak.' ELSE N'Pengajuan disetujui.' END AS message,
                   @IDCHECK AS id;
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
