-- =============================================
-- hr.FINGER_PULSE_SP (viewer + ingest)
-- Actions: SELECT | PUNCHES | PROMOTE | STATUS | PURGE
-- SELECT uses temp tables (fast person-day gabungan)
-- Run AFTER 93_finger_pulse_sp.sql (replaces procedure body)
-- =============================================

CREATE OR ALTER PROCEDURE hr.FINGER_PULSE_SP
    @ACTION_SP NVARCHAR(30),
    @DATE_FROM DATE = NULL,
    @DATE_TO DATE = NULL,
    @BY_JOBSITE INT = NULL,
    @BY_USER INT = NULL,
    @BATCH_ID UNIQUEIDENTIFIER = NULL,
    @MODE NVARCHAR(20) = NULL,
    @DATE DATE = NULL,
    @SEARCH NVARCHAR(100) = NULL,
    @SOURCE NVARCHAR(20) = NULL,
    @COMPLETENESS NVARCHAR(30) = NULL,
    @PAGE INT = NULL,
    @PAGE_SIZE INT = NULL,
    @NRP NVARCHAR(40) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT OFF;

    DECLARE @Action NVARCHAR(30) = UPPER(LTRIM(RTRIM(ISNULL(@ACTION_SP, N''))));
    DECLARE @Jobsite INT;
    DECLARE @RetainDays INT;
    DECLARE @Enabled BIT;
    DECLARE @BatchId UNIQUEIDENTIFIER = @BATCH_ID;
    DECLARE @RunMode VARCHAR(20);
    DECLARE @ShiftDate DATE;
    DECLARE @NowLocal DATETIME2 = SYSDATETIME();
    DECLARE @RunId BIGINT;
    DECLARE @Err NVARCHAR(1000);
    DECLARE @RowsIn INT = 0;
    DECLARE @RawNew INT = 0;
    DECLARE @Merged INT = 0;
    DECLARE @RowsInNo INT = 0;
    DECLARE @RawNewNo INT = 0;
    DECLARE @MergedNo INT = 0;
    DECLARE @RowsInOa INT = 0;
    DECLARE @RawNewOa INT = 0;
    DECLARE @MergedOa INT = 0;
    DECLARE @LockResult INT;
    DECLARE @StageNo INT;
    DECLARE @StageOa INT;
    DECLARE @Day DATE;
    DECLARE @Q NVARCHAR(100);
    DECLARE @Src NVARCHAR(20);
    DECLARE @Comp NVARCHAR(30);
    DECLARE @PageNum INT;
    DECLARE @PageSize INT;
    DECLARE @Offset INT;
    DECLARE @IdFinger BIGINT;

    IF @Action IN (N'PULSE', N'RECONCILE', N'BACKFILL')
        SET @Action = N'PROMOTE';

    IF @Action NOT IN (N'SELECT', N'PUNCHES', N'PROMOTE', N'STATUS', N'PURGE')
    BEGIN
        SELECT CAST(0 AS BIT) AS success, N'Unknown ACTION_SP.' AS message, CAST(NULL AS BIGINT) AS run_id;
        RETURN;
    END

    SELECT
        @Jobsite = COALESCE(@BY_JOBSITE, c.by_jobsite, 1),
        @RetainDays = c.raw_retain_days,
        @Enabled = c.enabled
    FROM hr.finger_pulse_config c
    WHERE c.id = 1;

    IF @Jobsite IS NULL SET @Jobsite = 1;
    IF @RetainDays IS NULL SET @RetainDays = 90;
    IF @Enabled IS NULL SET @Enabled = 1;

    SET @RunMode = UPPER(LTRIM(RTRIM(ISNULL(@MODE, N'BACKFILL'))));
    IF @RunMode NOT IN (N'PULSE', N'RECONCILE', N'BACKFILL', N'PURGE')
        SET @RunMode = N'BACKFILL';

    SET @ShiftDate = CAST(@NowLocal AS DATE);
    IF CAST(@NowLocal AS TIME) < CAST(N'07:30:00' AS TIME)
        SET @ShiftDate = DATEADD(DAY, -1, @ShiftDate);

    /* ---- SELECT person-day gabungan (temp tables) ---- */
    IF @Action = N'SELECT'
    BEGIN
        SET @Day = ISNULL(@DATE, @ShiftDate);
        SET @Q = NULLIF(LTRIM(RTRIM(@SEARCH)), N'');
        SET @Src = LOWER(LTRIM(RTRIM(ISNULL(@SOURCE, N'all'))));
        SET @Comp = LOWER(LTRIM(RTRIM(ISNULL(@COMPLETENESS, N'all'))));
        IF @Src NOT IN (N'all', N'machine', N'oams', N'both') SET @Src = N'all';
        IF @Comp NOT IN (N'all', N'complete', N'missing_out', N'machine_only', N'oams_only')
            SET @Comp = N'all';
        SET @PageNum = CASE WHEN ISNULL(@PAGE, 1) < 1 THEN 1 ELSE ISNULL(@PAGE, 1) END;
        SET @PageSize = CASE
            WHEN ISNULL(@PAGE_SIZE, 25) <= 0 THEN 25
            WHEN @PAGE_SIZE > 200 THEN 200
            ELSE @PAGE_SIZE
        END;
        SET @Offset = (@PageNum - 1) * @PageSize;

        IF OBJECT_ID('tempdb..#fp_machine') IS NOT NULL DROP TABLE #fp_machine;
        IF OBJECT_ID('tempdb..#fp_oams') IS NOT NULL DROP TABLE #fp_oams;
        IF OBJECT_ID('tempdb..#fp_w_finger') IS NOT NULL DROP TABLE #fp_w_finger;
        IF OBJECT_ID('tempdb..#fp_w_nrp') IS NOT NULL DROP TABLE #fp_w_nrp;
        IF OBJECT_ID('tempdb..#fp_combined') IS NOT NULL DROP TABLE #fp_combined;
        IF OBJECT_ID('tempdb..#fp_filtered') IS NOT NULL DROP TABLE #fp_filtered;

        /* Worker lookup once (avoids OUTER APPLY per punch user) */
        ;WITH ranked_finger AS (
            SELECT
                TRY_CAST(w.id_finger AS BIGINT) AS id_finger,
                LTRIM(RTRIM(w.nrp)) AS nrp,
                w.full_name,
                w.department_name,
                w.section_name,
                w.worker_source,
                ROW_NUMBER() OVER (
                    PARTITION BY TRY_CAST(w.id_finger AS BIGINT)
                    ORDER BY CASE WHEN w.worker_source = N'sis' THEN 0 ELSE 1 END, w.id
                ) AS rn
            FROM hr.v_workers_active w
            WHERE w.by_jobsite = @Jobsite
              AND TRY_CAST(w.id_finger AS BIGINT) IS NOT NULL
        )
        SELECT id_finger, nrp, full_name, department_name, section_name, worker_source
        INTO #fp_w_finger
        FROM ranked_finger
        WHERE rn = 1;

        CREATE UNIQUE CLUSTERED INDEX IX_fp_w_finger ON #fp_w_finger (id_finger);

        ;WITH ranked_nrp AS (
            SELECT
                LTRIM(RTRIM(w.nrp)) AS nrp,
                w.full_name,
                w.department_name,
                w.section_name,
                w.worker_source,
                TRY_CAST(w.id_finger AS BIGINT) AS id_finger,
                ROW_NUMBER() OVER (
                    PARTITION BY LTRIM(RTRIM(w.nrp))
                    ORDER BY CASE WHEN w.worker_source = N'sis' THEN 0 ELSE 1 END, w.id
                ) AS rn
            FROM hr.v_workers_active w
            WHERE w.by_jobsite = @Jobsite
              AND w.nrp IS NOT NULL
        )
        SELECT nrp, full_name, department_name, section_name, worker_source, id_finger
        INTO #fp_w_nrp
        FROM ranked_nrp
        WHERE rn = 1;

        CREATE UNIQUE CLUSTERED INDEX IX_fp_w_nrp ON #fp_w_nrp (nrp);

        SELECT
            l.nuserid,
            MAX(l.susername) AS susername,
            MIN(CASE
                WHEN l.ndatetime = @Day AND l.ntnaevent IN (N'0', N'00')
                THEN DATEADD(SECOND, DATEDIFF(SECOND, 0, l.[time]), CAST(l.ndatetime AS DATETIME2(0)))
            END) AS machine_in,
            MIN(CASE
                WHEN l.ntnaevent IN (N'1', N'01')
                 AND CASE
                        WHEN DATEPART(HOUR, l.[time]) < 12 THEN DATEADD(DAY, -1, l.ndatetime)
                        ELSE l.ndatetime
                     END = @Day
                THEN DATEADD(SECOND, DATEDIFF(SECOND, 0, l.[time]), CAST(l.ndatetime AS DATETIME2(0)))
            END) AS machine_out,
            SUM(CASE WHEN l.ndatetime = @Day THEN 1 ELSE 0 END) AS machine_punch_count
        INTO #fp_machine
        FROM hr.workers_finger_log l WITH (NOLOCK)
        WHERE l.by_jobsite = @Jobsite
          AND l.deleted_at IS NULL
          AND l.ndatetime IN (@Day, DATEADD(DAY, 1, @Day))
          AND (
                l.ndatetime = @Day
             OR (l.ntnaevent IN (N'1', N'01') AND DATEPART(HOUR, l.[time]) < 12)
          )
        GROUP BY l.nuserid;

        CREATE CLUSTERED INDEX IX_fp_machine_uid ON #fp_machine (nuserid);

        SELECT
            LTRIM(RTRIM(o.nrp)) AS nrp,
            o.nama,
            o.shift,
            o.finger_in AS oams_in,
            o.finger_out AS oams_out,
            o.area,
            o.unitjigsaw,
            o.excavator,
            o.[type],
            o.statusunit
        INTO #fp_oams
        FROM hr.workers_finger_oams o WITH (NOLOCK)
        WHERE o.by_jobsite = @Jobsite
          AND o.deleted_at IS NULL
          AND o.tanggal = @Day
          AND o.nrp IS NOT NULL;

        CREATE CLUSTERED INDEX IX_fp_oams_nrp ON #fp_oams (nrp);

        SELECT
            LTRIM(RTRIM(ISNULL(wf.nrp, CAST(m.nuserid AS VARCHAR(20))))) AS nrp,
            COALESCE(wf.full_name, m.susername, N'') AS full_name,
            wf.department_name,
            wf.section_name,
            wf.worker_source,
            m.nuserid AS id_finger,
            m.machine_in,
            m.machine_out,
            ISNULL(m.machine_punch_count, 0) AS machine_punch_count,
            CAST(NULL AS DATETIME2) AS oams_in,
            CAST(NULL AS DATETIME2) AS oams_out,
            CAST(NULL AS VARCHAR(100)) AS area,
            CAST(NULL AS VARCHAR(100)) AS unitjigsaw,
            CAST(NULL AS VARCHAR(100)) AS excavator,
            CAST(NULL AS VARCHAR(100)) AS [type],
            CAST(NULL AS VARCHAR(10)) AS shift,
            CAST(NULL AS VARCHAR(50)) AS statusunit,
            1 AS has_machine,
            0 AS has_oams
        INTO #fp_combined
        FROM #fp_machine m
        LEFT JOIN #fp_w_finger wf ON wf.id_finger = m.nuserid
        WHERE m.machine_punch_count > 0
           OR m.machine_in IS NOT NULL
           OR m.machine_out IS NOT NULL;

        CREATE CLUSTERED INDEX IX_fp_combined_nrp ON #fp_combined (nrp);

        UPDATE c
        SET
            c.oams_in = o.oams_in,
            c.oams_out = o.oams_out,
            c.area = o.area,
            c.unitjigsaw = o.unitjigsaw,
            c.excavator = o.excavator,
            c.[type] = o.[type],
            c.shift = o.shift,
            c.statusunit = o.statusunit,
            c.has_oams = 1,
            c.full_name = CASE
                WHEN c.full_name IS NULL OR c.full_name = N'' THEN ISNULL(o.nama, c.full_name)
                ELSE c.full_name
            END
        FROM #fp_combined c
        INNER JOIN #fp_oams o ON o.nrp = c.nrp;

        INSERT INTO #fp_combined (
            nrp, full_name, department_name, section_name, worker_source, id_finger,
            machine_in, machine_out, machine_punch_count,
            oams_in, oams_out, area, unitjigsaw, excavator, [type], shift, statusunit,
            has_machine, has_oams
        )
        SELECT
            o.nrp,
            COALESCE(wn.full_name, o.nama, N''),
            wn.department_name,
            wn.section_name,
            wn.worker_source,
            wn.id_finger,
            NULL, NULL, 0,
            o.oams_in, o.oams_out, o.area, o.unitjigsaw, o.excavator, o.[type], o.shift, o.statusunit,
            0, 1
        FROM #fp_oams o
        LEFT JOIN #fp_w_nrp wn ON wn.nrp = o.nrp
        WHERE NOT EXISTS (SELECT 1 FROM #fp_combined c WHERE c.nrp = o.nrp);

        SELECT
            c.*,
            CASE
                WHEN c.has_machine = 1 AND c.has_oams = 1
                 AND (
                    (c.machine_in IS NOT NULL AND c.oams_in IS NOT NULL
                        AND ABS(DATEDIFF(MINUTE, c.machine_in, c.oams_in)) > 5)
                 OR (c.machine_out IS NOT NULL AND c.oams_out IS NOT NULL
                        AND ABS(DATEDIFF(MINUTE, c.machine_out, c.oams_out)) > 5)
                 )
                THEN 1 ELSE 0
            END AS has_conflict,
            COALESCE(c.machine_in, c.oams_in) AS best_in,
            COALESCE(c.machine_out, c.oams_out) AS best_out
        INTO #fp_filtered
        FROM #fp_combined c
        WHERE (
                @Q IS NULL
             OR c.nrp LIKE N'%' + @Q + N'%'
             OR c.full_name LIKE N'%' + @Q + N'%'
             OR CAST(ISNULL(c.id_finger, 0) AS NVARCHAR(30)) LIKE N'%' + @Q + N'%'
          )
          AND (
                @Src = N'all'
             OR (@Src = N'machine' AND c.has_machine = 1)
             OR (@Src = N'oams' AND c.has_oams = 1)
             OR (@Src = N'both' AND c.has_machine = 1 AND c.has_oams = 1)
          )
          AND (
                @Comp = N'all'
             OR (@Comp = N'complete'
                    AND COALESCE(c.machine_in, c.oams_in) IS NOT NULL
                    AND COALESCE(c.machine_out, c.oams_out) IS NOT NULL)
             OR (@Comp = N'missing_out'
                    AND @Day < @ShiftDate
                    AND COALESCE(c.machine_in, c.oams_in) IS NOT NULL
                    AND COALESCE(c.machine_out, c.oams_out) IS NULL)
             OR (@Comp = N'machine_only' AND c.has_machine = 1 AND c.has_oams = 0)
             OR (@Comp = N'oams_only' AND c.has_oams = 1 AND c.has_machine = 0)
          );

        SELECT
            @Day AS [date],
            f.nrp,
            f.full_name,
            f.department_name,
            f.section_name,
            f.worker_source,
            f.id_finger,
            f.machine_in,
            f.machine_out,
            f.machine_punch_count,
            f.oams_in,
            f.oams_out,
            f.area,
            f.unitjigsaw,
            f.excavator,
            f.[type],
            f.shift,
            f.statusunit,
            f.has_machine,
            f.has_oams,
            f.has_conflict,
            f.best_in,
            f.best_out
        FROM #fp_filtered f
        ORDER BY
            CASE WHEN f.best_in IS NULL THEN 1 ELSE 0 END,
            f.best_in DESC,
            f.full_name,
            f.nrp
        OFFSET @Offset ROWS FETCH NEXT @PageSize ROWS ONLY;

        /* Missing OUT hanya untuk hari sebelum shift-date (hari ini belum wajib OUT). */
        SELECT
            COUNT_BIG(*) AS total_count,
            SUM(CASE WHEN has_machine = 1 THEN 1 ELSE 0 END) AS machine_count,
            SUM(CASE WHEN has_oams = 1 THEN 1 ELSE 0 END) AS oams_count,
            SUM(CASE WHEN has_machine = 1 AND has_oams = 1 THEN 1 ELSE 0 END) AS both_count,
            SUM(CASE WHEN best_in IS NOT NULL THEN 1 ELSE 0 END) AS fingered_count,
            SUM(CASE WHEN best_in IS NOT NULL AND best_out IS NOT NULL THEN 1 ELSE 0 END) AS complete_count,
            SUM(CASE
                    WHEN @Day < @ShiftDate
                     AND best_in IS NOT NULL
                     AND best_out IS NULL
                    THEN 1 ELSE 0
                END) AS missing_out_count,
            SUM(CASE WHEN best_in IS NULL THEN 1 ELSE 0 END) AS no_in_count
        FROM #fp_filtered;

        /* KPI breakdown per department / section (same filter as list) */
        SELECT
            ISNULL(NULLIF(LTRIM(RTRIM(department_name)), N''), N'(Tanpa department)') AS department_name,
            ISNULL(NULLIF(LTRIM(RTRIM(section_name)), N''), N'(Tanpa section)') AS section_name,
            COUNT_BIG(*) AS person_count,
            SUM(CASE WHEN best_in IS NOT NULL THEN 1 ELSE 0 END) AS fingered_count,
            SUM(CASE WHEN best_in IS NOT NULL AND best_out IS NOT NULL THEN 1 ELSE 0 END) AS complete_count,
            SUM(CASE
                    WHEN @Day < @ShiftDate
                     AND best_in IS NOT NULL
                     AND best_out IS NULL
                    THEN 1 ELSE 0
                END) AS missing_out_count,
            SUM(CASE WHEN best_in IS NULL THEN 1 ELSE 0 END) AS no_in_count,
            SUM(CASE WHEN has_machine = 1 THEN 1 ELSE 0 END) AS non_oams_count,
            SUM(CASE WHEN has_oams = 1 THEN 1 ELSE 0 END) AS oams_count
        FROM #fp_filtered
        GROUP BY
            ISNULL(NULLIF(LTRIM(RTRIM(department_name)), N''), N'(Tanpa department)'),
            ISNULL(NULLIF(LTRIM(RTRIM(section_name)), N''), N'(Tanpa section)')
        ORDER BY
            department_name,
            section_name;

        /* Missing OUT detail — kosong jika @Day = shift date hari ini */
        SELECT
            @Day AS [date],
            f.nrp,
            f.full_name,
            f.best_in AS finger_in,
            f.best_out AS finger_out,
            f.machine_in,
            f.oams_in,
            ISNULL(NULLIF(LTRIM(RTRIM(f.department_name)), N''), N'(Tanpa department)') AS department_name,
            ISNULL(NULLIF(LTRIM(RTRIM(f.section_name)), N''), N'(Tanpa section)') AS section_name
        FROM #fp_filtered f
        WHERE @Day < @ShiftDate
          AND f.best_in IS NOT NULL
          AND f.best_out IS NULL
        ORDER BY
            f.department_name,
            f.section_name,
            f.full_name,
            f.nrp;

        RETURN;
    END


    /* ---- PUNCHES (machine timeline) ---- */
    IF @Action = N'PUNCHES'
    BEGIN
        SET @Day = ISNULL(@DATE, @ShiftDate);
        SET @NRP = LTRIM(RTRIM(ISNULL(@NRP, N'')));
        IF @NRP = N''
        BEGIN
            SELECT CAST(0 AS BIT) AS success, N'@NRP is required.' AS message;
            RETURN;
        END

        SELECT TOP (1) @IdFinger = TRY_CAST(w.id_finger AS BIGINT)
        FROM hr.v_workers_active w
        WHERE w.by_jobsite = @Jobsite
          AND LTRIM(RTRIM(w.nrp)) = @NRP
        ORDER BY CASE WHEN w.worker_source = N'sis' THEN 0 ELSE 1 END, w.id;

        IF @IdFinger IS NULL
            SET @IdFinger = TRY_CAST(@NRP AS BIGINT);

        SELECT
            l.id,
            l.ndatetime AS [date],
            CONVERT(VARCHAR(8), l.[time], 108) AS [time],
            l.nuserid,
            l.susername,
            l.ntnaevent,
            CASE TRY_CAST(l.ntnaevent AS INT)
                WHEN 0 THEN N'IN'
                WHEN 1 THEN N'OUT'
                ELSE N'OTHER'
            END AS event_label
        FROM hr.workers_finger_log l
        WHERE l.by_jobsite = @Jobsite
          AND l.deleted_at IS NULL
          AND l.nuserid = @IdFinger
          AND (
                l.ndatetime = @Day
             OR (l.ndatetime = DATEADD(DAY, 1, @Day)
                 AND TRY_CAST(l.ntnaevent AS INT) = 1
                 AND DATEPART(HOUR, l.[time]) < 12)
          )
        ORDER BY l.ndatetime, l.[time], l.id;

        RETURN;
    END

    /* ---- STATUS ---- */
    IF @Action = N'STATUS'
    BEGIN
        SELECT
            w.stream,
            w.by_jobsite,
            w.last_success_at,
            w.last_date_from,
            w.last_date_to,
            w.last_rows_in,
            w.last_raw_new,
            w.last_merged,
            w.last_status,
            w.last_error,
            w.updated_at,
            DATEDIFF(SECOND, w.last_success_at, SYSUTCDATETIME()) AS lag_seconds
        FROM hr.finger_pulse_watermark w
        WHERE w.by_jobsite = @Jobsite
        ORDER BY w.stream;

        SELECT TOP (20)
            r.id,
            r.batch_id,
            r.mode,
            r.stream,
            r.date_from,
            r.date_to,
            r.started_at,
            r.finished_at,
            r.rows_in,
            r.raw_new,
            r.merged,
            r.status,
            r.error_message
        FROM hr.finger_pulse_run r
        WHERE r.by_jobsite = @Jobsite
        ORDER BY r.id DESC;

        SELECT
            c.linked_server,
            c.remote_database,
            c.by_jobsite,
            c.raw_retain_days,
            c.enabled,
            c.updated_at,
            (SELECT COUNT_BIG(*) FROM hr.finger_pulse_raw WHERE by_jobsite = @Jobsite) AS raw_rows
        FROM hr.finger_pulse_config c
        WHERE c.id = 1;

        RETURN;
    END

    /* ---- PURGE ---- */
    IF @Action = N'PURGE'
    BEGIN
        SET @BatchId = ISNULL(@BatchId, NEWID());
        INSERT INTO hr.finger_pulse_run (batch_id, by_jobsite, mode, status)
        VALUES (@BatchId, @Jobsite, N'PURGE', N'RUNNING');
        SET @RunId = SCOPE_IDENTITY();

        BEGIN TRY
            DELETE FROM hr.finger_pulse_raw
            WHERE by_jobsite = @Jobsite
              AND pulled_at < DATEADD(DAY, -@RetainDays, SYSUTCDATETIME());

            SET @Merged = @@ROWCOUNT;

            UPDATE hr.finger_pulse_run
            SET finished_at = SYSUTCDATETIME(),
                merged = @Merged,
                status = N'SUCCESS'
            WHERE id = @RunId;

            SELECT CAST(1 AS BIT) AS success,
                   N'Purged raw rows older than retain window.' AS message,
                   @RunId AS run_id,
                   @Merged AS purged_rows;
        END TRY
        BEGIN CATCH
            SET @Err = LEFT(ERROR_MESSAGE(), 1000);
            UPDATE hr.finger_pulse_run
            SET finished_at = SYSUTCDATETIME(), status = N'FAILED', error_message = @Err
            WHERE id = @RunId;
            SELECT CAST(0 AS BIT) AS success, @Err AS message, @RunId AS run_id;
        END CATCH
        RETURN;
    END

    /* ---- PROMOTE (stage → raw → canonical) ---- */
    IF @Enabled = 0
    BEGIN
        SELECT CAST(0 AS BIT) AS success,
               N'Finger Pulse is disabled in hr.finger_pulse_config.' AS message,
               CAST(NULL AS BIGINT) AS run_id;
        RETURN;
    END

    IF @BatchId IS NULL
    BEGIN
        SELECT CAST(0 AS BIT) AS success,
               N'PROMOTE requires @BATCH_ID. Use: node scripts/hr/run_finger_pulse.js pulse|reconcile|backfill' AS message,
               CAST(NULL AS BIGINT) AS run_id;
        RETURN;
    END

    SET @ShiftDate = CAST(@NowLocal AS DATE);
    IF CAST(@NowLocal AS TIME) < CAST(N'07:30:00' AS TIME)
        SET @ShiftDate = DATEADD(DAY, -1, @ShiftDate);

    IF @DATE_FROM IS NULL SET @DATE_FROM = @ShiftDate;
    IF @DATE_TO IS NULL SET @DATE_TO = @DATE_FROM;

    SELECT @StageNo = COUNT(*) FROM hr.finger_pulse_stage_non_oams WHERE batch_id = @BatchId;
    SELECT @StageOa = COUNT(*) FROM hr.finger_pulse_stage_oams WHERE batch_id = @BatchId;

    IF @StageNo = 0 AND @StageOa = 0
    BEGIN
        SELECT CAST(0 AS BIT) AS success,
               N'No staged rows for @BATCH_ID. Run the Node puller first (run_finger_pulse.js).' AS message,
               CAST(NULL AS BIGINT) AS run_id;
        RETURN;
    END

    EXEC @LockResult = sp_getapplock
        @Resource = N'hr.finger_pulse.ingest',
        @LockMode = N'Exclusive',
        @LockOwner = N'Session',
        @LockTimeout = 60000;

    IF @LockResult < 0
    BEGIN
        SELECT CAST(0 AS BIT) AS success,
               N'Could not acquire finger_pulse ingest lock (another run in progress).' AS message,
               CAST(NULL AS BIGINT) AS run_id;
        RETURN;
    END

    INSERT INTO hr.finger_pulse_run (
        batch_id, by_jobsite, mode, date_from, date_to, status
    )
    VALUES (@BatchId, @Jobsite, @RunMode, @DATE_FROM, @DATE_TO, N'RUNNING');
    SET @RunId = SCOPE_IDENTITY();

    BEGIN TRY
        IF NOT EXISTS (
            SELECT 1 FROM hr.finger_pulse_watermark
            WHERE by_jobsite = @Jobsite AND stream = N'non_oams'
        )
            INSERT INTO hr.finger_pulse_watermark (stream, by_jobsite)
            VALUES (N'non_oams', @Jobsite);
        IF NOT EXISTS (
            SELECT 1 FROM hr.finger_pulse_watermark
            WHERE by_jobsite = @Jobsite AND stream = N'oams'
        )
            INSERT INTO hr.finger_pulse_watermark (stream, by_jobsite)
            VALUES (N'oams', @Jobsite);

        SET @RowsInNo = @StageNo;
        SET @RowsInOa = @StageOa;

        /* non_oams → raw */
        ;WITH mapped AS (
            SELECT
                @Jobsite AS by_jobsite,
                s.batch_id,
                CAST(N'non_oams' AS VARCHAR(20)) AS stream,
                SYSUTCDATETIME() AS pulled_at,
                @DATE_FROM AS date_from,
                @DATE_TO AS date_to,
                HASHBYTES(
                    N'SHA2_256',
                    CONCAT(
                        N'non_oams|',
                        CAST(ISNULL(s.nEventLogIdn, 0) AS NVARCHAR(30)),
                        N'|',
                        ISNULL(s.SERVER_NAME, N'')
                    )
                ) AS content_hash,
                s.nEventLogIdn AS neventlogidn,
                LEFT(s.SERVER_NAME, 50) AS server_name,
                CAST(s.nDateTime AS DATE) AS ndatetime,
                TRY_CONVERT(TIME(0), s.[TIME]) AS [time],
                LEFT(s.IP_ADDRESS, 50) AS sip,
                LEFT(s.sIP, 50) AS id_mesin,
                s.nUserID AS nuserid,
                LEFT(s.nUserName, 250) AS susername,
                LEFT(CAST(s.nTnaEvent AS VARCHAR(10)), 10) AS ntnaevent
            FROM hr.finger_pulse_stage_non_oams s
            WHERE s.batch_id = @BatchId
              AND s.nUserID IS NOT NULL
              AND s.nDateTime IS NOT NULL
              AND TRY_CONVERT(TIME(0), s.[TIME]) IS NOT NULL
        )
        INSERT INTO hr.finger_pulse_raw (
            by_jobsite, batch_id, stream, pulled_at, date_from, date_to, content_hash,
            neventlogidn, server_name, ndatetime, [time], sip, id_mesin,
            nuserid, susername, ntnaevent
        )
        SELECT
            m.by_jobsite, m.batch_id, m.stream, m.pulled_at, m.date_from, m.date_to, m.content_hash,
            m.neventlogidn, m.server_name, m.ndatetime, m.[time], m.sip, m.id_mesin,
            m.nuserid, m.susername, m.ntnaevent
        FROM mapped m
        WHERE NOT EXISTS (
            SELECT 1
            FROM hr.finger_pulse_raw r
            WHERE r.by_jobsite = m.by_jobsite
              AND r.stream = m.stream
              AND r.content_hash = m.content_hash
        );

        SET @RawNewNo = @@ROWCOUNT;

        INSERT INTO hr.workers_finger_log (
            by_jobsite, ndatetime, [time], nuserid, susername, ntnaevent, created_at
        )
        SELECT
            r.by_jobsite,
            r.ndatetime,
            r.[time],
            r.nuserid,
            r.susername,
            r.ntnaevent,
            SYSUTCDATETIME()
        FROM hr.finger_pulse_raw r
        WHERE r.batch_id = @BatchId
          AND r.stream = N'non_oams'
          AND r.nuserid IS NOT NULL
          AND r.ndatetime IS NOT NULL
          AND r.[time] IS NOT NULL
          AND NOT EXISTS (
              SELECT 1
              FROM hr.workers_finger_log l
              WHERE l.deleted_at IS NULL
                AND l.by_jobsite = r.by_jobsite
                AND l.nuserid = r.nuserid
                AND l.ndatetime = r.ndatetime
                AND l.[time] = r.[time]
                AND ISNULL(l.ntnaevent, N'') = ISNULL(r.ntnaevent, N'')
          );

        SET @MergedNo = @@ROWCOUNT;

        /* oams → raw (legacy filter: FINGER_IN + AREA) */
        ;WITH mapped_o AS (
            SELECT
                @Jobsite AS by_jobsite,
                s.batch_id,
                CAST(N'oams' AS VARCHAR(20)) AS stream,
                SYSUTCDATETIME() AS pulled_at,
                @DATE_FROM AS date_from,
                @DATE_TO AS date_to,
                HASHBYTES(
                    N'SHA2_256',
                    CONCAT(
                        N'oams|',
                        CONVERT(VARCHAR(10), s.TANGGAL, 23), N'|',
                        ISNULL(LTRIM(RTRIM(s.NRP)), N''), N'|',
                        CONVERT(VARCHAR(30), s.FINGER_IN, 126), N'|',
                        CONVERT(VARCHAR(30), s.FINGER_OUT, 126), N'|',
                        ISNULL(s.AREA, N''), N'|',
                        ISNULL(s.shift, N''), N'|',
                        ISNULL(s.UnitJigsaw, N''), N'|',
                        ISNULL(s.Excavator, N''), N'|',
                        ISNULL(s.[Type], N''), N'|',
                        ISNULL(s.STATUS_UNIT, N''), N'|',
                        ISNULL(s.HASIL_BUGSEL, N''), N'|',
                        ISNULL(s.KESIMPULAN_BUGSEL, N'')
                    )
                ) AS content_hash,
                s.TANGGAL AS tanggal,
                LEFT(LTRIM(RTRIM(s.NRP)), 20) AS nrp,
                TRY_CONVERT(INT, LTRIM(RTRIM(s.NRP))) AS nrp_int,
                LEFT(LTRIM(RTRIM(s.NAMA)), 250) AS nama,
                LEFT(s.shift, 10) AS shift,
                CAST(s.FINGER_IN AS DATETIME2) AS finger_in,
                CAST(s.FINGER_OUT AS DATETIME2) AS finger_out,
                LEFT(s.UnitJigsaw, 100) AS unitjigsaw,
                LEFT(s.Excavator, 100) AS excavator,
                LEFT(s.[Type], 100) AS [type],
                LEFT(s.AREA, 100) AS area,
                LEFT(s.STATUS_UNIT, 50) AS statusunit,
                LEFT(s.HASIL_BUGSEL, 250) AS hasilbugsel,
                LEFT(s.KESIMPULAN_BUGSEL, 250) AS kesimpulanbugsel
            FROM hr.finger_pulse_stage_oams s
            WHERE s.batch_id = @BatchId
              AND s.FINGER_IN IS NOT NULL
              AND s.AREA IS NOT NULL
              AND LTRIM(RTRIM(ISNULL(s.NRP, N''))) <> N''
              AND s.TANGGAL IS NOT NULL
        )
        INSERT INTO hr.finger_pulse_raw (
            by_jobsite, batch_id, stream, pulled_at, date_from, date_to, content_hash,
            tanggal, nrp, nrp_int, nama, shift, finger_in, finger_out,
            unitjigsaw, excavator, [type], area, statusunit, hasilbugsel, kesimpulanbugsel
        )
        SELECT
            m.by_jobsite, m.batch_id, m.stream, m.pulled_at, m.date_from, m.date_to, m.content_hash,
            m.tanggal, m.nrp, m.nrp_int, m.nama, m.shift, m.finger_in, m.finger_out,
            m.unitjigsaw, m.excavator, m.[type], m.area, m.statusunit, m.hasilbugsel, m.kesimpulanbugsel
        FROM mapped_o m
        WHERE NOT EXISTS (
            SELECT 1
            FROM hr.finger_pulse_raw r
            WHERE r.by_jobsite = m.by_jobsite
              AND r.stream = m.stream
              AND r.content_hash = m.content_hash
        );

        SET @RawNewOa = @@ROWCOUNT;

        ;WITH latest AS (
            SELECT
                r.*,
                ROW_NUMBER() OVER (
                    PARTITION BY r.by_jobsite, r.nrp, r.tanggal
                    ORDER BY r.id DESC
                ) AS rn
            FROM hr.finger_pulse_raw r
            WHERE r.batch_id = @BatchId
              AND r.stream = N'oams'
              AND r.nrp IS NOT NULL
              AND r.tanggal IS NOT NULL
        )
        MERGE hr.workers_finger_oams AS tgt
        USING (
            SELECT * FROM latest WHERE rn = 1
        ) AS src
        ON tgt.deleted_at IS NULL
           AND tgt.by_jobsite = src.by_jobsite
           AND tgt.nrp = src.nrp
           AND tgt.tanggal = src.tanggal
        WHEN MATCHED AND (
               ISNULL(CONVERT(VARCHAR(30), tgt.finger_in, 126), N'')
                 <> ISNULL(CONVERT(VARCHAR(30), src.finger_in, 126), N'')
            OR ISNULL(CONVERT(VARCHAR(30), tgt.finger_out, 126), N'')
                 <> ISNULL(CONVERT(VARCHAR(30), src.finger_out, 126), N'')
            OR ISNULL(tgt.nama, N'') <> ISNULL(src.nama, N'')
            OR ISNULL(tgt.shift, N'') <> ISNULL(src.shift, N'')
            OR ISNULL(tgt.unitjigsaw, N'') <> ISNULL(src.unitjigsaw, N'')
            OR ISNULL(tgt.excavator, N'') <> ISNULL(src.excavator, N'')
            OR ISNULL(tgt.[type], N'') <> ISNULL(src.[type], N'')
            OR ISNULL(tgt.area, N'') <> ISNULL(src.area, N'')
            OR ISNULL(tgt.statusunit, N'') <> ISNULL(src.statusunit, N'')
            OR ISNULL(tgt.hasilbugsel, N'') <> ISNULL(src.hasilbugsel, N'')
            OR ISNULL(tgt.kesimpulanbugsel, N'') <> ISNULL(src.kesimpulanbugsel, N'')
            OR ISNULL(tgt.nrp_int, -1) <> ISNULL(src.nrp_int, -1)
        )
        THEN UPDATE SET
            tgt.nrp_int = src.nrp_int,
            tgt.nama = src.nama,
            tgt.shift = src.shift,
            tgt.finger_in = src.finger_in,
            tgt.finger_out = src.finger_out,
            tgt.unitjigsaw = src.unitjigsaw,
            tgt.excavator = src.excavator,
            tgt.[type] = src.[type],
            tgt.area = src.area,
            tgt.statusunit = src.statusunit,
            tgt.hasilbugsel = src.hasilbugsel,
            tgt.kesimpulanbugsel = src.kesimpulanbugsel,
            tgt.updated_at = SYSUTCDATETIME(),
            tgt.updated_by = @BY_USER
        WHEN NOT MATCHED BY TARGET THEN
        INSERT (
            by_jobsite, tanggal, nrp, nrp_int, nama, shift,
            finger_in, finger_out, unitjigsaw, excavator, [type], area,
            statusunit, hasilbugsel, kesimpulanbugsel, created_at, created_by
        )
        VALUES (
            src.by_jobsite, src.tanggal, src.nrp, src.nrp_int, src.nama, src.shift,
            src.finger_in, src.finger_out, src.unitjigsaw, src.excavator, src.[type], src.area,
            src.statusunit, src.hasilbugsel, src.kesimpulanbugsel, SYSUTCDATETIME(), @BY_USER
        );

        SET @MergedOa = @@ROWCOUNT;

        DELETE FROM hr.finger_pulse_stage_non_oams WHERE batch_id = @BatchId;
        DELETE FROM hr.finger_pulse_stage_oams WHERE batch_id = @BatchId;

        SET @RowsIn = @RowsInNo + @RowsInOa;
        SET @RawNew = @RawNewNo + @RawNewOa;
        SET @Merged = @MergedNo + @MergedOa;

        UPDATE hr.finger_pulse_watermark
        SET last_success_at = SYSUTCDATETIME(),
            last_date_from = @DATE_FROM,
            last_date_to = @DATE_TO,
            last_rows_in = @RowsInNo,
            last_raw_new = @RawNewNo,
            last_merged = @MergedNo,
            last_status = N'SUCCESS',
            last_error = NULL,
            updated_at = SYSUTCDATETIME()
        WHERE by_jobsite = @Jobsite AND stream = N'non_oams';

        UPDATE hr.finger_pulse_watermark
        SET last_success_at = SYSUTCDATETIME(),
            last_date_from = @DATE_FROM,
            last_date_to = @DATE_TO,
            last_rows_in = @RowsInOa,
            last_raw_new = @RawNewOa,
            last_merged = @MergedOa,
            last_status = N'SUCCESS',
            last_error = NULL,
            updated_at = SYSUTCDATETIME()
        WHERE by_jobsite = @Jobsite AND stream = N'oams';

        UPDATE hr.finger_pulse_run
        SET finished_at = SYSUTCDATETIME(),
            rows_in = @RowsIn,
            raw_new = @RawNew,
            merged = @Merged,
            status = N'SUCCESS'
        WHERE id = @RunId;

        EXEC sp_releaseapplock @Resource = N'hr.finger_pulse.ingest', @LockOwner = N'Session';

        SELECT CAST(1 AS BIT) AS success,
               N'Finger Pulse PROMOTE completed.' AS message,
               @RunId AS run_id,
               @BatchId AS batch_id,
               @DATE_FROM AS date_from,
               @DATE_TO AS date_to,
               @RowsIn AS rows_in,
               @RawNew AS raw_new,
               @Merged AS merged,
               @RowsInNo AS rows_in_non_oams,
               @RawNewNo AS raw_new_non_oams,
               @MergedNo AS merged_non_oams,
               @RowsInOa AS rows_in_oams,
               @RawNewOa AS raw_new_oams,
               @MergedOa AS merged_oams;
    END TRY
    BEGIN CATCH
        SET @Err = LEFT(ERROR_MESSAGE(), 1000);

        UPDATE hr.finger_pulse_run
        SET finished_at = SYSUTCDATETIME(),
            status = N'FAILED',
            error_message = @Err,
            rows_in = @RowsInNo + @RowsInOa,
            raw_new = @RawNewNo + @RawNewOa,
            merged = @MergedNo + @MergedOa
        WHERE id = @RunId;

        UPDATE hr.finger_pulse_watermark
        SET last_status = N'FAILED',
            last_error = @Err,
            updated_at = SYSUTCDATETIME()
        WHERE by_jobsite = @Jobsite;

        BEGIN TRY
            EXEC sp_releaseapplock @Resource = N'hr.finger_pulse.ingest', @LockOwner = N'Session';
        END TRY
        BEGIN CATCH
        END CATCH

        SELECT CAST(0 AS BIT) AS success, @Err AS message, @RunId AS run_id;
    END CATCH
END
GO

