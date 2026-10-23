-- =============================================
-- UPSERT modules into hr.edit_policy_modules from UI
-- (no separate Master menu — Edit Policy page owns this)
-- Run AFTER 48_edit_policy.sql
-- =============================================

CREATE OR ALTER PROCEDURE hr.EDIT_POLICY_MODULES_SP
    @ACTION_SP NVARCHAR(30) = NULL,
    @MODULE_CODE NVARCHAR(50) = NULL,
    @MODULE_NAME NVARCHAR(100) = NULL,
    @DESCRIPTION NVARCHAR(255) = NULL,
    @SORT_ORDER INT = NULL,
    @BY_USER INT = NULL,
    @BY_JOBSITE INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Jobsite INT = ISNULL(@BY_JOBSITE, 1);
    DECLARE @Code NVARCHAR(50) = LOWER(LTRIM(RTRIM(ISNULL(@MODULE_CODE, N''))));
    DECLARE @Name NVARCHAR(100) = LTRIM(RTRIM(ISNULL(@MODULE_NAME, N'')));

    BEGIN TRY
        IF @ACTION_SP = N'LIST'
        BEGIN
            SELECT
                m.id,
                m.module_code,
                m.module_name,
                m.description,
                m.sort_order,
                m.is_active
            FROM hr.edit_policy_modules m
            WHERE m.by_jobsite = @Jobsite
              AND m.deleted_at IS NULL
              AND m.is_active = 1
            ORDER BY m.sort_order ASC, m.module_name ASC;
        END
        ELSE IF @ACTION_SP = N'UPSERT'
        BEGIN
            IF @Code = N'' OR @Name = N''
            BEGIN
                SELECT CAST(0 AS BIT) AS success,
                       N'module_code and module_name are required.' AS message;
                RETURN;
            END

            -- snake_case / lowercase letters, digits, underscore
            IF @Code LIKE N'%[^a-z0-9_]%' OR LEFT(@Code, 1) LIKE N'[0-9]'
            BEGIN
                SELECT CAST(0 AS BIT) AS success,
                       N'module_code must be lowercase snake_case (a-z, 0-9, _), not starting with a digit).' AS message;
                RETURN;
            END

            IF EXISTS (
                SELECT 1 FROM hr.edit_policy_modules
                WHERE by_jobsite = @Jobsite
                  AND deleted_at IS NULL
                  AND LOWER(module_code) = @Code
            )
            BEGIN
                UPDATE hr.edit_policy_modules
                SET module_name = @Name,
                    description = NULLIF(LTRIM(RTRIM(@DESCRIPTION)), N''),
                    sort_order = ISNULL(@SORT_ORDER, sort_order),
                    is_active = 1,
                    updated_at = SYSUTCDATETIME(),
                    updated_by = @BY_USER
                WHERE by_jobsite = @Jobsite
                  AND deleted_at IS NULL
                  AND LOWER(module_code) = @Code;

                SELECT CAST(1 AS BIT) AS success,
                       N'Module updated.' AS message,
                       (
                           SELECT TOP 1 id FROM hr.edit_policy_modules
                           WHERE by_jobsite = @Jobsite
                             AND deleted_at IS NULL
                             AND LOWER(module_code) = @Code
                       ) AS id;
            END
            ELSE
            BEGIN
                DECLARE @NextSort INT = ISNULL(
                    (
                        SELECT MAX(sort_order) + 10
                        FROM hr.edit_policy_modules
                        WHERE by_jobsite = @Jobsite AND deleted_at IS NULL
                    ),
                    10
                );

                INSERT INTO hr.edit_policy_modules (
                    by_jobsite, module_code, module_name, description, sort_order, created_by
                )
                VALUES (
                    @Jobsite,
                    @Code,
                    @Name,
                    NULLIF(LTRIM(RTRIM(@DESCRIPTION)), N''),
                    ISNULL(@SORT_ORDER, @NextSort),
                    @BY_USER
                );

                SELECT CAST(1 AS BIT) AS success,
                       N'Module created.' AS message,
                       CAST(SCOPE_IDENTITY() AS INT) AS id;
            END
        END
        ELSE
        BEGIN
            SELECT CAST(0 AS BIT) AS success,
                   N'Unsupported ACTION_SP for EDIT_POLICY_MODULES_SP.' AS message;
        END
    END TRY
    BEGIN CATCH
        SELECT CAST(0 AS BIT) AS success,
               CONCAT(N'EDIT_POLICY_MODULES_SP error: ', ERROR_MESSAGE()) AS message;
    END CATCH
END
GO

PRINT 'hr.EDIT_POLICY_MODULES_SP ready (LIST / UPSERT).';
GO
