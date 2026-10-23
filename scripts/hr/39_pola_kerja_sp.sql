-- =============================================
-- hr.POLA_KERJA_SP — menu hr_pola_kerja
-- Actions: SELECT | GET | LOOKUP | INSERT | UPDATE | DELETE
--          | GENERATE_PREVIEW | GENERATE
-- Source: hr.workers_pola_kerja + hr.workers_roster_kerja + hr.v_workers_active
-- List/export filters stay in this SP (no TVF) so query changes are one place.
-- GENERATE expands seed rows into daily roster (legacy self_workers_pola_kerja).
-- Run AFTER 37_workers_pola_kerja.sql + 31_workers_roster_kerja.sql + 23_views_workers_active.sql
-- =============================================
CREATE OR ALTER PROCEDURE hr.POLA_KERJA_SP
    @ACTION_SP NVARCHAR(30) = NULL,
    @ID INT = NULL,
    @MONTH NVARCHAR(7) = NULL,          -- YYYY-MM (SELECT / GENERATE*)
    @DEPARTMENT NVARCHAR(250) = NULL,
    @SECTION NVARCHAR(250) = NULL,
    @JOB_RANK NVARCHAR(50) = NULL,
    @PAGE INT = 1,
    @PAGE_SIZE INT = 0,
    @SEARCH NVARCHAR(150) = NULL,
    @SCOPE_SECTIONS NVARCHAR(MAX) = NULL,
    @DATE DATE = NULL,
    @NRP NVARCHAR(MAX) = NULL,          -- single NRP or CSV (GENERATE*)
    @POLA_KERJA NVARCHAR(100) = NULL,
    @POLA_CUTI NVARCHAR(100) = NULL,     -- masa_onsite:cuti_lapangan
    @POLA_HARI NVARCHAR(100) = NULL,
    @HARI_KE INT = NULL,
    @REMARK NVARCHAR(20) = NULL,
    @BY_USER INT = NULL,
    @BY_JOBSITE INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Jobsite INT = ISNULL(@BY_JOBSITE, 1);
    DECLARE @IDCHECK INT;
    DECLARE @NrpClean NVARCHAR(MAX) = UPPER(LTRIM(RTRIM(ISNULL(@NRP, N''))));

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
                p.id,
                p.by_jobsite,
                p.[date],
                p.nrp,
                ISNULL(wa.full_name, N'') AS full_name,
                ISNULL(wa.jabatan, N'') AS jabatan,
                wa.department,
                ISNULL(wa.department_name, N'') AS department_name,
                wa.[section],
                ISNULL(wa.section_name, N'') AS section_name,
                p.pola_cuti,
                p.pola_kerja,
                p.pola_hari,
                p.hari_ke,
                p.remark,
                p.created_at,
                p.updated_at
            FROM hr.workers_pola_kerja p
            LEFT JOIN hr.v_workers_active wa
                ON wa.nrp = p.nrp
               AND wa.by_jobsite = p.by_jobsite
            WHERE p.deleted_at IS NULL
              AND p.by_jobsite = @Jobsite
              AND p.[date] >= @FromDate
              AND p.[date] < @ToDate
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
                 OR p.nrp LIKE N'%' + @Q + N'%'
                 OR wa.full_name LIKE N'%' + @Q + N'%'
                 OR p.pola_kerja LIKE N'%' + @Q + N'%'
                 OR p.remark LIKE N'%' + @Q + N'%'
                  )
            ORDER BY p.nrp ASC, p.[date] ASC
            OFFSET CASE WHEN @PAGE_SIZE > 0 THEN (@PAGE - 1) * @PAGE_SIZE ELSE 0 END ROWS
            FETCH NEXT CASE WHEN @PAGE_SIZE > 0 THEN @PAGE_SIZE ELSE 100000 END ROWS ONLY;

            SELECT COUNT(*) AS total_count
            FROM hr.workers_pola_kerja p
            LEFT JOIN hr.v_workers_active wa
                ON wa.nrp = p.nrp
               AND wa.by_jobsite = p.by_jobsite
            WHERE p.deleted_at IS NULL
              AND p.by_jobsite = @Jobsite
              AND p.[date] >= @FromDate
              AND p.[date] < @ToDate
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
                 OR p.nrp LIKE N'%' + @Q + N'%'
                 OR wa.full_name LIKE N'%' + @Q + N'%'
                 OR p.pola_kerja LIKE N'%' + @Q + N'%'
                 OR p.remark LIKE N'%' + @Q + N'%'
                  );
        END
        ELSE IF @ACTION_SP = N'GET'
        BEGIN
            SELECT
                p.id,
                p.by_jobsite,
                p.[date],
                p.nrp,
                ISNULL(wa.full_name, N'') AS full_name,
                ISNULL(wa.jabatan, N'') AS jabatan,
                wa.department,
                ISNULL(wa.department_name, N'') AS department_name,
                wa.[section],
                ISNULL(wa.section_name, N'') AS section_name,
                p.pola_cuti,
                p.pola_kerja,
                p.pola_hari,
                p.hari_ke,
                p.remark,
                p.created_at,
                p.updated_at
            FROM hr.workers_pola_kerja p
            LEFT JOIN hr.v_workers_active wa
                ON wa.nrp = p.nrp
               AND wa.by_jobsite = p.by_jobsite
            WHERE p.deleted_at IS NULL
              AND p.by_jobsite = @Jobsite
              AND p.id = @ID;
        END
        ELSE IF @ACTION_SP = N'LOOKUP'
        BEGIN
            IF @NrpClean = N''
            BEGIN
                SELECT CAST(0 AS BIT) AS success, N'NRP is required.' AS message;
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
              AND wa.nrp = @NrpClean;
        END
        ELSE IF @ACTION_SP = N'INSERT'
        BEGIN
            IF @NrpClean = N''
               OR @DATE IS NULL
               OR @POLA_KERJA IS NULL OR LTRIM(RTRIM(@POLA_KERJA)) = N''
               OR @POLA_CUTI IS NULL OR LTRIM(RTRIM(@POLA_CUTI)) = N''
               OR @HARI_KE IS NULL
            BEGIN
                SELECT CAST(0 AS BIT) AS success,
                       N'nrp, date, pola_kerja, pola_cuti, and hari_ke are required.' AS message;
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

            INSERT INTO hr.workers_pola_kerja (
                by_jobsite, [date], nrp, nrp_int, pola_kerja, pola_cuti, pola_hari,
                hari_ke, remark, created_by, updated_at, updated_by
            )
            VALUES (
                @Jobsite,
                @DATE,
                @NrpClean,
                @NrpClean,
                UPPER(LTRIM(RTRIM(@POLA_KERJA))),
                UPPER(LTRIM(RTRIM(@POLA_CUTI))),
                ISNULL(NULLIF(LTRIM(RTRIM(@POLA_HARI)), N''), N'1'),
                @HARI_KE,
                UPPER(NULLIF(LTRIM(RTRIM(@REMARK)), N'')),
                @BY_USER,
                SYSUTCDATETIME(),
                @BY_USER
            );

            SELECT CAST(1 AS BIT) AS success,
                   N'Pola kerja saved successfully.' AS message,
                   CAST(SCOPE_IDENTITY() AS INT) AS id;
        END
        ELSE IF @ACTION_SP = N'UPDATE'
        BEGIN
            SELECT @IDCHECK = id
            FROM hr.workers_pola_kerja
            WHERE deleted_at IS NULL
              AND id = @ID
              AND by_jobsite = @Jobsite;

            IF @IDCHECK IS NULL
            BEGIN
                SELECT CAST(0 AS BIT) AS success, N'Pola kerja not found.' AS message;
                RETURN;
            END

            IF @NrpClean = N''
               OR @DATE IS NULL
               OR @POLA_KERJA IS NULL OR LTRIM(RTRIM(@POLA_KERJA)) = N''
               OR @POLA_CUTI IS NULL OR LTRIM(RTRIM(@POLA_CUTI)) = N''
               OR @HARI_KE IS NULL
            BEGIN
                SELECT CAST(0 AS BIT) AS success,
                       N'nrp, date, pola_kerja, pola_cuti, and hari_ke are required.' AS message;
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

            UPDATE hr.workers_pola_kerja
            SET
                [date] = @DATE,
                nrp = @NrpClean,
                nrp_int = @NrpClean,
                pola_kerja = UPPER(LTRIM(RTRIM(@POLA_KERJA))),
                pola_cuti = UPPER(LTRIM(RTRIM(@POLA_CUTI))),
                pola_hari = ISNULL(NULLIF(LTRIM(RTRIM(@POLA_HARI)), N''), pola_hari),
                hari_ke = @HARI_KE,
                remark = UPPER(NULLIF(LTRIM(RTRIM(@REMARK)), N'')),
                updated_at = SYSUTCDATETIME(),
                updated_by = @BY_USER
            WHERE id = @IDCHECK;

            SELECT CAST(1 AS BIT) AS success, N'Pola kerja updated successfully.' AS message, @IDCHECK AS id;
        END
        ELSE IF @ACTION_SP = N'DELETE'
        BEGIN
            SELECT @IDCHECK = id
            FROM hr.workers_pola_kerja
            WHERE deleted_at IS NULL
              AND id = @ID
              AND by_jobsite = @Jobsite;

            IF @IDCHECK IS NULL
            BEGIN
                SELECT CAST(0 AS BIT) AS success, N'Pola kerja not found.' AS message;
                RETURN;
            END

            UPDATE hr.workers_pola_kerja
            SET deleted_at = SYSUTCDATETIME(),
                deleted_by = @BY_USER,
                updated_at = SYSUTCDATETIME(),
                updated_by = @BY_USER
            WHERE id = @IDCHECK;

            SELECT CAST(1 AS BIT) AS success, N'Pola kerja deleted successfully.' AS message, @IDCHECK AS id;
        END
        ELSE IF @ACTION_SP IN (N'GENERATE_PREVIEW', N'GENERATE')
        BEGIN
            ---------------------------------------------------------------
            -- Seed set for month (latest row per NRP) — no TVF.
            -- GENERATE expands each seed into daily hr.workers_roster_kerja
            -- through the 1st of next month (legacy Generate Fix).
            ---------------------------------------------------------------
            DECLARE @GMonthRaw NVARCHAR(7) = NULLIF(LTRIM(RTRIM(@MONTH)), N'');
            DECLARE @GYear INT;
            DECLARE @GMon INT;
            DECLARE @GFrom DATE;
            DECLARE @GTo DATE;
            DECLARE @GScope NVARCHAR(MAX) = ISNULL(LTRIM(RTRIM(@SCOPE_SECTIONS)), N'');
            DECLARE @GHasScope BIT = CASE WHEN @GScope = N'' THEN 0 ELSE 1 END;
            DECLARE @GNrpFilter NVARCHAR(MAX) = @NrpClean;

            IF @GMonthRaw IS NOT NULL
               AND LEN(@GMonthRaw) = 7
               AND SUBSTRING(@GMonthRaw, 5, 1) = N'-'
            BEGIN
                SET @GYear = TRY_CAST(LEFT(@GMonthRaw, 4) AS INT);
                SET @GMon = TRY_CAST(RIGHT(@GMonthRaw, 2) AS INT);
            END

            IF @GYear IS NULL OR @GMon IS NULL OR @GMon < 1 OR @GMon > 12
            BEGIN
                SELECT CAST(0 AS BIT) AS success,
                       N'month must be YYYY-MM.' AS message,
                       CAST(0 AS INT) AS workers,
                       CAST(0 AS INT) AS days_upserted;
                RETURN;
            END

            SET @GFrom = DATEFROMPARTS(@GYear, @GMon, 1);
            SET @GTo = DATEADD(MONTH, 1, @GFrom);

            DECLARE @GScopeIds TABLE (id INT PRIMARY KEY);
            IF @GHasScope = 1
            BEGIN
                INSERT INTO @GScopeIds (id)
                SELECT DISTINCT TRY_CAST(LTRIM(RTRIM(value)) AS INT)
                FROM STRING_SPLIT(@GScope, N',')
                WHERE TRY_CAST(LTRIM(RTRIM(value)) AS INT) IS NOT NULL;
            END

            DECLARE @GNrpIds TABLE (nrp NVARCHAR(40) PRIMARY KEY);
            IF @GNrpFilter <> N''
            BEGIN
                INSERT INTO @GNrpIds (nrp)
                SELECT DISTINCT UPPER(LTRIM(RTRIM(value)))
                FROM STRING_SPLIT(@GNrpFilter, N',')
                WHERE LTRIM(RTRIM(value)) <> N'';
            END

            DECLARE @GSeeds TABLE (
                id INT NOT NULL PRIMARY KEY,
                [date] DATE NOT NULL,
                nrp NVARCHAR(40) NOT NULL,
                full_name NVARCHAR(200) NULL,
                pola_kerja NVARCHAR(100) NULL,
                pola_cuti NVARCHAR(100) NULL,
                pola_hari NVARCHAR(100) NULL,
                hari_ke INT NULL,
                remark NVARCHAR(20) NULL
            );

            ;WITH latest AS (
                SELECT MAX(p.id) AS id
                FROM hr.workers_pola_kerja p
                WHERE p.deleted_at IS NULL
                  AND p.by_jobsite = @Jobsite
                  AND p.[date] >= @GFrom
                  AND p.[date] < @GTo
                  AND (
                        @GNrpFilter = N''
                     OR p.nrp IN (SELECT nrp FROM @GNrpIds)
                      )
                GROUP BY p.nrp
            )
            INSERT INTO @GSeeds (
                id, [date], nrp, full_name, pola_kerja, pola_cuti, pola_hari, hari_ke, remark
            )
            SELECT
                p.id,
                p.[date],
                p.nrp,
                ISNULL(wa.full_name, N''),
                p.pola_kerja,
                p.pola_cuti,
                p.pola_hari,
                p.hari_ke,
                p.remark
            FROM latest l
            INNER JOIN hr.workers_pola_kerja p ON p.id = l.id
            LEFT JOIN hr.v_workers_active wa
                ON wa.nrp = p.nrp
               AND wa.by_jobsite = p.by_jobsite
            WHERE (
                    @GHasScope = 0
                 OR wa.[section] IN (SELECT id FROM @GScopeIds)
                  );

            IF @ACTION_SP = N'GENERATE_PREVIEW'
            BEGIN
                SELECT
                    s.[date],
                    s.nrp,
                    s.full_name,
                    s.pola_kerja,
                    s.pola_cuti,
                    s.pola_hari,
                    s.hari_ke,
                    s.remark
                FROM @GSeeds s
                ORDER BY s.nrp ASC, s.[date] ASC;

                SELECT COUNT(*) AS total_count FROM @GSeeds;
                RETURN;
            END

            -- GENERATE
            IF NOT EXISTS (SELECT 1 FROM @GSeeds)
            BEGIN
                SELECT CAST(0 AS BIT) AS success,
                       N'Tidak ada data pola untuk digenerate.' AS message,
                       CAST(0 AS INT) AS workers,
                       CAST(0 AS INT) AS days_upserted;
                RETURN;
            END

            DECLARE @DaysUpserted INT = 0;
            DECLARE @WorkersDone INT = 0;

            DECLARE @SId INT, @SDate DATE, @SNrp NVARCHAR(40), @SName NVARCHAR(200);
            DECLARE @SPola NVARCHAR(100), @SCuti NVARCHAR(100), @SPolaHari NVARCHAR(100);
            DECLARE @SHariKe INT, @SRemark NVARCHAR(20);

            DECLARE @PartCount INT, @TotalPola INT, @TotalCuti INT;
            DECLARE @P1 INT, @P2 INT, @P3 INT, @P4 INT;
            DECLARE @CurDate DATE, @EndDate DATE, @NextMonthFirst DATE;
            DECLARE @Hari INT, @HariKerja INT;
            DECLARE @SeedRemark NVARCHAR(20), @DayRemark NVARCHAR(20);
            DECLARE @RosterId INT, @PolaSeedId INT;
            DECLARE @ParseRest NVARCHAR(200), @Token NVARCHAR(40), @TokInt INT, @Ord INT;

            DECLARE seed_cur CURSOR LOCAL FAST_FORWARD FOR
                SELECT id, [date], nrp, full_name, pola_kerja, pola_cuti, pola_hari, hari_ke, remark
                FROM @GSeeds
                ORDER BY nrp;

            OPEN seed_cur;
            FETCH NEXT FROM seed_cur INTO
                @SId, @SDate, @SNrp, @SName, @SPola, @SCuti, @SPolaHari, @SHariKe, @SRemark;

            WHILE @@FETCH_STATUS = 0
            BEGIN
                -- Ordered parse of "a:b:c:d" (STRING_SPLIT order is not guaranteed)
                SET @P1 = 0; SET @P2 = 0; SET @P3 = 0; SET @P4 = 0;
                SET @PartCount = 0; SET @TotalPola = 0; SET @TotalCuti = 0;
                SET @ParseRest = LTRIM(RTRIM(ISNULL(@SPola, N''))) + N':';
                WHILE CHARINDEX(N':', @ParseRest) > 0 AND @PartCount < 4
                BEGIN
                    SET @Token = LEFT(@ParseRest, CHARINDEX(N':', @ParseRest) - 1);
                    SET @TokInt = TRY_CAST(LTRIM(RTRIM(@Token)) AS INT);
                    SET @ParseRest = SUBSTRING(@ParseRest, CHARINDEX(N':', @ParseRest) + 1, 400);
                    IF @TokInt IS NULL CONTINUE;
                    SET @PartCount += 1;
                    SET @TotalPola += @TokInt;
                    IF @PartCount = 1 SET @P1 = @TokInt;
                    ELSE IF @PartCount = 2 SET @P2 = @TokInt;
                    ELSE IF @PartCount = 3 SET @P3 = @TokInt;
                    ELSE IF @PartCount = 4 SET @P4 = @TokInt;
                END

                SET @ParseRest = LTRIM(RTRIM(ISNULL(@SCuti, N''))) + N':';
                WHILE CHARINDEX(N':', @ParseRest) > 0
                BEGIN
                    SET @Token = LEFT(@ParseRest, CHARINDEX(N':', @ParseRest) - 1);
                    SET @TokInt = TRY_CAST(LTRIM(RTRIM(@Token)) AS INT);
                    SET @ParseRest = SUBSTRING(@ParseRest, CHARINDEX(N':', @ParseRest) + 1, 400);
                    IF @TokInt IS NOT NULL SET @TotalCuti += @TokInt;
                END

                IF @PartCount < 2 OR @TotalPola <= 0
                BEGIN
                    FETCH NEXT FROM seed_cur INTO
                        @SId, @SDate, @SNrp, @SName, @SPola, @SCuti, @SPolaHari, @SHariKe, @SRemark;
                    CONTINUE;
                END

                SET @CurDate = @SDate;
                SET @EndDate = DATEADD(DAY, 1, EOMONTH(@SDate)); -- inclusive 1st next month
                SET @NextMonthFirst = DATEADD(MONTH, 1, DATEFROMPARTS(YEAR(@SDate), MONTH(@SDate), 1));
                SET @Hari = ISNULL(@SHariKe, 1);
                SET @HariKerja = ISNULL(TRY_CAST(@SPolaHari AS INT), 1);
                SET @SeedRemark = UPPER(NULLIF(LTRIM(RTRIM(@SRemark)), N''));

                WHILE @CurDate <= @EndDate
                BEGIN
                    SET @DayRemark = N'';
                    IF @PartCount = 2
                    BEGIN
                        IF @Hari <= @P1 SET @DayRemark = N'D';
                        ELSE IF @Hari <= @P1 + @P2 SET @DayRemark = N'OFF';
                        ELSE SET @DayRemark = @SeedRemark;
                    END
                    ELSE IF @PartCount = 3
                    BEGIN
                        IF @Hari <= @P1 SET @DayRemark = N'D';
                        ELSE IF @Hari <= @P1 + @P2 SET @DayRemark = N'N';
                        ELSE IF @Hari <= @P1 + @P2 + @P3 SET @DayRemark = N'OFF';
                        ELSE SET @DayRemark = @SeedRemark;
                    END
                    ELSE -- 4 parts: D / OFF / N / OFF (legacy case 4)
                    BEGIN
                        IF @Hari <= @P1 SET @DayRemark = N'D';
                        ELSE IF @Hari <= @P1 + @P2 SET @DayRemark = N'OFF';
                        ELSE IF @Hari <= @P1 + @P2 + @P3 SET @DayRemark = N'N';
                        ELSE IF @Hari <= @P1 + @P2 + @P3 + @P4 SET @DayRemark = N'OFF';
                        ELSE SET @DayRemark = @SeedRemark;
                    END

                    SET @RosterId = NULL;
                    SELECT TOP 1 @RosterId = id
                    FROM hr.workers_roster_kerja
                    WHERE by_jobsite = @Jobsite
                      AND nrp = @SNrp
                      AND [date] = @CurDate
                    ORDER BY CASE WHEN deleted_at IS NULL THEN 0 ELSE 1 END, id DESC;

                    IF @RosterId IS NULL
                    BEGIN
                        INSERT INTO hr.workers_roster_kerja (
                            by_jobsite, [date], nrp, nrp_int, pola_kerja, pola_cuti, pola_hari,
                            hari_ke, remark, created_by, updated_at, updated_by
                        )
                        VALUES (
                            @Jobsite, @CurDate, @SNrp, @SNrp,
                            UPPER(LTRIM(RTRIM(@SPola))),
                            UPPER(LTRIM(RTRIM(@SCuti))),
                            CAST(@HariKerja AS NVARCHAR(100)),
                            @Hari,
                            @DayRemark,
                            @BY_USER,
                            SYSUTCDATETIME(),
                            @BY_USER
                        );
                    END
                    ELSE
                    BEGIN
                        UPDATE hr.workers_roster_kerja
                        SET
                            nrp_int = @SNrp,
                            pola_kerja = UPPER(LTRIM(RTRIM(@SPola))),
                            pola_cuti = UPPER(LTRIM(RTRIM(@SCuti))),
                            pola_hari = CAST(@HariKerja AS NVARCHAR(100)),
                            hari_ke = @Hari,
                            remark = @DayRemark,
                            deleted_at = NULL,
                            deleted_by = NULL,
                            updated_at = SYSUTCDATETIME(),
                            updated_by = @BY_USER
                        WHERE id = @RosterId;
                    END

                    SET @DaysUpserted += 1;

                    -- Carry seed into next month on the 1st (legacy)
                    IF @CurDate = @NextMonthFirst
                    BEGIN
                        SET @PolaSeedId = NULL;
                        SELECT TOP 1 @PolaSeedId = id
                        FROM hr.workers_pola_kerja
                        WHERE by_jobsite = @Jobsite
                          AND nrp = @SNrp
                          AND [date] = @CurDate
                        ORDER BY CASE WHEN deleted_at IS NULL THEN 0 ELSE 1 END, id DESC;

                        IF @PolaSeedId IS NULL
                        BEGIN
                            INSERT INTO hr.workers_pola_kerja (
                                by_jobsite, [date], nrp, nrp_int, pola_kerja, pola_cuti, pola_hari,
                                hari_ke, remark, created_by, updated_at, updated_by
                            )
                            VALUES (
                                @Jobsite, @CurDate, @SNrp, @SNrp,
                                UPPER(LTRIM(RTRIM(@SPola))),
                                UPPER(LTRIM(RTRIM(@SCuti))),
                                CAST(@HariKerja AS NVARCHAR(100)),
                                @Hari,
                                @DayRemark,
                                @BY_USER,
                                SYSUTCDATETIME(),
                                @BY_USER
                            );
                        END
                        ELSE
                        BEGIN
                            UPDATE hr.workers_pola_kerja
                            SET
                                nrp_int = @SNrp,
                                pola_kerja = UPPER(LTRIM(RTRIM(@SPola))),
                                pola_cuti = UPPER(LTRIM(RTRIM(@SCuti))),
                                pola_hari = CAST(@HariKerja AS NVARCHAR(100)),
                                hari_ke = @Hari,
                                remark = @DayRemark,
                                deleted_at = NULL,
                                deleted_by = NULL,
                                updated_at = SYSUTCDATETIME(),
                                updated_by = @BY_USER
                            WHERE id = @PolaSeedId;
                        END
                    END

                    IF @Hari >= @TotalPola SET @Hari = 0;
                    IF @TotalCuti > 0 AND @HariKerja = @TotalCuti SET @HariKerja = 0;

                    SET @Hari += 1;
                    SET @HariKerja += 1;
                    SET @CurDate = DATEADD(DAY, 1, @CurDate);
                END

                SET @WorkersDone += 1;

                FETCH NEXT FROM seed_cur INTO
                    @SId, @SDate, @SNrp, @SName, @SPola, @SCuti, @SPolaHari, @SHariKe, @SRemark;
            END

            CLOSE seed_cur;
            DEALLOCATE seed_cur;

            SELECT CAST(1 AS BIT) AS success,
                   N'Generate roster selesai.' AS message,
                   @WorkersDone AS workers,
                   @DaysUpserted AS days_upserted;
        END
        ELSE
        BEGIN
            SELECT CAST(0 AS BIT) AS success, N'Unknown ACTION_SP' AS message, CAST(NULL AS INT) AS id;
        END
    END TRY
    BEGIN CATCH
        SELECT CAST(0 AS BIT) AS success, ERROR_MESSAGE() AS message, CAST(NULL AS INT) AS id;
    END CATCH
END
GO
