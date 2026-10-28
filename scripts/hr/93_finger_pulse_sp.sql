-- =============================================
-- hr.FINGER_PULSE_SP
-- Actions: PROMOTE | STATUS | PURGE
--   (+ PULSE/RECONCILE/BACKFILL aliases → same as PROMOTE when @BATCH_ID set)
--
-- Pull path (no MSDTC): Node runner EXEC remote Biostar SPs → bulk stage tables
--   → EXEC hr.FINGER_PULSE_SP @ACTION_SP=N'PROMOTE', @BATCH_ID=...
-- Linked-server INSERT…EXEC inside SQL is intentionally avoided (DTC / MI).
-- Run AFTER 92_finger_pulse.sql
-- =============================================

CREATE OR ALTER PROCEDURE hr.FINGER_PULSE_SP
    @ACTION_SP NVARCHAR(30),
    @DATE_FROM DATE = NULL,
    @DATE_TO DATE = NULL,
    @BY_JOBSITE INT = NULL,
    @BY_USER INT = NULL,
    @BATCH_ID UNIQUEIDENTIFIER = NULL,
    @MODE NVARCHAR(20) = NULL
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

    IF @Action IN (N'PULSE', N'RECONCILE', N'BACKFILL')
        SET @Action = N'PROMOTE';

    IF @Action NOT IN (N'PROMOTE', N'STATUS', N'PURGE')
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
