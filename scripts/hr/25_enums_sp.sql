-- =============================================
-- hr.ENUMS_SP — CRUD for typed lookups (hr.enums)
-- Actions: SELECT | GET | INSERT | UPDATE | DELETE
-- Run AFTER 16_enums.sql
-- =============================================
CREATE OR ALTER PROCEDURE hr.ENUMS_SP
    @ACTION_SP NVARCHAR(30) = NULL,
    @ID INT = NULL,
    @CODE NVARCHAR(50) = NULL,
    @NAME NVARCHAR(MAX) = NULL,
    @CATEGORY NVARCHAR(50) = NULL,
    @DESCRIPTION NVARCHAR(MAX) = NULL,
    @TYPE NVARCHAR(50) = NULL,
    @REF_ID BIGINT = NULL,
    @CLEAR_REF BIT = 0,
    @PAGE INT = 1,
    @PAGE_SIZE INT = 0,
    @SEARCH NVARCHAR(150) = NULL,
    @BY_USER INT = NULL,
    @BY_JOBSITE INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @IDCHECK INT;
    DECLARE @Jobsite INT = ISNULL(@BY_JOBSITE, 1);

    BEGIN TRY
        IF @ACTION_SP = N'SELECT'
        BEGIN
            IF @PAGE IS NULL OR @PAGE < 1
                SET @PAGE = 1;

            IF @PAGE_SIZE IS NULL
                SET @PAGE_SIZE = 0;

            SELECT
                e.id,
                e.by_jobsite,
                e.legacy_id,
                e.code,
                e.name,
                e.category,
                e.description,
                e.type,
                e.ref_id,
                e.created_at,
                e.updated_at
            FROM hr.enums e
            WHERE e.deleted_at IS NULL
              AND e.by_jobsite = @Jobsite
              AND (@TYPE IS NULL OR e.type = @TYPE)
              AND (@CATEGORY IS NULL OR e.category = @CATEGORY)
              AND (
                    @SEARCH IS NULL
                 OR LTRIM(RTRIM(@SEARCH)) = N''
                 OR e.name LIKE N'%' + @SEARCH + N'%'
                 OR e.code LIKE N'%' + @SEARCH + N'%'
              )
            ORDER BY e.type, e.name
            OFFSET CASE WHEN @PAGE_SIZE > 0 THEN (@PAGE - 1) * @PAGE_SIZE ELSE 0 END ROWS
            FETCH NEXT CASE WHEN @PAGE_SIZE > 0 THEN @PAGE_SIZE ELSE 100000 END ROWS ONLY;

            SELECT COUNT(*) AS total_count
            FROM hr.enums e
            WHERE e.deleted_at IS NULL
              AND e.by_jobsite = @Jobsite
              AND (@TYPE IS NULL OR e.type = @TYPE)
              AND (@CATEGORY IS NULL OR e.category = @CATEGORY)
              AND (
                    @SEARCH IS NULL
                 OR LTRIM(RTRIM(@SEARCH)) = N''
                 OR e.name LIKE N'%' + @SEARCH + N'%'
                 OR e.code LIKE N'%' + @SEARCH + N'%'
              );
        END
        ELSE IF @ACTION_SP = N'GET'
        BEGIN
            SELECT
                e.id,
                e.by_jobsite,
                e.legacy_id,
                e.code,
                e.name,
                e.category,
                e.description,
                e.type,
                e.ref_id,
                e.created_at,
                e.updated_at
            FROM hr.enums e
            WHERE e.deleted_at IS NULL
              AND e.id = @ID
              AND e.by_jobsite = @Jobsite;
        END
        ELSE IF @ACTION_SP = N'INSERT'
        BEGIN
            IF @NAME IS NULL OR LTRIM(RTRIM(@NAME)) = N''
               OR @TYPE IS NULL OR LTRIM(RTRIM(@TYPE)) = N''
            BEGIN
                SELECT CAST(0 AS BIT) AS success, N'Name and type are required.' AS message;
                RETURN;
            END

            IF @CODE IS NOT NULL AND LTRIM(RTRIM(@CODE)) <> N'' AND EXISTS (
                SELECT 1 FROM hr.enums
                WHERE deleted_at IS NULL
                  AND by_jobsite = @Jobsite
                  AND type = LTRIM(RTRIM(@TYPE))
                  AND code = LTRIM(RTRIM(@CODE))
            )
            BEGIN
                SELECT CAST(0 AS BIT) AS success, N'Enum code already exists for this type.' AS message;
                RETURN;
            END

            INSERT INTO hr.enums (
                by_jobsite, code, name, category, description, type, ref_id, created_by
            )
            VALUES (
                @Jobsite,
                NULLIF(LTRIM(RTRIM(@CODE)), N''),
                LTRIM(RTRIM(@NAME)),
                NULLIF(LTRIM(RTRIM(@CATEGORY)), N''),
                NULLIF(LTRIM(RTRIM(@DESCRIPTION)), N''),
                LTRIM(RTRIM(@TYPE)),
                @REF_ID,
                @BY_USER
            );

            SELECT CAST(1 AS BIT) AS success,
                   N'Enum saved successfully.' AS message,
                   SCOPE_IDENTITY() AS id;
        END
        ELSE IF @ACTION_SP = N'UPDATE'
        BEGIN
            SELECT @IDCHECK = id
            FROM hr.enums
            WHERE deleted_at IS NULL
              AND id = @ID
              AND by_jobsite = @Jobsite;

            IF @IDCHECK IS NULL
            BEGIN
                SELECT CAST(0 AS BIT) AS success, N'Enum not found.' AS message;
                RETURN;
            END

            IF @CODE IS NOT NULL AND LTRIM(RTRIM(@CODE)) <> N'' AND EXISTS (
                SELECT 1 FROM hr.enums
                WHERE deleted_at IS NULL
                  AND by_jobsite = @Jobsite
                  AND type = ISNULL(NULLIF(LTRIM(RTRIM(@TYPE)), N''),
                                    (SELECT type FROM hr.enums WHERE id = @IDCHECK))
                  AND code = LTRIM(RTRIM(@CODE))
                  AND id <> @IDCHECK
            )
            BEGIN
                SELECT CAST(0 AS BIT) AS success, N'Enum code already exists for this type.' AS message;
                RETURN;
            END

            UPDATE hr.enums
            SET
                code = CASE
                    WHEN @CODE IS NULL THEN code
                    ELSE NULLIF(LTRIM(RTRIM(@CODE)), N'')
                END,
                name = CASE
                    WHEN @NAME IS NULL OR LTRIM(RTRIM(@NAME)) = N'' THEN name
                    ELSE LTRIM(RTRIM(@NAME))
                END,
                category = CASE
                    WHEN @CATEGORY IS NULL THEN category
                    ELSE NULLIF(LTRIM(RTRIM(@CATEGORY)), N'')
                END,
                description = CASE
                    WHEN @DESCRIPTION IS NULL THEN description
                    ELSE NULLIF(LTRIM(RTRIM(@DESCRIPTION)), N'')
                END,
                type = CASE
                    WHEN @TYPE IS NULL OR LTRIM(RTRIM(@TYPE)) = N'' THEN type
                    ELSE LTRIM(RTRIM(@TYPE))
                END,
                ref_id = CASE
                    WHEN @CLEAR_REF = 1 THEN NULL
                    WHEN @REF_ID IS NULL THEN ref_id
                    ELSE @REF_ID
                END,
                updated_at = SYSUTCDATETIME(),
                updated_by = @BY_USER
            WHERE id = @IDCHECK;

            SELECT CAST(1 AS BIT) AS success, N'Enum updated successfully.' AS message;
        END
        ELSE IF @ACTION_SP = N'DELETE'
        BEGIN
            SELECT @IDCHECK = id
            FROM hr.enums
            WHERE deleted_at IS NULL
              AND id = @ID
              AND by_jobsite = @Jobsite;

            IF @IDCHECK IS NULL
            BEGIN
                SELECT CAST(0 AS BIT) AS success, N'Enum not found.' AS message;
                RETURN;
            END

            UPDATE hr.enums
            SET deleted_at = SYSUTCDATETIME(),
                deleted_by = @BY_USER,
                updated_at = SYSUTCDATETIME(),
                updated_by = @BY_USER
            WHERE id = @IDCHECK;

            SELECT CAST(1 AS BIT) AS success, N'Enum deleted successfully.' AS message;
        END
        ELSE
        BEGIN
            SELECT CAST(0 AS BIT) AS success, N'Unknown ACTION_SP.' AS message;
        END
    END TRY
    BEGIN CATCH
        SELECT
            CAST(0 AS BIT) AS success,
            N'Failed to process enum data.' AS message,
            ERROR_NUMBER() AS error_number,
            ERROR_MESSAGE() AS error_message;
    END CATCH
END
GO
