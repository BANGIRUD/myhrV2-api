-- =============================================
-- hr.ACTIVITY_LOG_SP
-- Actions: INSERT | SELECT | ROTATE
-- Hot table hr.activity_log; on ROTATE rename to archive + recreate hot.
-- No PURGE — history is kept in archive tables listed in registry.
-- Run AFTER 78_activity_log.sql
-- =============================================

CREATE OR ALTER PROCEDURE hr.activity_log_do_rotate
    @ArchiveTable SYSNAME = NULL OUTPUT,
    @ErrorMessage NVARCHAR(4000) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @LockResult INT;
    DECLARE @ArchiveName SYSNAME;
    DECLARE @Suffix NVARCHAR(20);
    DECLARE @Sql NVARCHAR(MAX);
    DECLARE @n INT;
    DECLARE @PkNew SYSNAME;
    DECLARE @DfNew SYSNAME;
    DECLARE @CheckName NVARCHAR(260);

    SET @ArchiveTable = NULL;
    SET @ErrorMessage = NULL;

    EXEC @LockResult = sp_getapplock
        @Resource = N'hr.activity_log.rotate',
        @LockMode = N'Exclusive',
        @LockOwner = N'Session',
        @LockTimeout = 10000;

    IF @LockResult < 0
    BEGIN
        SET @ErrorMessage = N'Could not acquire activity_log rotate lock.';
        RETURN;
    END

    BEGIN TRY
        IF OBJECT_ID(N'hr.activity_log', N'U') IS NULL
        BEGIN
            SET @ErrorMessage = N'Hot table hr.activity_log is missing.';
            EXEC sp_releaseapplock @Resource = N'hr.activity_log.rotate', @LockOwner = N'Session';
            RETURN;
        END

        SET @Suffix = CONVERT(CHAR(8), SYSUTCDATETIME(), 112);
        SET @ArchiveName = N'activity_log_' + @Suffix;

        IF OBJECT_ID(N'hr.' + @ArchiveName, N'U') IS NOT NULL
        BEGIN
            SET @n = 2;
            SET @CheckName = N'hr.' + @ArchiveName + N'_' + CAST(@n AS NVARCHAR(10));
            WHILE OBJECT_ID(@CheckName, N'U') IS NOT NULL
            BEGIN
                SET @n = @n + 1;
                SET @CheckName = N'hr.' + @ArchiveName + N'_' + CAST(@n AS NVARCHAR(10));
            END
            SET @ArchiveName = @ArchiveName + N'_' + CAST(@n AS NVARCHAR(10));
        END

        SET @PkNew = @ArchiveName + N'_pk';
        SET @DfNew = @ArchiveName + N'_df_created';

        IF OBJECT_ID(N'hr.PK_hr_activity_log', N'PK') IS NOT NULL
            EXEC sp_rename N'hr.PK_hr_activity_log', @PkNew, N'OBJECT';
        IF OBJECT_ID(N'hr.DF_hr_activity_log_created_at', N'D') IS NOT NULL
            EXEC sp_rename N'hr.DF_hr_activity_log_created_at', @DfNew, N'OBJECT';

        EXEC sp_rename N'hr.activity_log', @ArchiveName;

        UPDATE hr.activity_log_registry
        SET table_name = @ArchiveName,
            is_current = 0,
            ended_at = SYSUTCDATETIME()
        WHERE table_name = N'activity_log';

        SET @Sql = N'UPDATE hr.activity_log_registry SET approx_rows = (SELECT COUNT_BIG(*) FROM hr.'
            + QUOTENAME(@ArchiveName) + N') WHERE table_name = @name';
        EXEC sp_executesql @Sql, N'@name SYSNAME', @name = @ArchiveName;

        CREATE TABLE hr.activity_log (
            id BIGINT IDENTITY(1,1) NOT NULL,
            by_jobsite INT NOT NULL,
            module NVARCHAR(50) NOT NULL,
            action NVARCHAR(30) NOT NULL,
            record_id BIGINT NULL,
            record_key NVARCHAR(100) NULL,
            actor_user_id INT NULL,
            message NVARCHAR(300) NULL,
            created_at DATETIME2 NOT NULL
                CONSTRAINT DF_hr_activity_log_created_at DEFAULT (SYSUTCDATETIME()),
            CONSTRAINT PK_hr_activity_log PRIMARY KEY NONCLUSTERED (id)
        );

        CREATE CLUSTERED INDEX IX_hr_activity_log_jobsite_created
            ON hr.activity_log (by_jobsite, created_at DESC, id DESC);
        CREATE NONCLUSTERED INDEX IX_hr_activity_log_module_record
            ON hr.activity_log (by_jobsite, module, record_id);
        CREATE NONCLUSTERED INDEX IX_hr_activity_log_actor
            ON hr.activity_log (by_jobsite, actor_user_id, created_at DESC);

        IF NOT EXISTS (SELECT 1 FROM hr.activity_log_registry WHERE table_name = N'activity_log')
        BEGIN
            INSERT INTO hr.activity_log_registry (table_name, is_current, approx_rows, started_at, ended_at)
            VALUES (N'activity_log', 1, 0, SYSUTCDATETIME(), NULL);
        END
        ELSE
        BEGIN
            UPDATE hr.activity_log_registry
            SET is_current = 1,
                approx_rows = 0,
                started_at = SYSUTCDATETIME(),
                ended_at = NULL
            WHERE table_name = N'activity_log';
        END

        SET @ArchiveTable = @ArchiveName;
        EXEC sp_releaseapplock @Resource = N'hr.activity_log.rotate', @LockOwner = N'Session';
    END TRY
    BEGIN CATCH
        SET @ErrorMessage = ERROR_MESSAGE();
        BEGIN TRY
            EXEC sp_releaseapplock @Resource = N'hr.activity_log.rotate', @LockOwner = N'Session';
        END TRY
        BEGIN CATCH
        END CATCH
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE hr.ACTIVITY_LOG_SP
    @ACTION_SP NVARCHAR(30) = NULL,
    @MODULE NVARCHAR(50) = NULL,
    @ACTION NVARCHAR(30) = NULL,
    @RECORD_ID BIGINT = NULL,
    @RECORD_KEY NVARCHAR(100) = NULL,
    @MESSAGE NVARCHAR(300) = NULL,
    @DATE_FROM DATETIME2 = NULL,
    @DATE_TO DATETIME2 = NULL,
    @SEARCH NVARCHAR(150) = NULL,
    @ACTOR_USER_ID INT = NULL,
    @PAGE INT = NULL,
    @PAGE_SIZE INT = NULL,
    @KEEP_ROWS BIGINT = NULL,
    @BY_USER INT = NULL,
    @BY_JOBSITE INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Jobsite INT = ISNULL(@BY_JOBSITE, 1);
    DECLARE @Threshold BIGINT = ISNULL(@KEEP_ROWS, 500000);
    DECLARE @Approx BIGINT;
    DECLARE @Sql NVARCHAR(MAX);
    DECLARE @PageNum INT = CASE WHEN ISNULL(@PAGE, 1) < 1 THEN 1 ELSE ISNULL(@PAGE, 1) END;
    DECLARE @PageSize INT = ISNULL(@PAGE_SIZE, 50);
    DECLARE @Offset INT;
    DECLARE @ArchiveName SYSNAME;
    DECLARE @RotateErr NVARCHAR(4000);

    IF @PageSize < 0 SET @PageSize = 0;
    IF @PageSize > 500 SET @PageSize = 500;
    SET @Offset = (@PageNum - 1) * CASE WHEN @PageSize = 0 THEN 0 ELSE @PageSize END;

    BEGIN TRY
        IF @ACTION_SP = N'ROTATE'
        BEGIN
            EXEC hr.activity_log_do_rotate
                @ArchiveTable = @ArchiveName OUTPUT,
                @ErrorMessage = @RotateErr OUTPUT;

            IF @RotateErr IS NOT NULL
            BEGIN
                SELECT CAST(0 AS BIT) AS success, @RotateErr AS message;
                RETURN;
            END

            SELECT CAST(1 AS BIT) AS success,
                   N'Rotated activity_log to ' + ISNULL(@ArchiveName, N'?') AS message,
                   @ArchiveName AS archive_table;
            RETURN;
        END

        IF @ACTION_SP = N'INSERT'
        BEGIN
            IF @MODULE IS NULL OR LTRIM(RTRIM(@MODULE)) = N''
               OR @ACTION IS NULL OR LTRIM(RTRIM(@ACTION)) = N''
            BEGIN
                SELECT CAST(0 AS BIT) AS success, N'module and action are required.' AS message;
                RETURN;
            END

            IF OBJECT_ID(N'hr.activity_log', N'U') IS NULL
            BEGIN
                SELECT CAST(0 AS BIT) AS success, N'Hot table hr.activity_log is missing. Run script 78.' AS message;
                RETURN;
            END

            SELECT @Approx = approx_rows
            FROM hr.activity_log_registry
            WHERE is_current = 1 AND table_name = N'activity_log';

            IF @Approx IS NULL SET @Approx = 0;

            IF @Approx >= @Threshold
            BEGIN
                BEGIN TRY
                    EXEC hr.activity_log_do_rotate
                        @ArchiveTable = @ArchiveName OUTPUT,
                        @ErrorMessage = @RotateErr OUTPUT;
                END TRY
                BEGIN CATCH
                END CATCH
            END

            INSERT INTO hr.activity_log (
                by_jobsite, module, action, record_id, record_key, actor_user_id, message
            )
            VALUES (
                @Jobsite,
                LEFT(LTRIM(RTRIM(@MODULE)), 50),
                LEFT(LTRIM(RTRIM(@ACTION)), 30),
                @RECORD_ID,
                NULLIF(LEFT(LTRIM(RTRIM(@RECORD_KEY)), 100), N''),
                COALESCE(@ACTOR_USER_ID, @BY_USER),
                NULLIF(LEFT(LTRIM(RTRIM(@MESSAGE)), 300), N'')
            );

            UPDATE hr.activity_log_registry
            SET approx_rows = approx_rows + 1
            WHERE is_current = 1 AND table_name = N'activity_log';

            SELECT CAST(1 AS BIT) AS success,
                   N'Logged.' AS message,
                   CAST(SCOPE_IDENTITY() AS BIGINT) AS id;
            RETURN;
        END

        IF @ACTION_SP = N'SELECT'
        BEGIN
            DECLARE @FromDt DATETIME2 = ISNULL(@DATE_FROM, DATEADD(DAY, -90, SYSUTCDATETIME()));
            DECLARE @ToDt DATETIME2 = ISNULL(@DATE_TO, SYSUTCDATETIME());
            DECLARE @Mod NVARCHAR(50) = NULLIF(LTRIM(RTRIM(@MODULE)), N'');
            DECLARE @Act NVARCHAR(30) = NULLIF(LTRIM(RTRIM(@ACTION)), N'');
            DECLARE @Q NVARCHAR(150) = NULLIF(LTRIM(RTRIM(@SEARCH)), N'');
            DECLARE @Actor INT = @ACTOR_USER_ID;
            DECLARE @Parts NVARCHAR(MAX) = N'';
            DECLARE @Name SYSNAME;
            DECLARE @Started DATETIME2;
            DECLARE @Ended DATETIME2;

            DECLARE shard_cur CURSOR LOCAL FAST_FORWARD FOR
                SELECT table_name, started_at, ended_at
                FROM hr.activity_log_registry
                WHERE started_at <= @ToDt
                  AND (ended_at IS NULL OR ended_at >= @FromDt)
                ORDER BY started_at DESC;

            OPEN shard_cur;
            FETCH NEXT FROM shard_cur INTO @Name, @Started, @Ended;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                IF OBJECT_ID(N'hr.' + @Name, N'U') IS NOT NULL
                BEGIN
                    IF LEN(@Parts) > 0 SET @Parts += N' UNION ALL ';
                    SET @Parts += N'
                        SELECT
                            l.id,
                            l.by_jobsite,
                            l.module,
                            l.action,
                            l.record_id,
                            l.record_key,
                            l.actor_user_id,
                            u.username AS actor_username,
                            u.full_name AS actor_full_name,
                            l.message,
                            l.created_at,
                            N''' + REPLACE(@Name, N'''', N'''''') + N''' AS shard_table
                        FROM hr.' + QUOTENAME(@Name) + N' l
                        LEFT JOIN hr.users u ON u.id = l.actor_user_id
                        WHERE l.by_jobsite = @Jobsite
                          AND l.created_at >= @FromDt
                          AND l.created_at <= @ToDt
                          AND (@Mod IS NULL OR l.module = @Mod)
                          AND (@Act IS NULL OR l.action = @Act)
                          AND (@Actor IS NULL OR l.actor_user_id = @Actor)
                          AND (
                                @Q IS NULL
                             OR l.message LIKE N''%'' + @Q + N''%''
                             OR l.record_key LIKE N''%'' + @Q + N''%''
                             OR l.module LIKE N''%'' + @Q + N''%''
                             OR l.action LIKE N''%'' + @Q + N''%''
                          )';
                END
                FETCH NEXT FROM shard_cur INTO @Name, @Started, @Ended;
            END
            CLOSE shard_cur;
            DEALLOCATE shard_cur;

            IF @Parts IS NULL OR @Parts = N''
            BEGIN
                SELECT TOP 0
                    CAST(NULL AS BIGINT) AS id,
                    CAST(NULL AS INT) AS by_jobsite,
                    CAST(NULL AS NVARCHAR(50)) AS module,
                    CAST(NULL AS NVARCHAR(30)) AS action,
                    CAST(NULL AS BIGINT) AS record_id,
                    CAST(NULL AS NVARCHAR(100)) AS record_key,
                    CAST(NULL AS INT) AS actor_user_id,
                    CAST(NULL AS NVARCHAR(50)) AS actor_username,
                    CAST(NULL AS NVARCHAR(150)) AS actor_full_name,
                    CAST(NULL AS NVARCHAR(300)) AS message,
                    CAST(NULL AS DATETIME2) AS created_at,
                    CAST(NULL AS NVARCHAR(128)) AS shard_table;
                SELECT CAST(0 AS INT) AS total_count;
                RETURN;
            END

            SET @Sql = N'
                ;WITH combined AS (
                    ' + @Parts + N'
                )
                SELECT *
                FROM combined
                ORDER BY created_at DESC, id DESC
                ' + CASE
                        WHEN @PageSize = 0 THEN N''
                        ELSE N' OFFSET ' + CAST(@Offset AS NVARCHAR(20))
                             + N' ROWS FETCH NEXT ' + CAST(@PageSize AS NVARCHAR(20)) + N' ROWS ONLY'
                    END + N';

                ;WITH combined AS (
                    ' + @Parts + N'
                )
                SELECT COUNT_BIG(*) AS total_count FROM combined;
            ';

            EXEC sp_executesql
                @Sql,
                N'@Jobsite INT, @FromDt DATETIME2, @ToDt DATETIME2, @Mod NVARCHAR(50), @Act NVARCHAR(30), @Actor INT, @Q NVARCHAR(150)',
                @Jobsite = @Jobsite,
                @FromDt = @FromDt,
                @ToDt = @ToDt,
                @Mod = @Mod,
                @Act = @Act,
                @Actor = @Actor,
                @Q = @Q;
            RETURN;
        END

        SELECT CAST(0 AS BIT) AS success, N'Unknown ACTION_SP' AS message;
    END TRY
    BEGIN CATCH
        SELECT CAST(0 AS BIT) AS success, ERROR_MESSAGE() AS message;
    END CATCH
END;
GO
