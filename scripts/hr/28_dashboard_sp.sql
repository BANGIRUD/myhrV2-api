-- =============================================
-- hr.DASHBOARD_SP — dashboard data (Admin Section and other structure-scoped levels)
-- Actions: ATTENDANCE | POLA_KERJA | UNFIT
--
-- BRIDGE: the attendance domain (roster, finger, travel, cuti, sickness, standby,
-- permit, holidays) still lives in dbo. This SP wraps the proven dbo procedures so
-- that all new code goes through hr.*; when those tables are migrated to hr only
-- the bodies below change, not the API or the frontend.
--   ATTENDANCE  -> dbo.workers_attendance(@TANGGAL, @DEPARTMENT, @SECTION)
--   POLA_KERJA  -> dbo.dashboard_pola_kerja(@TANGGAL, @DEPARTMENT, @SECTION)
--   UNFIT       -> dbo.DASHBOARD_EMPLOYEE_UNFIT(@DEPARTMENT_ID, @SECTION_ID)
-- Bridge covers jobsite 1 only; other jobsites return an empty result.
--
-- @SOURCE ('dbo' | 'hr' | 'cache') picks the data source per call; NULL uses the per-action
-- default in the "source defaults" block below. Migration status:
--   UNFIT       hr  (hr.workers_standby, 29_/30_*.sql)   - migrated
--   POLA_KERJA  hr  (hr.workers_roster_kerja, 31_/32_*.sql; rolling month-2..month+2 window,
--                   older/newer months fall back to dbo)   - migrated
--   ATTENDANCE  hr  = COMPUTED in this SP from the hr source tables (35_attendance_sources.sql:
--                   roster, standby, travel, cuti, sickness, permit, cuti kerja, holiday, finger
--                   log + OAMS + corrections). Port of dbo.fv_achievement_attendance_ratio for one
--                   day; to change the attendance rules, edit the "Port of ..." block below.
--                   Window month-2 .. month+2; other days fall back to the dbo bridge. - migrated
--               cache = hr.attendance_ratio (33_/34_*.sql, copy of the Azure cron table); optional,
--                   the Azure cron lags a few days on finger data.
--
-- Result: recordset 1 = rows, recordset 2 = { total_count }.
-- @SCOPE_SECTIONS = CSV of hr.structure section ids the caller may see
-- (NULL / empty = every section). @DATE for POLA_KERJA is any day in the month
-- (normalised to the first day, like the legacy app).
-- Run AFTER 17_structure.sql. Local DB only.
-- =============================================
CREATE OR ALTER PROCEDURE hr.DASHBOARD_SP
    @ACTION_SP NVARCHAR(30) = NULL,
    @DATE DATETIME = NULL,
    @SHIFT NVARCHAR(10) = NULL,            -- all | day | night (ATTENDANCE)
    @DEPARTMENT NVARCHAR(250) = NULL,      -- CSV of department ids ('' = all)
    @SECTION NVARCHAR(250) = NULL,         -- CSV of section ids ('' = all)
    @SCOPE_SECTIONS NVARCHAR(MAX) = NULL,  -- CSV of allowed section ids ('' = all)
    @BY_USER INT = NULL,
    @BY_JOBSITE INT = NULL,
    @SOURCE NVARCHAR(10) = NULL            -- dbo | hr (NULL = per-action default)
AS
BEGIN
    SET NOCOUNT ON;

    -- ---- source defaults (flip an action to 'hr' once the parity check passes) ----
    DECLARE @Src NVARCHAR(10) = LOWER(LTRIM(RTRIM(ISNULL(NULLIF(@SOURCE, N''),
        CASE @ACTION_SP
            WHEN N'UNFIT' THEN N'hr'
            WHEN N'POLA_KERJA' THEN N'hr'
            WHEN N'ATTENDANCE' THEN N'hr'
            ELSE N'dbo'
        END))));
    IF @Src NOT IN (N'dbo', N'hr', N'cache')
        THROW 50029, 'SOURCE must be dbo, hr or cache.', 1;

    DECLARE @Jobsite INT = ISNULL(@BY_JOBSITE, 1);
    DECLARE @Day DATETIME = CAST(ISNULL(@DATE, GETDATE()) AS DATE);

    -- hr.workers_roster_kerja only holds a rolling window (month-2 .. month+2, see
    -- 32_sync_workers_roster_kerja_from_dbo.sql). Outside it, a call that did not ask for a
    -- source explicitly falls back to the dbo bridge so older months stay correct.
    IF @ACTION_SP = N'POLA_KERJA' AND @Src = N'hr' AND NULLIF(@SOURCE, N'') IS NULL
    BEGIN
        DECLARE @RosterFrom DATE = DATEFROMPARTS(YEAR(DATEADD(MONTH, -2, GETDATE())), MONTH(DATEADD(MONTH, -2, GETDATE())), 1);
        DECLARE @RosterTo DATE = DATEFROMPARTS(YEAR(DATEADD(MONTH, 2, GETDATE())), MONTH(DATEADD(MONTH, 2, GETDATE())), 1);
        IF CAST(@Day AS DATE) < @RosterFrom OR CAST(@Day AS DATE) >= @RosterTo
            SET @Src = N'dbo';
    END

    -- ATTENDANCE source tables hold month-2 onwards (35_attendance_sources.sql; roster up to month+2).
    --   hr    = computed in this SP from the hr source tables (default)
    --   cache = hr.attendance_ratio (copy of the Azure cron table, month-2 .. today)
    -- Days outside the window fall back to the dbo bridge unless a source was requested.
    DECLARE @AttFrom DATE = DATEFROMPARTS(YEAR(DATEADD(MONTH, -2, GETDATE())), MONTH(DATEADD(MONTH, -2, GETDATE())), 1);
    IF @ACTION_SP = N'ATTENDANCE' AND @Src IN (N'hr', N'cache') AND NULLIF(@SOURCE, N'') IS NULL
    BEGIN
        IF CAST(@Day AS DATE) < @AttFrom
           OR CAST(@Day AS DATE) >= DATEFROMPARTS(YEAR(DATEADD(MONTH, 2, GETDATE())), MONTH(DATEADD(MONTH, 2, GETDATE())), 1)
            SET @Src = N'dbo';
    END
    IF @Src = N'cache' AND @ACTION_SP <> N'ATTENDANCE'
        SET @Src = N'hr';
    DECLARE @Dept NVARCHAR(250) = ISNULL(LTRIM(RTRIM(@DEPARTMENT)), N'');
    DECLARE @Sect NVARCHAR(250) = ISNULL(LTRIM(RTRIM(@SECTION)), N'');
    DECLARE @Scope NVARCHAR(MAX) = ISNULL(LTRIM(RTRIM(@SCOPE_SECTIONS)), N'');
    DECLARE @ShiftMode NVARCHAR(10) = LOWER(ISNULL(NULLIF(LTRIM(RTRIM(@SHIFT)), N''), N'all'));

    -- allowed section ids (empty table + @HasScope = 0 means unrestricted)
    DECLARE @HasScope BIT = CASE WHEN @Scope = N'' THEN 0 ELSE 1 END;
    DECLARE @ScopeIds TABLE (id INT PRIMARY KEY);
    IF @HasScope = 1
    BEGIN
        INSERT INTO @ScopeIds (id)
        SELECT DISTINCT TRY_CAST(LTRIM(RTRIM(value)) AS INT)
        FROM STRING_SPLIT(@Scope, N',')
        WHERE TRY_CAST(LTRIM(RTRIM(value)) AS INT) IS NOT NULL;
    END

    BEGIN TRY
        IF @ACTION_SP = N'ATTENDANCE'
        BEGIN
            IF @ShiftMode NOT IN (N'all', N'day', N'night')
                SET @ShiftMode = N'all';

            CREATE TABLE #att (
                id INT, department_id NVARCHAR(20), by_order INT, [date] DATETIME,
                department NVARCHAR(250), section NVARCHAR(250), total_workers INT,
                plan_day INT, actual_day INT, plan_night INT, actual_night INT,
                plan_off INT, actual_off INT, plan_cuti INT, actual_cuti INT,
                plan_sakit INT, actual_sakit INT, plan_izin INT, actual_izin INT,
                plan_alpha INT, actual_alpha_day INT, actual_alpha_night INT, actual_alpha INT,
                plan_lain_lain INT, actual_lain_lain INT, total_pola_kerja INT
            );

            IF @Src IN (N'hr', N'cache')
            BEGIN
                -- hr version of dbo.workers_attendance. #apf = one row per worker/finger match
                -- (section, plan, actual): computed below ('hr') or read from hr.attendance_ratio ('cache').
                -- The same buckets as the legacy SP are aggregated per section that has active workers.
                -- Legacy quirk kept on purpose: actual_cuti also counts plan = 'CLL'.
                DECLARE @AttDay DATE = CAST(@Day AS DATE);
                DECLARE @AttToday DATE = CAST(GETDATE() AS DATE);

                CREATE TABLE #apf ([section] INT, [plan] VARCHAR(25), actual VARCHAR(25));

                IF @Src = N'cache'
                    INSERT INTO #apf ([section], [plan], actual)
                    SELECT r.[section], r.[plan], r.actual
                    FROM hr.attendance_ratio r
                    WHERE r.by_jobsite = @Jobsite AND r.[date] = @AttDay AND r.deleted_at IS NULL;
                ELSE
                BEGIN
                    -- Port of dbo.fv_achievement_attendance_ratio for a single day, on hr tables.
                    -- Join multiplicity of the legacy function is kept on purpose (parity).

                    -- 1. active workers (dbo.v_workers_active_lite)
                    SELECT wa.nrp, wa.id_finger, wa.[section], wa.department
                    INTO #aw
                    FROM hr.v_workers_active wa
                    WHERE wa.by_jobsite = @Jobsite;

                    -- 2. roster of the day
                    SELECT rk.nrp, rk.remark
                    INTO #ar
                    FROM hr.workers_roster_kerja rk
                    WHERE rk.by_jobsite = @Jobsite AND rk.deleted_at IS NULL AND rk.[date] = @AttDay;

                    -- 3. status of the day: travel / cuti / sakit / standby / izin / cuti kerja
                    SELECT x.nrp, x.code
                    INTO #au
                    FROM (
                        SELECT t.nrp, CAST(N'T' AS NVARCHAR(10)) AS code
                        FROM hr.workers_travel t
                        WHERE t.by_jobsite = @Jobsite AND t.deleted_at IS NULL AND t.verify = N'administrator'
                          AND @AttDay BETWEEN t.start_date AND t.end_date
                        UNION ALL
                        SELECT m.nrp, N'CT'
                        FROM hr.workers_cuti_period_master m
                        LEFT JOIN hr.workers_cuti_period p
                               ON p.periode = m.id AND p.by_jobsite = m.by_jobsite
                              AND p.deleted_at IS NULL AND p.verify = N'administrator'
                        WHERE m.by_jobsite = @Jobsite AND m.deleted_at IS NULL
                          AND @AttDay BETWEEN ISNULL(p.start_date, m.start_date) AND ISNULL(p.end_date, m.end_date)
                        UNION ALL
                        SELECT s.nrp, N'S'
                        FROM (SELECT MAX(id) AS id FROM hr.workers_sickness
                              WHERE by_jobsite = @Jobsite AND deleted_at IS NULL AND ref_id IS NOT NULL
                              GROUP BY ref_id) a
                        JOIN hr.workers_sickness s ON s.id = a.id
                        WHERE s.verify = N'administrator'
                          AND @AttDay BETWEEN s.start_date AND ISNULL(s.end_date, EOMONTH(GETDATE()))
                        UNION ALL
                        SELECT sb.nrp, N'STB'
                        FROM hr.workers_standby sb
                        WHERE sb.by_jobsite = @Jobsite AND sb.deleted_at IS NULL AND sb.verify = N'administrator'
                          AND @AttDay BETWEEN sb.start_date AND sb.end_date
                        UNION ALL
                        SELECT pm.nrp, N'I'
                        FROM hr.workers_permit pm
                        WHERE pm.by_jobsite = @Jobsite AND pm.deleted_at IS NULL AND pm.verify = N'administrator'
                          AND @AttDay BETWEEN pm.start_date AND pm.end_date
                        UNION ALL
                        SELECT k.nrp, CAST(e.code AS NVARCHAR(10))
                        FROM hr.workers_cuti_kerja k
                        LEFT JOIN hr.enums e ON e.id = k.[status]
                        WHERE k.by_jobsite = @Jobsite AND k.deleted_at IS NULL AND k.verify = N'administrator'
                          AND LEN(ISNULL(k.note, N'')) = 0
                          AND @AttDay BETWEEN k.start_date AND k.end_date
                    ) x;

                    -- standby category join of the legacy function only multiplies rows
                    SELECT sb.nrp
                    INTO #asc
                    FROM hr.workers_standby sb
                    WHERE sb.by_jobsite = @Jobsite AND sb.deleted_at IS NULL AND sb.verify = N'administrator'
                      AND @AttDay BETWEEN sb.start_date AND sb.end_date;

                    -- 4. finger of the day (dbo.v_workers_finger): machine IN/OUT + OAMS + manual corrections
                    CREATE TABLE #af0 (
                        tanggal DATE, nrp VARCHAR(20), finger_in DATETIME2(3), finger_out DATETIME2(3),
                        unitjigsaw VARCHAR(100), excavator VARCHAR(100), [type] VARCHAR(100), area VARCHAR(100),
                        statusunit VARCHAR(50), hasilbugsel VARCHAR(250), kesimpulanbugsel VARCHAR(250)
                    );

                    -- first IN event of the day
                    INSERT INTO #af0 (tanggal, nrp, finger_in)
                    SELECT l.ndatetime, CAST(l.nuserid AS VARCHAR(20)),
                           MIN(DATEADD(MILLISECOND, DATEDIFF(MILLISECOND, 0, l.[time]), CAST(l.ndatetime AS DATETIME2(3))))
                    FROM hr.workers_finger_log l
                    WHERE l.by_jobsite = @Jobsite AND l.ndatetime = @AttDay AND TRY_CAST(l.ntnaevent AS INT) = 0
                    GROUP BY l.ndatetime, l.nuserid;

                    -- first OUT event; events before 12:00 belong to the previous day's shift
                    INSERT INTO #af0 (tanggal, nrp, finger_out)
                    SELECT @AttDay, CAST(l.nuserid AS VARCHAR(20)),
                           MIN(DATEADD(MILLISECOND, DATEDIFF(MILLISECOND, 0, l.[time]), CAST(l.ndatetime AS DATETIME2(3))))
                    FROM hr.workers_finger_log l
                    WHERE l.by_jobsite = @Jobsite
                      AND l.ndatetime IN (@AttDay, DATEADD(DAY, 1, @AttDay))
                      AND TRY_CAST(l.ntnaevent AS INT) = 1
                      AND CASE WHEN DATEPART(HOUR, l.[time]) < 12 THEN DATEADD(DAY, -1, l.ndatetime) ELSE l.ndatetime END = @AttDay
                    GROUP BY l.nuserid;

                    -- OAMS (carries the unit / bugsel attributes)
                    INSERT INTO #af0
                    SELECT o.tanggal, o.nrp, o.finger_in, o.finger_out, o.unitjigsaw, o.excavator, o.[type],
                           o.area, o.statusunit, o.hasilbugsel, o.kesimpulanbugsel
                    FROM hr.workers_finger_oams o
                    WHERE o.by_jobsite = @Jobsite AND o.tanggal = @AttDay;

                    -- manual corrections (verified by administrator)
                    INSERT INTO #af0 (tanggal, nrp, finger_in, finger_out)
                    SELECT fe.[date], CAST(w.id_finger AS VARCHAR(20)), MIN(fe.finger_in), MIN(fe.finger_out)
                    FROM hr.workers_finger_error fe
                    LEFT JOIN #aw w ON w.nrp = fe.nrp
                    WHERE fe.by_jobsite = @Jobsite AND fe.[date] = @AttDay AND fe.verify = N'administrator'
                    GROUP BY fe.[date], w.id_finger;

                    -- one row per (date, nrp, unit attributes), remark = D / N / A
                    SELECT f.nrp, f.fin, f.fout,
                           CASE WHEN (f.fin IS NULL OR f.fout IS NULL) AND f.tanggal <> @AttToday THEN N'A'
                                WHEN DATEPART(HOUR, f.fin) >= 15 AND DATEPART(HOUR, f.fin) <= 23 THEN N'N'
                                ELSE N'D' END AS remark
                    INTO #af
                    FROM (
                        SELECT tanggal, nrp, MAX(finger_in) AS fin, MAX(finger_out) AS fout
                        FROM (SELECT DISTINCT * FROM #af0) z
                        GROUP BY tanggal, nrp, unitjigsaw, excavator, [type], area, statusunit, hasilbugsel, kesimpulanbugsel
                    ) f;

                    -- 5. plan / actual per worker (dbo.fv_achievement_attendance_ratio)
                    SELECT w.[section],
                           CASE WHEN u.nrp IS NOT NULL THEN u.code ELSE r.remark END AS plan0,
                           f.fin, f.fout, f.remark AS frem
                    INTO #ap
                    FROM #aw w
                    LEFT JOIN #ar r ON r.nrp = w.nrp
                    LEFT JOIN #au u ON u.nrp = w.nrp
                    LEFT JOIN #asc sc ON sc.nrp = w.nrp
                    LEFT JOIN #af f ON TRY_CAST(w.id_finger AS BIGINT) = TRY_CAST(f.nrp AS BIGINT);

                    INSERT INTO #apf ([section], [plan], actual)
                    SELECT p.[section],
                           CASE WHEN h.is_holiday = 1 THEN (CASE WHEN p.frem IS NOT NULL THEN p.plan0 ELSE N'L' END)
                                ELSE p.plan0 END,
                           CASE
                               WHEN p.frem = N'TRN' THEN N'TRN'
                               WHEN (p.frem IS NULL AND p.plan0 IN (N'D', N'N'))
                                 OR (p.frem = N'' AND p.plan0 IN (N'D', N'N'))
                                 OR (p.frem IS NULL AND p.plan0 IS NULL)
                                    THEN CASE WHEN h.is_holiday = 1 THEN N'L' ELSE N'A' END
                               WHEN p.frem IS NOT NULL THEN
                                    CASE WHEN (p.fin IS NOT NULL AND p.fout IS NOT NULL AND DATEDIFF(HOUR, p.fin, p.fout) >= 5)
                                           OR (@AttDay = @AttToday AND (p.fin IS NOT NULL OR p.fout IS NOT NULL))
                                              THEN p.frem
                                         WHEN p.plan0 IN (N'N', N'D') THEN N'A'
                                         ELSE p.plan0 END
                               ELSE p.plan0
                           END
                    FROM #ap p
                    CROSS APPLY (
                        SELECT CASE WHEN EXISTS (
                                   SELECT 1 FROM hr.date_holiday dh
                                   WHERE dh.by_jobsite = @Jobsite AND dh.deleted_at IS NULL AND dh.[date] = @AttDay
                                     AND ISNULL(dh.roster, N'') = ISNULL(p.plan0, N''))
                               THEN 1 ELSE 0 END AS is_holiday
                    ) h;

                    DROP TABLE #aw, #ar, #au, #asc, #af0, #af, #ap;
                END

                INSERT INTO #att
                SELECT
                    s.id, CAST(s.ref_id AS NVARCHAR(20)), s.by_order, @Day, s.description, s.name,
                    s.id,
                    SUM(CASE WHEN r.[plan] IN (N'D', N'T') THEN 1 ELSE 0 END),
                    SUM(CASE WHEN r.actual IN (N'D', N'T') THEN 1 ELSE 0 END),
                    SUM(CASE WHEN r.[plan] = N'N' THEN 1 ELSE 0 END),
                    SUM(CASE WHEN r.actual = N'N' THEN 1 ELSE 0 END),
                    SUM(CASE WHEN r.[plan] = N'OFF' THEN 1 ELSE 0 END),
                    SUM(CASE WHEN r.actual = N'OFF' THEN 1 ELSE 0 END),
                    SUM(CASE WHEN r.[plan] IN (N'CT', N'CTN', N'CTB', N'CLL') THEN 1 ELSE 0 END),
                    SUM(CASE WHEN r.actual IN (N'CT', N'CTN', N'CTB') OR r.[plan] = N'CLL' THEN 1 ELSE 0 END),
                    SUM(CASE WHEN r.[plan] = N'S' THEN 1 ELSE 0 END),
                    SUM(CASE WHEN r.actual = N'S' THEN 1 ELSE 0 END),
                    SUM(CASE WHEN r.[plan] = N'I' THEN 1 ELSE 0 END),
                    SUM(CASE WHEN r.actual = N'I' THEN 1 ELSE 0 END),
                    0,
                    SUM(CASE WHEN r.[plan] = N'D' AND r.actual = N'A' THEN 1 ELSE 0 END),
                    SUM(CASE WHEN r.[plan] = N'N' AND r.actual = N'A' THEN 1 ELSE 0 END),
                    SUM(CASE WHEN r.actual = N'A' THEN 1 ELSE 0 END),
                    SUM(CASE WHEN r.[plan] IN (N'STB', N'TRN') THEN 1 ELSE 0 END),
                    SUM(CASE WHEN r.actual IN (N'STB', N'TRN') THEN 1 ELSE 0 END),
                    SUM(CASE WHEN r.[plan] IS NULL OR r.[plan] = N'' THEN 0 ELSE 1 END)
                FROM hr.structure s
                JOIN #apf r ON r.[section] = s.id
                WHERE s.by_jobsite = @Jobsite
                  AND s.type = N'section'
                  AND s.deleted_at IS NULL
                  AND EXISTS (SELECT 1 FROM hr.v_workers_active wa
                              WHERE wa.[section] = s.id AND wa.by_jobsite = s.by_jobsite)
                  AND (@Dept = N'' OR TRY_CAST(s.ref_id AS INT) IN (
                        SELECT TRY_CAST(LTRIM(RTRIM(value)) AS INT) FROM STRING_SPLIT(@Dept, N',')))
                  AND (@Sect = N'' OR s.id IN (
                        SELECT TRY_CAST(LTRIM(RTRIM(value)) AS INT) FROM STRING_SPLIT(@Sect, N',')))
                GROUP BY s.id, s.ref_id, s.by_order, s.description, s.name;
            END
            ELSE IF @Jobsite = 1
                INSERT INTO #att EXEC dbo.workers_attendance @Day, @Dept, @Sect;

            -- Legacy shift rule: a single shift hides the other shift's columns and
            -- counts only that shift's alpha.
            UPDATE #att SET
                plan_night = CASE WHEN @ShiftMode = N'day' THEN 0 ELSE plan_night END,
                actual_night = CASE WHEN @ShiftMode = N'day' THEN 0 ELSE actual_night END,
                plan_day = CASE WHEN @ShiftMode = N'night' THEN 0 ELSE plan_day END,
                actual_day = CASE WHEN @ShiftMode = N'night' THEN 0 ELSE actual_day END,
                actual_alpha = CASE @ShiftMode
                    WHEN N'day' THEN actual_alpha_day
                    WHEN N'night' THEN actual_alpha_night
                    ELSE actual_alpha
                END;

            -- total_workers from the dbo SP is not a headcount (it returns the section id);
            -- the real headcount comes from POLA_KERJA, so it is not exposed here.
            SELECT
                a.id, a.department_id, a.by_order, a.[date], a.department, a.section,
                a.plan_day, a.actual_day, a.plan_night, a.actual_night,
                a.plan_off, a.actual_off, a.plan_cuti, a.actual_cuti,
                a.plan_sakit, a.actual_sakit, a.plan_izin, a.actual_izin,
                a.plan_alpha, a.actual_alpha_day, a.actual_alpha_night, a.actual_alpha,
                a.plan_lain_lain, a.actual_lain_lain, a.total_pola_kerja
            FROM #att a
            WHERE @HasScope = 0 OR a.id IN (SELECT id FROM @ScopeIds)
            ORDER BY a.by_order, TRY_CAST(a.department_id AS INT), a.id;

            SELECT COUNT(*) AS total_count
            FROM #att a
            WHERE @HasScope = 0 OR a.id IN (SELECT id FROM @ScopeIds);
        END
        ELSE IF @ACTION_SP = N'POLA_KERJA'
        BEGIN
            DECLARE @FirstOfMonth DATETIME =
                DATEFROMPARTS(YEAR(@Day), MONTH(@Day), 1);

            CREATE TABLE #pola (
                id INT, department NVARCHAR(250), section NVARCHAR(250),
                total_worker INT, total_pola_kerja INT
            );

            IF @Src = N'hr'
            BEGIN
                -- hr version of dbo.dashboard_pola_kerja. Same semantics as the legacy SP:
                -- headcount per section from the active workers, "pola kerja" = workers that
                -- have a roster row on the FIRST DAY of the month. Empty filter = all sections.
                DECLARE @PolaDay DATE = CAST(@FirstOfMonth AS DATE);

                INSERT INTO #pola (id, department, section, total_worker, total_pola_kerja)
                SELECT
                    s.id, s.description, s.name, tw.total_worker, tw.total_pola_kerja
                FROM hr.structure s
                LEFT JOIN (
                    SELECT
                        wa.by_jobsite, wa.[section],
                        COUNT(*) AS total_worker,
                        SUM(CASE WHEN r.nrp IS NULL THEN 0 ELSE 1 END) AS total_pola_kerja
                    FROM hr.v_workers_active wa
                    LEFT JOIN hr.workers_roster_kerja r
                        ON r.nrp = wa.nrp
                       AND r.by_jobsite = wa.by_jobsite
                       AND r.[date] = @PolaDay
                       AND r.deleted_at IS NULL
                    WHERE wa.by_jobsite = @Jobsite
                    GROUP BY wa.by_jobsite, wa.[section]
                ) tw ON tw.[section] = s.id AND tw.by_jobsite = s.by_jobsite
                WHERE s.by_jobsite = @Jobsite
                  AND s.type = N'section'
                  AND s.deleted_at IS NULL
                  AND (@Dept = N'' OR TRY_CAST(s.ref_id AS INT) IN (
                        SELECT TRY_CAST(LTRIM(RTRIM(value)) AS INT) FROM STRING_SPLIT(@Dept, N',')))
                  AND (@Sect = N'' OR s.id IN (
                        SELECT TRY_CAST(LTRIM(RTRIM(value)) AS INT) FROM STRING_SPLIT(@Sect, N',')));
            END
            ELSE IF @Jobsite = 1
                INSERT INTO #pola EXEC dbo.dashboard_pola_kerja @FirstOfMonth, @Dept, @Sect;

            SELECT
                p.id, p.department, p.section,
                ISNULL(p.total_worker, 0) AS total_worker,
                ISNULL(p.total_pola_kerja, 0) AS total_pola_kerja,
                CAST(CASE WHEN ISNULL(p.total_worker, 0) = 0 THEN 0
                          ELSE ROUND(ISNULL(p.total_pola_kerja, 0) * 100.0 / p.total_worker, 1)
                     END AS DECIMAL(5, 1)) AS achievement
            FROM #pola p
            WHERE @HasScope = 0 OR p.id IN (SELECT id FROM @ScopeIds)
            ORDER BY p.department, p.section;

            SELECT COUNT(*) AS total_count
            FROM #pola p
            WHERE @HasScope = 0 OR p.id IN (SELECT id FROM @ScopeIds);
        END
        ELSE IF @ACTION_SP = N'UNFIT'
        BEGIN
            CREATE TABLE #unfit (
                nrp NVARCHAR(25), full_name NVARCHAR(200), [section] INT, department INT,
                section_name NVARCHAR(250), department_name NVARCHAR(250),
                reason NVARCHAR(250), start_date DATETIME2, total_hari INT
            );

            -- EXEC parameters cannot be expressions; the dbo SP takes a single id
            DECLARE @DeptId INT = TRY_CAST(NULLIF(@Dept, N'') AS INT);
            DECLARE @SectId INT = TRY_CAST(NULLIF(@Sect, N'') AS INT);

            IF @Src = N'hr'
            BEGIN
                -- hr version of dbo.DASHBOARD_EMPLOYEE_UNFIT: standby categories 336/337
                -- verified by 'administrator' that are running today, active workers only.
                -- Jobsite-aware: no "jobsite 1 only" limitation on this path.
                DECLARE @Today DATE = CAST(GETDATE() AS DATE);

                INSERT INTO #unfit
                SELECT DISTINCT
                    wa.nrp, wa.full_name, wa.[section], wa.department,
                    s.name, s.description, e.name, ws.start_date,
                    DATEDIFF(DAY, ws.start_date, GETDATE())
                FROM hr.workers_standby ws
                JOIN hr.enums e
                    ON e.id = ws.category AND e.by_jobsite = ws.by_jobsite
                JOIN hr.v_workers_active wa
                    ON wa.nrp = ws.nrp AND wa.by_jobsite = ws.by_jobsite
                JOIN hr.structure s
                    ON s.id = wa.[section] AND s.by_jobsite = wa.by_jobsite
                   AND s.type = N'section' AND s.deleted_at IS NULL
                WHERE ws.by_jobsite = @Jobsite
                  AND ws.deleted_at IS NULL
                  AND ws.category IN (336, 337)
                  AND ws.verify = N'administrator'
                  AND @Today BETWEEN ws.start_date AND ws.end_date
                  AND (@DeptId IS NULL OR wa.department = @DeptId)
                  AND (@SectId IS NULL OR wa.[section] = @SectId);
            END
            ELSE IF @Jobsite = 1
                INSERT INTO #unfit
                EXEC dbo.DASHBOARD_EMPLOYEE_UNFIT
                    @DEPARTMENT_ID = @DeptId,
                    @SECTION_ID = @SectId;

            SELECT
                u.nrp, u.full_name, u.[section], u.department,
                u.section_name, u.department_name, u.reason, u.start_date, u.total_hari
            FROM #unfit u
            WHERE @HasScope = 0 OR u.[section] IN (SELECT id FROM @ScopeIds)
            ORDER BY u.total_hari DESC, u.full_name;

            SELECT COUNT(*) AS total_count
            FROM #unfit u
            WHERE @HasScope = 0 OR u.[section] IN (SELECT id FROM @ScopeIds);
        END
        ELSE
        BEGIN
            THROW 50028, 'Unknown ACTION_SP for hr.DASHBOARD_SP.', 1;
        END
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END
GO
