-- =============================================
-- hr.ROSTER_EDIT_POLICY_SP — menu hr_roster_edit_policy
-- Actions: SELECT | GET | INSERT | UPDATE | DELETE
-- Source: hr.roster_edit_policy (+ hr.levels for display name)
-- Run AFTER 45_roster_edit_policy.sql
-- =============================================
CREATE OR ALTER PROCEDURE hr.ROSTER_EDIT_POLICY_SP
    @ACTION_SP NVARCHAR(30) = NULL,
    @ID INT = NULL,
    @LEVEL_CODE NVARCHAR(50) = NULL,
    @CAN_EDIT BIT = NULL,
    @PAST_DAYS INT = NULL,
    @ALLOW_PAST BIT = NULL,
    @DESCRIPTION NVARCHAR(255) = NULL,
    @PAGE INT = 1,
    @PAGE_SIZE INT = 0,
    @SEARCH NVARCHAR(150) = NULL,
    @BY_USER INT = NULL,
    @BY_JOBSITE INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Jobsite INT = ISNULL(@BY_JOBSITE, 1);

    BEGIN TRY
        IF @ACTION_SP = N'SELECT'
        BEGIN
            DECLARE @Q NVARCHAR(150) = NULLIF(LTRIM(RTRIM(@SEARCH)), N'');
            IF @PAGE IS NULL OR @PAGE < 1 SET @PAGE = 1;
            IF @PAGE_SIZE IS NULL SET @PAGE_SIZE = 0;

            SELECT
                p.id,
                p.by_jobsite,
                p.level_code,
                ISNULL(l.name, p.level_code) AS level_name,
                p.can_edit,
                p.past_days,
                p.allow_past,
                p.description,
                p.created_at,
                p.updated_at
            FROM hr.roster_edit_policy p
            LEFT JOIN hr.levels l
                ON l.by_jobsite = p.by_jobsite
               AND LOWER(l.code) = LOWER(p.level_code)
               AND l.deleted_at IS NULL
            WHERE p.deleted_at IS NULL
              AND p.by_jobsite = @Jobsite
              AND (
                    @Q IS NULL
                 OR p.level_code LIKE N'%' + @Q + N'%'
                 OR l.name LIKE N'%' + @Q + N'%'
                 OR p.description LIKE N'%' + @Q + N'%'
                  )
            ORDER BY p.level_code ASC
            OFFSET CASE WHEN @PAGE_SIZE > 0 THEN (@PAGE - 1) * @PAGE_SIZE ELSE 0 END ROWS
            FETCH NEXT CASE WHEN @PAGE_SIZE > 0 THEN @PAGE_SIZE ELSE 100000 END ROWS ONLY;

            SELECT COUNT(*) AS total_count
            FROM hr.roster_edit_policy p
            LEFT JOIN hr.levels l
                ON l.by_jobsite = p.by_jobsite
               AND LOWER(l.code) = LOWER(p.level_code)
               AND l.deleted_at IS NULL
            WHERE p.deleted_at IS NULL
              AND p.by_jobsite = @Jobsite
              AND (
                    @Q IS NULL
                 OR p.level_code LIKE N'%' + @Q + N'%'
                 OR l.name LIKE N'%' + @Q + N'%'
                 OR p.description LIKE N'%' + @Q + N'%'
                  );
        END
        ELSE IF @ACTION_SP = N'GET'
        BEGIN
            SELECT
                p.id,
                p.by_jobsite,
                p.level_code,
                ISNULL(l.name, p.level_code) AS level_name,
                p.can_edit,
                p.past_days,
                p.allow_past,
                p.description,
                p.created_at,
                p.updated_at
            FROM hr.roster_edit_policy p
            LEFT JOIN hr.levels l
                ON l.by_jobsite = p.by_jobsite
               AND LOWER(l.code) = LOWER(p.level_code)
               AND l.deleted_at IS NULL
            WHERE p.deleted_at IS NULL
              AND p.by_jobsite = @Jobsite
              AND p.id = @ID;
        END
        ELSE IF @ACTION_SP = N'INSERT'
        BEGIN
            DECLARE @InsCode NVARCHAR(50) = LOWER(LTRIM(RTRIM(ISNULL(@LEVEL_CODE, N''))));
            IF @InsCode = N''
            BEGIN
                SELECT CAST(0 AS BIT) AS success, N'level_code is required.' AS message;
                RETURN;
            END

            IF ISNULL(@PAST_DAYS, 0) < 0
            BEGIN
                SELECT CAST(0 AS BIT) AS success, N'past_days must be >= 0.' AS message;
                RETURN;
            END

            IF EXISTS (
                SELECT 1 FROM hr.roster_edit_policy
                WHERE by_jobsite = @Jobsite
                  AND deleted_at IS NULL
                  AND LOWER(level_code) = @InsCode
            )
            BEGIN
                SELECT CAST(0 AS BIT) AS success,
                       N'A policy row already exists for this level_code.' AS message;
                RETURN;
            END

            INSERT INTO hr.roster_edit_policy (
                by_jobsite, level_code, can_edit, past_days, allow_past, description, created_by
            )
            VALUES (
                @Jobsite,
                @InsCode,
                ISNULL(@CAN_EDIT, 1),
                ISNULL(@PAST_DAYS, 0),
                ISNULL(@ALLOW_PAST, 0),
                NULLIF(LTRIM(RTRIM(@DESCRIPTION)), N''),
                @BY_USER
            );

            SELECT CAST(1 AS BIT) AS success,
                   N'Roster edit policy created.' AS message,
                   CAST(SCOPE_IDENTITY() AS INT) AS id;
        END
        ELSE IF @ACTION_SP = N'UPDATE'
        BEGIN
            IF @ID IS NULL
            BEGIN
                SELECT CAST(0 AS BIT) AS success, N'id is required.' AS message;
                RETURN;
            END

            DECLARE @UpdCode NVARCHAR(50) = LOWER(LTRIM(RTRIM(ISNULL(@LEVEL_CODE, N''))));
            IF @UpdCode = N''
            BEGIN
                SELECT CAST(0 AS BIT) AS success, N'level_code is required.' AS message;
                RETURN;
            END

            IF ISNULL(@PAST_DAYS, 0) < 0
            BEGIN
                SELECT CAST(0 AS BIT) AS success, N'past_days must be >= 0.' AS message;
                RETURN;
            END

            IF NOT EXISTS (
                SELECT 1 FROM hr.roster_edit_policy
                WHERE id = @ID AND by_jobsite = @Jobsite AND deleted_at IS NULL
            )
            BEGIN
                SELECT CAST(0 AS BIT) AS success, N'Policy not found.' AS message;
                RETURN;
            END

            IF EXISTS (
                SELECT 1 FROM hr.roster_edit_policy
                WHERE by_jobsite = @Jobsite
                  AND deleted_at IS NULL
                  AND LOWER(level_code) = @UpdCode
                  AND id <> @ID
            )
            BEGIN
                SELECT CAST(0 AS BIT) AS success,
                       N'A policy row already exists for this level_code.' AS message;
                RETURN;
            END

            UPDATE hr.roster_edit_policy
            SET level_code = @UpdCode,
                can_edit = ISNULL(@CAN_EDIT, can_edit),
                past_days = ISNULL(@PAST_DAYS, past_days),
                allow_past = ISNULL(@ALLOW_PAST, allow_past),
                description = NULLIF(LTRIM(RTRIM(@DESCRIPTION)), N''),
                updated_at = SYSUTCDATETIME(),
                updated_by = @BY_USER
            WHERE id = @ID
              AND by_jobsite = @Jobsite
              AND deleted_at IS NULL;

            SELECT CAST(1 AS BIT) AS success, N'Roster edit policy updated.' AS message, @ID AS id;
        END
        ELSE IF @ACTION_SP = N'DELETE'
        BEGIN
            IF @ID IS NULL
            BEGIN
                SELECT CAST(0 AS BIT) AS success, N'id is required.' AS message;
                RETURN;
            END

            IF NOT EXISTS (
                SELECT 1 FROM hr.roster_edit_policy
                WHERE id = @ID AND by_jobsite = @Jobsite AND deleted_at IS NULL
            )
            BEGIN
                SELECT CAST(0 AS BIT) AS success, N'Policy not found.' AS message;
                RETURN;
            END

            UPDATE hr.roster_edit_policy
            SET deleted_at = SYSUTCDATETIME(),
                deleted_by = @BY_USER
            WHERE id = @ID
              AND by_jobsite = @Jobsite
              AND deleted_at IS NULL;

            SELECT CAST(1 AS BIT) AS success, N'Roster edit policy deleted.' AS message, @ID AS id;
        END
        ELSE
        BEGIN
            SELECT CAST(0 AS BIT) AS success,
                   N'Unsupported ACTION_SP for ROSTER_EDIT_POLICY_SP.' AS message;
        END
    END TRY
    BEGIN CATCH
        SELECT CAST(0 AS BIT) AS success,
               CONCAT(N'ROSTER_EDIT_POLICY_SP error: ', ERROR_MESSAGE()) AS message;
    END CATCH
END
GO
