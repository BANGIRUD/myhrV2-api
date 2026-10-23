-- =============================================
-- hr.ROSTER_KERJA_SP — menu hr_roster_kerja
-- Actions: SELECT | GET | UPDATE | GET_EDIT_POLICY
-- Source: hr.workers_roster_kerja + hr.v_workers_active + hr.edit_policy
-- Daily roster rows (usually written by POLA_KERJA_SP GENERATE).
-- UPDATE only changes remark; edit window from hr.edit_policy
--   (module_code = N'roster_kerja', by @LEVEL_CODE).
-- Run AFTER 31 + 23 + 48_edit_policy.sql (falls back to hr.roster_edit_policy if present)
-- =============================================
CREATE OR ALTER PROCEDURE hr.ROSTER_KERJA_SP
    @ACTION_SP NVARCHAR(30) = NULL,
    @ID INT = NULL,
    @MONTH NVARCHAR(7) = NULL,          -- YYYY-MM (SELECT)
    @DEPARTMENT NVARCHAR(250) = NULL,
    @SECTION NVARCHAR(250) = NULL,
    @JOB_RANK NVARCHAR(50) = NULL,
    @PAGE INT = 1,
    @PAGE_SIZE INT = 0,
    @SEARCH NVARCHAR(150) = NULL,
    @SCOPE_SECTIONS NVARCHAR(MAX) = NULL,
    @REMARK NVARCHAR(20) = NULL,
    @LEVEL_CODE NVARCHAR(50) = NULL,     -- caller level; drives hr.roster_edit_policy
    @BY_USER INT = NULL,
    @BY_JOBSITE INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Jobsite INT = ISNULL(@BY_JOBSITE, 1);
    DECLARE @LevelKey NVARCHAR(50) = LOWER(LTRIM(RTRIM(ISNULL(@LEVEL_CODE, N''))));

    BEGIN TRY
        IF @ACTION_SP = N'SELECT'
        BEGIN
            DECLARE @Dept NVARCHAR(250) = ISNULL(LTRIM(RTRIM(@DEPARTMENT)), N'');
            DECLARE @Sect NVARCHAR(250) = ISNULL(LTRIM(RTRIM(@SECTION)), N'');
            DECLARE @JobRank INT = TRY_CAST(NULLIF(LTRIM(RTRIM(@JOB_RANK)), N'') AS INT);
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

            SELECT
                r.id,
                r.by_jobsite,
                r.[date],
                r.nrp,
                ISNULL(wa.full_name, N'') AS full_name,
                ISNULL(wa.jabatan, N'') AS jabatan,
                wa.department,
                ISNULL(wa.department_name, N'') AS department_name,
                wa.[section],
                ISNULL(wa.section_name, N'') AS section_name,
                r.pola_cuti,
                r.pola_kerja,
                r.pola_hari,
                r.hari_ke,
                r.remark,
                r.created_at,
                r.updated_at
            FROM hr.workers_roster_kerja r
            LEFT JOIN hr.v_workers_active wa
                ON wa.nrp = r.nrp
               AND wa.by_jobsite = r.by_jobsite
            WHERE r.deleted_at IS NULL
              AND r.by_jobsite = @Jobsite
              AND r.[date] >= @FromDate
              AND r.[date] < @ToDate
              AND (@Dept = N'' OR wa.department IN (
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
              AND (
                    @HasScope = 0
                 OR wa.[section] IN (SELECT id FROM @ScopeIds)
                  )
              AND (
                    @Q IS NULL
                 OR r.nrp LIKE N'%' + @Q + N'%'
                 OR wa.full_name LIKE N'%' + @Q + N'%'
                 OR r.pola_kerja LIKE N'%' + @Q + N'%'
                 OR r.remark LIKE N'%' + @Q + N'%'
                  )
            ORDER BY r.nrp ASC, r.[date] ASC
            OFFSET CASE WHEN @PAGE_SIZE > 0 THEN (@PAGE - 1) * @PAGE_SIZE ELSE 0 END ROWS
            FETCH NEXT CASE WHEN @PAGE_SIZE > 0 THEN @PAGE_SIZE ELSE 100000 END ROWS ONLY;

            SELECT COUNT(*) AS total_count
            FROM hr.workers_roster_kerja r
            LEFT JOIN hr.v_workers_active wa
                ON wa.nrp = r.nrp
               AND wa.by_jobsite = r.by_jobsite
            WHERE r.deleted_at IS NULL
              AND r.by_jobsite = @Jobsite
              AND r.[date] >= @FromDate
              AND r.[date] < @ToDate
              AND (@Dept = N'' OR wa.department IN (
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
              AND (
                    @HasScope = 0
                 OR wa.[section] IN (SELECT id FROM @ScopeIds)
                  )
              AND (
                    @Q IS NULL
                 OR r.nrp LIKE N'%' + @Q + N'%'
                 OR wa.full_name LIKE N'%' + @Q + N'%'
                 OR r.pola_kerja LIKE N'%' + @Q + N'%'
                 OR r.remark LIKE N'%' + @Q + N'%'
                  );
        END
        ELSE IF @ACTION_SP = N'GET'
        BEGIN
            SELECT
                r.id,
                r.by_jobsite,
                r.[date],
                r.nrp,
                ISNULL(wa.full_name, N'') AS full_name,
                ISNULL(wa.jabatan, N'') AS jabatan,
                wa.department,
                ISNULL(wa.department_name, N'') AS department_name,
                wa.[section],
                ISNULL(wa.section_name, N'') AS section_name,
                r.pola_cuti,
                r.pola_kerja,
                r.pola_hari,
                r.hari_ke,
                r.remark,
                r.created_at,
                r.updated_at
            FROM hr.workers_roster_kerja r
            LEFT JOIN hr.v_workers_active wa
                ON wa.nrp = r.nrp
               AND wa.by_jobsite = r.by_jobsite
            WHERE r.deleted_at IS NULL
              AND r.by_jobsite = @Jobsite
              AND r.id = @ID;
        END
        ELSE IF @ACTION_SP = N'GET_EDIT_POLICY'
        BEGIN
            -- Resolve edit window for the caller's level (for UI lock hints).
            IF @LevelKey = N''
            BEGIN
                SELECT
                    CAST(0 AS BIT) AS success,
                    CAST(0 AS BIT) AS can_edit,
                    CAST(0 AS BIT) AS allow_past,
                    CAST(0 AS INT) AS past_days,
                    CAST(NULL AS DATE) AS min_editable_date,
                    N'level_code is required.' AS message;
                RETURN;
            END

            DECLARE @PolCanEdit BIT;
            DECLARE @PolAllowPast BIT;
            DECLARE @PolPastDays INT;

            IF OBJECT_ID(N'hr.edit_policy', N'U') IS NOT NULL
            BEGIN
                SELECT TOP 1
                    @PolCanEdit = p.can_edit,
                    @PolAllowPast = p.allow_past,
                    @PolPastDays = p.past_days
                FROM hr.edit_policy p
                WHERE p.by_jobsite = @Jobsite
                  AND p.deleted_at IS NULL
                  AND LOWER(p.module_code) = N'roster_kerja'
                  AND LOWER(p.level_code) = @LevelKey;
            END
            ELSE IF OBJECT_ID(N'hr.roster_edit_policy', N'U') IS NOT NULL
            BEGIN
                SELECT TOP 1
                    @PolCanEdit = p.can_edit,
                    @PolAllowPast = p.allow_past,
                    @PolPastDays = p.past_days
                FROM hr.roster_edit_policy p
                WHERE p.by_jobsite = @Jobsite
                  AND p.deleted_at IS NULL
                  AND LOWER(p.level_code) = @LevelKey;
            END

            IF @PolCanEdit IS NULL
            BEGIN
                -- No policy row → not allowed to edit (add a row to grant).
                SELECT
                    CAST(1 AS BIT) AS success,
                    CAST(0 AS BIT) AS can_edit,
                    CAST(0 AS BIT) AS allow_past,
                    CAST(0 AS INT) AS past_days,
                    CAST(GETDATE() AS DATE) AS min_editable_date,
                    @LevelKey AS level_code,
                    N'No edit_policy row for module roster_kerja + this level.' AS message;
                RETURN;
            END

            SELECT
                CAST(1 AS BIT) AS success,
                @PolCanEdit AS can_edit,
                @PolAllowPast AS allow_past,
                @PolPastDays AS past_days,
                CASE
                    WHEN @PolAllowPast = 1 THEN CAST(NULL AS DATE)
                    ELSE DATEADD(DAY, -ISNULL(@PolPastDays, 0), CAST(GETDATE() AS DATE))
                END AS min_editable_date,
                @LevelKey AS level_code,
                N'OK' AS message;
        END
        ELSE IF @ACTION_SP = N'UPDATE'
        BEGIN
            IF @ID IS NULL
            BEGIN
                SELECT CAST(0 AS BIT) AS success, N'id is required.' AS message;
                RETURN;
            END

            IF @LevelKey = N''
            BEGIN
                SELECT CAST(0 AS BIT) AS success, N'level_code is required.' AS message;
                RETURN;
            END

            DECLARE @RemarkClean NVARCHAR(20) = UPPER(LTRIM(RTRIM(ISNULL(@REMARK, N''))));
            IF @RemarkClean NOT IN (N'D', N'N', N'OFF')
            BEGIN
                SELECT CAST(0 AS BIT) AS success,
                       N'remark must be D, N, or OFF.' AS message;
                RETURN;
            END

            DECLARE @CanEdit BIT;
            DECLARE @AllowPast BIT;
            DECLARE @PastDays INT;

            IF OBJECT_ID(N'hr.edit_policy', N'U') IS NOT NULL
            BEGIN
                SELECT TOP 1
                    @CanEdit = p.can_edit,
                    @AllowPast = p.allow_past,
                    @PastDays = p.past_days
                FROM hr.edit_policy p
                WHERE p.by_jobsite = @Jobsite
                  AND p.deleted_at IS NULL
                  AND LOWER(p.module_code) = N'roster_kerja'
                  AND LOWER(p.level_code) = @LevelKey;
            END
            ELSE IF OBJECT_ID(N'hr.roster_edit_policy', N'U') IS NOT NULL
            BEGIN
                SELECT TOP 1
                    @CanEdit = p.can_edit,
                    @AllowPast = p.allow_past,
                    @PastDays = p.past_days
                FROM hr.roster_edit_policy p
                WHERE p.by_jobsite = @Jobsite
                  AND p.deleted_at IS NULL
                  AND LOWER(p.level_code) = @LevelKey;
            END

            IF @CanEdit IS NULL OR @CanEdit = 0
            BEGIN
                SELECT CAST(0 AS BIT) AS success,
                       N'Level ini tidak diizinkan mengubah roster (lihat hr.edit_policy module=roster_kerja).' AS message;
                RETURN;
            END

            IF NOT EXISTS (
                SELECT 1
                FROM hr.workers_roster_kerja
                WHERE id = @ID
                  AND by_jobsite = @Jobsite
                  AND deleted_at IS NULL
            )
            BEGIN
                SELECT CAST(0 AS BIT) AS success, N'Roster kerja not found.' AS message;
                RETURN;
            END

            DECLARE @RowDate DATE = (
                SELECT [date]
                FROM hr.workers_roster_kerja
                WHERE id = @ID
                  AND by_jobsite = @Jobsite
                  AND deleted_at IS NULL
            );

            DECLARE @Today DATE = CAST(GETDATE() AS DATE);
            DECLARE @MinEditable DATE = DATEADD(DAY, -ISNULL(@PastDays, 0), @Today);

            IF @RowDate IS NOT NULL
               AND ISNULL(@AllowPast, 0) = 0
               AND @RowDate < @MinEditable
            BEGIN
                SELECT CAST(0 AS BIT) AS success,
                       CASE
                           WHEN ISNULL(@PastDays, 0) > 0
                               THEN CONCAT(
                                   N'Roster tidak dapat diubah: tanggal lebih dari H-',
                                   ISNULL(@PastDays, 0),
                                   N' (batas ',
                                   CONVERT(NVARCHAR(10), @MinEditable, 23),
                                   N').'
                               )
                           ELSE N'Roster tidak dapat diubah, karena tanggal sudah lewat.'
                       END AS message;
                RETURN;
            END

            UPDATE hr.workers_roster_kerja
            SET remark = @RemarkClean,
                updated_at = SYSUTCDATETIME(),
                updated_by = @BY_USER
            WHERE id = @ID
              AND by_jobsite = @Jobsite
              AND deleted_at IS NULL;

            SELECT CAST(1 AS BIT) AS success, N'Roster kerja updated.' AS message, @ID AS id;
        END
        ELSE
        BEGIN
            SELECT CAST(0 AS BIT) AS success,
                   N'Unsupported ACTION_SP for ROSTER_KERJA_SP.' AS message;
        END
    END TRY
    BEGIN CATCH
        SELECT CAST(0 AS BIT) AS success,
               CONCAT(N'ROSTER_KERJA_SP error: ', ERROR_MESSAGE()) AS message;
    END CATCH
END
GO
