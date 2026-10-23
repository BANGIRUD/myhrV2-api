-- =============================================
-- hr.MENUS_SP — CRUD for master Menus menu
-- Actions: SELECT | GET | INSERT | UPDATE | DELETE
-- Run AFTER 10_menus.sql
-- =============================================
CREATE OR ALTER PROCEDURE hr.MENUS_SP
    @ACTION_SP NVARCHAR(30) = NULL,
    @ID INT = NULL,
    @MENU_CODE NVARCHAR(100) = NULL,
    @MENU_NAME NVARCHAR(150) = NULL,
    @MENU_URL NVARCHAR(500) = NULL,
    @ICON NVARCHAR(100) = NULL,
    @MENU_TYPE NVARCHAR(50) = NULL,
    @PARENT_ID INT = NULL,
    @SORT_ORDER INT = NULL,
    @SHOW_SIDEBAR BIT = NULL,
    @IS_ACTIVE BIT = NULL,
    @DESCRIPTION NVARCHAR(255) = NULL,
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
    DECLARE @ClearParent BIT = 0;

    -- Convention: PARENT_ID = -1 means clear parent (set NULL)
    IF @PARENT_ID = -1
    BEGIN
        SET @ClearParent = 1;
        SET @PARENT_ID = NULL;
    END

    BEGIN TRY
        IF @ACTION_SP = N'SELECT'
        BEGIN
            IF @PAGE IS NULL OR @PAGE < 1
                SET @PAGE = 1;

            IF @PAGE_SIZE IS NULL
                SET @PAGE_SIZE = 0;

            SELECT
                m.id,
                m.by_jobsite,
                m.legacy_id,
                m.menu_code,
                m.menu_name,
                m.menu_url,
                m.icon,
                m.menu_type,
                m.parent_id,
                p.menu_name AS parent_name,
                m.sort_order,
                m.show_sidebar,
                m.is_active,
                m.description,
                m.created_at,
                m.updated_at
            FROM hr.menus m
            LEFT JOIN hr.menus p
                ON p.id = m.parent_id AND p.deleted_at IS NULL
            WHERE m.deleted_at IS NULL
              AND m.by_jobsite = @Jobsite
              AND (@IS_ACTIVE IS NULL OR m.is_active = @IS_ACTIVE)
              AND (
                    @SEARCH IS NULL
                 OR LTRIM(RTRIM(@SEARCH)) = N''
                 OR m.menu_code LIKE N'%' + @SEARCH + N'%'
                 OR m.menu_name LIKE N'%' + @SEARCH + N'%'
                 OR m.menu_url LIKE N'%' + @SEARCH + N'%'
              )
            ORDER BY m.sort_order, m.menu_name
            OFFSET CASE WHEN @PAGE_SIZE > 0 THEN (@PAGE - 1) * @PAGE_SIZE ELSE 0 END ROWS
            FETCH NEXT CASE WHEN @PAGE_SIZE > 0 THEN @PAGE_SIZE ELSE 100000 END ROWS ONLY;

            SELECT COUNT(*) AS total_count
            FROM hr.menus m
            WHERE m.deleted_at IS NULL
              AND m.by_jobsite = @Jobsite
              AND (@IS_ACTIVE IS NULL OR m.is_active = @IS_ACTIVE)
              AND (
                    @SEARCH IS NULL
                 OR LTRIM(RTRIM(@SEARCH)) = N''
                 OR m.menu_code LIKE N'%' + @SEARCH + N'%'
                 OR m.menu_name LIKE N'%' + @SEARCH + N'%'
                 OR m.menu_url LIKE N'%' + @SEARCH + N'%'
              );
        END
        ELSE IF @ACTION_SP = N'GET'
        BEGIN
            SELECT
                m.id,
                m.by_jobsite,
                m.legacy_id,
                m.menu_code,
                m.menu_name,
                m.menu_url,
                m.icon,
                m.menu_type,
                m.parent_id,
                p.menu_name AS parent_name,
                m.sort_order,
                m.show_sidebar,
                m.is_active,
                m.description,
                m.created_at,
                m.updated_at
            FROM hr.menus m
            LEFT JOIN hr.menus p
                ON p.id = m.parent_id AND p.deleted_at IS NULL
            WHERE m.deleted_at IS NULL
              AND m.id = @ID
              AND m.by_jobsite = @Jobsite;
        END
        ELSE IF @ACTION_SP = N'INSERT'
        BEGIN
            IF @MENU_CODE IS NULL
               OR LTRIM(RTRIM(@MENU_CODE)) = N''
               OR @MENU_NAME IS NULL
               OR LTRIM(RTRIM(@MENU_NAME)) = N''
            BEGIN
                SELECT CAST(0 AS BIT) AS success,
                       N'Menu code and menu name are required.' AS message;
                RETURN;
            END

            IF EXISTS (
                SELECT 1 FROM hr.menus
                WHERE deleted_at IS NULL
                  AND by_jobsite = @Jobsite
                  AND menu_code = LTRIM(RTRIM(@MENU_CODE))
            )
            BEGIN
                SELECT CAST(0 AS BIT) AS success, N'Menu code already exists.' AS message;
                RETURN;
            END

            IF @PARENT_ID IS NOT NULL AND NOT EXISTS (
                SELECT 1 FROM hr.menus
                WHERE deleted_at IS NULL
                  AND by_jobsite = @Jobsite
                  AND id = @PARENT_ID
            )
            BEGIN
                SELECT CAST(0 AS BIT) AS success, N'Parent menu not found.' AS message;
                RETURN;
            END

            INSERT INTO hr.menus (
                by_jobsite, menu_code, menu_name, menu_url, icon, menu_type,
                parent_id, sort_order, show_sidebar, is_active, description, created_by
            )
            VALUES (
                @Jobsite,
                LTRIM(RTRIM(@MENU_CODE)),
                LTRIM(RTRIM(@MENU_NAME)),
                NULLIF(LTRIM(RTRIM(@MENU_URL)), N''),
                NULLIF(LTRIM(RTRIM(@ICON)), N''),
                NULLIF(LTRIM(RTRIM(@MENU_TYPE)), N''),
                @PARENT_ID,
                ISNULL(@SORT_ORDER, 0),
                ISNULL(@SHOW_SIDEBAR, 1),
                ISNULL(@IS_ACTIVE, 1),
                NULLIF(LTRIM(RTRIM(@DESCRIPTION)), N''),
                @BY_USER
            );

            SELECT CAST(1 AS BIT) AS success,
                   N'Menu saved successfully.' AS message,
                   SCOPE_IDENTITY() AS id;
        END
        ELSE IF @ACTION_SP = N'UPDATE'
        BEGIN
            SELECT @IDCHECK = id
            FROM hr.menus
            WHERE deleted_at IS NULL
              AND id = @ID
              AND by_jobsite = @Jobsite;

            IF @IDCHECK IS NULL
            BEGIN
                SELECT CAST(0 AS BIT) AS success, N'Menu not found.' AS message;
                RETURN;
            END

            IF @MENU_CODE IS NOT NULL AND EXISTS (
                SELECT 1 FROM hr.menus
                WHERE deleted_at IS NULL
                  AND by_jobsite = @Jobsite
                  AND menu_code = LTRIM(RTRIM(@MENU_CODE))
                  AND id <> @IDCHECK
            )
            BEGIN
                SELECT CAST(0 AS BIT) AS success, N'Menu code already exists.' AS message;
                RETURN;
            END

            IF @PARENT_ID IS NOT NULL
            BEGIN
                IF @PARENT_ID = @IDCHECK
                BEGIN
                    SELECT CAST(0 AS BIT) AS success, N'Menu cannot be its own parent.' AS message;
                    RETURN;
                END

                IF NOT EXISTS (
                    SELECT 1 FROM hr.menus
                    WHERE deleted_at IS NULL
                      AND by_jobsite = @Jobsite
                      AND id = @PARENT_ID
                )
                BEGIN
                    SELECT CAST(0 AS BIT) AS success, N'Parent menu not found.' AS message;
                    RETURN;
                END
            END

            UPDATE hr.menus
            SET
                menu_code = CASE
                    WHEN @MENU_CODE IS NULL OR LTRIM(RTRIM(@MENU_CODE)) = N'' THEN menu_code
                    ELSE LTRIM(RTRIM(@MENU_CODE))
                END,
                menu_name = CASE
                    WHEN @MENU_NAME IS NULL OR LTRIM(RTRIM(@MENU_NAME)) = N'' THEN menu_name
                    ELSE LTRIM(RTRIM(@MENU_NAME))
                END,
                menu_url = CASE
                    WHEN @MENU_URL IS NULL THEN menu_url
                    ELSE NULLIF(LTRIM(RTRIM(@MENU_URL)), N'')
                END,
                icon = CASE
                    WHEN @ICON IS NULL THEN icon
                    ELSE NULLIF(LTRIM(RTRIM(@ICON)), N'')
                END,
                menu_type = CASE
                    WHEN @MENU_TYPE IS NULL THEN menu_type
                    ELSE NULLIF(LTRIM(RTRIM(@MENU_TYPE)), N'')
                END,
                parent_id = CASE
                    WHEN @ClearParent = 1 THEN NULL
                    WHEN @PARENT_ID IS NULL THEN parent_id
                    ELSE @PARENT_ID
                END,
                sort_order = ISNULL(@SORT_ORDER, sort_order),
                show_sidebar = ISNULL(@SHOW_SIDEBAR, show_sidebar),
                is_active = ISNULL(@IS_ACTIVE, is_active),
                description = CASE
                    WHEN @DESCRIPTION IS NULL THEN description
                    ELSE NULLIF(LTRIM(RTRIM(@DESCRIPTION)), N'')
                END,
                updated_at = SYSUTCDATETIME(),
                updated_by = @BY_USER
            WHERE id = @IDCHECK;

            SELECT CAST(1 AS BIT) AS success, N'Menu updated successfully.' AS message;
        END
        ELSE IF @ACTION_SP = N'DELETE'
        BEGIN
            SELECT @IDCHECK = id
            FROM hr.menus
            WHERE deleted_at IS NULL
              AND id = @ID
              AND by_jobsite = @Jobsite;

            IF @IDCHECK IS NULL
            BEGIN
                SELECT CAST(0 AS BIT) AS success, N'Menu not found.' AS message;
                RETURN;
            END

            IF EXISTS (
                SELECT 1 FROM hr.menus
                WHERE deleted_at IS NULL
                  AND parent_id = @IDCHECK
            )
            BEGIN
                SELECT CAST(0 AS BIT) AS success,
                       N'Cannot delete menu that still has child menus.' AS message;
                RETURN;
            END

            IF EXISTS (
                SELECT 1 FROM hr.level_permissions
                WHERE deleted_at IS NULL
                  AND menu_id = @IDCHECK
            )
            BEGIN
                SELECT CAST(0 AS BIT) AS success,
                       N'Cannot delete menu that is still used in level permissions.' AS message;
                RETURN;
            END

            UPDATE hr.menus
            SET deleted_at = SYSUTCDATETIME(),
                deleted_by = @BY_USER,
                is_active = 0,
                show_sidebar = 0,
                updated_at = SYSUTCDATETIME(),
                updated_by = @BY_USER
            WHERE id = @IDCHECK;

            SELECT CAST(1 AS BIT) AS success, N'Menu deleted successfully.' AS message;
        END
        ELSE
        BEGIN
            SELECT CAST(0 AS BIT) AS success, N'Unknown ACTION_SP.' AS message;
        END
    END TRY
    BEGIN CATCH
        SELECT
            CAST(0 AS BIT) AS success,
            N'Failed to process menu data.' AS message,
            ERROR_NUMBER() AS error_number,
            ERROR_MESSAGE() AS error_message;
    END CATCH
END
GO
