-- =============================================
-- Expand hr.workers_sickness to match dbo.workers_sickness (+ keep HR extras)
-- + hr.SAKIT_SP (SELECT | GET) for Reconciliation → Sakit (read-only list)
-- Run AFTER 35_attendance_sources.sql + 23_views_workers_active.sql
-- =============================================

IF OBJECT_ID('hr.workers_sickness', 'U') IS NULL
BEGIN
    THROW 50052, 'hr.workers_sickness missing. Apply 35_attendance_sources.sql first.', 1;
END;
GO

-- Mirror dbo.workers_sickness business columns (nullable for safe ALTER on existing rows).
-- HR extras kept: by_jobsite, created_by, updated_by, deleted_by, legacy_id.

IF COL_LENGTH('hr.workers_sickness', 'key_id') IS NULL
    ALTER TABLE hr.workers_sickness ADD key_id NVARCHAR(50) NULL;
IF COL_LENGTH('hr.workers_sickness', 'date') IS NULL
    ALTER TABLE hr.workers_sickness ADD [date] DATE NULL;
IF COL_LENGTH('hr.workers_sickness', 'nrp_int') IS NULL
    ALTER TABLE hr.workers_sickness ADD nrp_int NVARCHAR(25) NULL;
IF COL_LENGTH('hr.workers_sickness', 'full_name') IS NULL
    ALTER TABLE hr.workers_sickness ADD full_name NVARCHAR(200) NULL;
IF COL_LENGTH('hr.workers_sickness', 'diagnosa') IS NULL
    ALTER TABLE hr.workers_sickness ADD diagnosa NVARCHAR(150) NULL;
IF COL_LENGTH('hr.workers_sickness', 'name_doctor') IS NULL
    ALTER TABLE hr.workers_sickness ADD name_doctor NVARCHAR(150) NULL;
IF COL_LENGTH('hr.workers_sickness', 'name_agency') IS NULL
    ALTER TABLE hr.workers_sickness ADD name_agency NVARCHAR(150) NULL;
IF COL_LENGTH('hr.workers_sickness', 'date_issue') IS NULL
    ALTER TABLE hr.workers_sickness ADD date_issue DATE NULL;
IF COL_LENGTH('hr.workers_sickness', 'category') IS NULL
    ALTER TABLE hr.workers_sickness ADD category NVARCHAR(150) NULL;
IF COL_LENGTH('hr.workers_sickness', 'path_evident') IS NULL
    ALTER TABLE hr.workers_sickness ADD path_evident NVARCHAR(MAX) NULL;
IF COL_LENGTH('hr.workers_sickness', 'description') IS NULL
    ALTER TABLE hr.workers_sickness ADD description NVARCHAR(MAX) NULL;
IF COL_LENGTH('hr.workers_sickness', 'note') IS NULL
    ALTER TABLE hr.workers_sickness ADD note NVARCHAR(MAX) NULL;
IF COL_LENGTH('hr.workers_sickness', 'approve') IS NULL
    ALTER TABLE hr.workers_sickness ADD approve NVARCHAR(5) NULL;
IF COL_LENGTH('hr.workers_sickness', 'reject') IS NULL
    ALTER TABLE hr.workers_sickness ADD reject NVARCHAR(5) NULL;
IF COL_LENGTH('hr.workers_sickness', 'by_verified') IS NULL
    ALTER TABLE hr.workers_sickness ADD by_verified BIGINT NULL;
IF COL_LENGTH('hr.workers_sickness', 'by_user') IS NULL
    ALTER TABLE hr.workers_sickness ADD by_user BIGINT NULL;
IF COL_LENGTH('hr.workers_sickness', 'kriteria') IS NULL
    ALTER TABLE hr.workers_sickness ADD kriteria NUMERIC(18, 0) NULL;
IF COL_LENGTH('hr.workers_sickness', 'note_dokter') IS NULL
    ALTER TABLE hr.workers_sickness ADD note_dokter NVARCHAR(MAX) NULL;
IF COL_LENGTH('hr.workers_sickness', 'note_hr') IS NULL
    ALTER TABLE hr.workers_sickness ADD note_hr NVARCHAR(MAX) NULL;
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
    @BY_USER INT = NULL,
    @BY_JOBSITE INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Jobsite INT = ISNULL(@BY_JOBSITE, 1);

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
