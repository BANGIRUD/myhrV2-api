-- =============================================
-- hr.LEVEL_PERMISSIONS_SP — matrix level × menu
-- Actions: SELECT | UPSERT
-- SELECT returns every matching menu for a level (LEFT JOIN so missing
-- rows appear with can_* = 0). Default filter: menu_code LIKE 'hr_%'.
-- Run AFTER 11_level_permissions.sql + 13_wave1_sidebar_menus.sql
-- =============================================
CREATE OR ALTER PROCEDURE hr.LEVEL_PERMISSIONS_SP
    @ACTION_SP NVARCHAR(30) = NULL,
    @ID INT = NULL,
    @LEVEL_ID INT = NULL,
    @MENU_ID INT = NULL,
    @CAN_READ BIT = NULL,
    @CAN_INSERT BIT = NULL,
    @CAN_UPDATE BIT = NULL,
    @CAN_DELETE BIT = NULL,
    @CAN_EXPORT BIT = NULL,
    @CAN_APPROVE BIT = NULL,
    @AUDIENCE NVARCHAR(100) = NULL,
    @CLEAR_AUDIENCE BIT = 0,
    @HR_ONLY BIT = 1,
    @SEARCH NVARCHAR(150) = NULL,
    @BY_USER INT = NULL,
    @BY_JOBSITE INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Jobsite INT = ISNULL(@BY_JOBSITE, 1);
    DECLARE @Actor INT = @BY_USER;
    DECLARE @ExistingId INT;

    BEGIN TRY
        IF @ACTION_SP = N'SELECT'
        BEGIN
            IF @LEVEL_ID IS NULL
            BEGIN
                -- Flat list of existing grants (legacy table view)
                SELECT
                    lp.id,
                    lp.by_jobsite,
                    lp.level_id,
                    l.code AS level_code,
                    l.name AS level_name,
                    lp.menu_id,
                    m.menu_code,
                    m.menu_name,
                    m.menu_url,
                    m.parent_id,
                    m.sort_order,
                    m.show_sidebar,
                    m.is_active,
                    lp.audience,
                    CAST(ISNULL(lp.can_read, 0) AS BIT) AS can_read,
                    CAST(ISNULL(lp.can_insert, 0) AS BIT) AS can_insert,
                    CAST(ISNULL(lp.can_update, 0) AS BIT) AS can_update,
                    CAST(ISNULL(lp.can_delete, 0) AS BIT) AS can_delete,
                    CAST(ISNULL(lp.can_export, 0) AS BIT) AS can_export,
                    CAST(ISNULL(lp.can_approve, 0) AS BIT) AS can_approve
                FROM hr.level_permissions lp
                INNER JOIN hr.levels l ON l.id = lp.level_id AND l.deleted_at IS NULL
                INNER JOIN hr.menus m ON m.id = lp.menu_id AND m.deleted_at IS NULL
                WHERE lp.by_jobsite = @Jobsite
                  AND lp.deleted_at IS NULL
                  AND (@HR_ONLY = 0 OR m.menu_code LIKE N'hr_%')
                  AND (
                        @SEARCH IS NULL
                     OR LTRIM(RTRIM(@SEARCH)) = N''
                     OR m.menu_code LIKE N'%' + @SEARCH + N'%'
                     OR m.menu_name LIKE N'%' + @SEARCH + N'%'
                     OR l.code LIKE N'%' + @SEARCH + N'%'
                     OR l.name LIKE N'%' + @SEARCH + N'%'
                  )
                ORDER BY l.sort_order, m.sort_order, m.menu_name;

                SELECT COUNT(*) AS total_count
                FROM hr.level_permissions lp
                INNER JOIN hr.levels l ON l.id = lp.level_id AND l.deleted_at IS NULL
                INNER JOIN hr.menus m ON m.id = lp.menu_id AND m.deleted_at IS NULL
                WHERE lp.by_jobsite = @Jobsite
                  AND lp.deleted_at IS NULL
                  AND (@HR_ONLY = 0 OR m.menu_code LIKE N'hr_%')
                  AND (
                        @SEARCH IS NULL
                     OR LTRIM(RTRIM(@SEARCH)) = N''
                     OR m.menu_code LIKE N'%' + @SEARCH + N'%'
                     OR m.menu_name LIKE N'%' + @SEARCH + N'%'
                     OR l.code LIKE N'%' + @SEARCH + N'%'
                     OR l.name LIKE N'%' + @SEARCH + N'%'
                  );
            END
            ELSE
            BEGIN
                -- Matrix for one level: all menus (+ zeroed flags when no grant row)
                SELECT
                    lp.id,
                    @Jobsite AS by_jobsite,
                    @LEVEL_ID AS level_id,
                    l.code AS level_code,
                    l.name AS level_name,
                    m.id AS menu_id,
                    m.menu_code,
                    m.menu_name,
                    m.menu_url,
                    m.parent_id,
                    p.menu_name AS parent_name,
                    m.sort_order,
                    m.show_sidebar,
                    m.is_active,
                    lp.audience,
                    CAST(ISNULL(lp.can_read, 0) AS BIT) AS can_read,
                    CAST(ISNULL(lp.can_insert, 0) AS BIT) AS can_insert,
                    CAST(ISNULL(lp.can_update, 0) AS BIT) AS can_update,
                    CAST(ISNULL(lp.can_delete, 0) AS BIT) AS can_delete,
                    CAST(ISNULL(lp.can_export, 0) AS BIT) AS can_export,
                    CAST(ISNULL(lp.can_approve, 0) AS BIT) AS can_approve
                FROM hr.menus m
                INNER JOIN hr.levels l
                    ON l.id = @LEVEL_ID
                   AND l.by_jobsite = @Jobsite
                   AND l.deleted_at IS NULL
                LEFT JOIN hr.menus p
                    ON p.id = m.parent_id
                   AND p.deleted_at IS NULL
                LEFT JOIN hr.level_permissions lp
                    ON lp.menu_id = m.id
                   AND lp.level_id = @LEVEL_ID
                   AND lp.by_jobsite = @Jobsite
                   AND lp.deleted_at IS NULL
                WHERE m.by_jobsite = @Jobsite
                  AND m.deleted_at IS NULL
                  AND (@HR_ONLY = 0 OR m.menu_code LIKE N'hr_%')
                  AND (
                        @SEARCH IS NULL
                     OR LTRIM(RTRIM(@SEARCH)) = N''
                     OR m.menu_code LIKE N'%' + @SEARCH + N'%'
                     OR m.menu_name LIKE N'%' + @SEARCH + N'%'
                  )
                ORDER BY m.sort_order, m.menu_name;

                SELECT COUNT(*) AS total_count
                FROM hr.menus m
                WHERE m.by_jobsite = @Jobsite
                  AND m.deleted_at IS NULL
                  AND (@HR_ONLY = 0 OR m.menu_code LIKE N'hr_%')
                  AND (
                        @SEARCH IS NULL
                     OR LTRIM(RTRIM(@SEARCH)) = N''
                     OR m.menu_code LIKE N'%' + @SEARCH + N'%'
                     OR m.menu_name LIKE N'%' + @SEARCH + N'%'
                  );
            END
        END
        ELSE IF @ACTION_SP = N'UPSERT'
        BEGIN
            IF @LEVEL_ID IS NULL OR @MENU_ID IS NULL
            BEGIN
                SELECT CAST(0 AS BIT) AS success,
                       N'level_id and menu_id are required.' AS message;
                RETURN;
            END;

            IF NOT EXISTS (
                SELECT 1 FROM hr.levels
                WHERE id = @LEVEL_ID AND by_jobsite = @Jobsite AND deleted_at IS NULL
            )
            BEGIN
                SELECT CAST(0 AS BIT) AS success, N'Level not found.' AS message;
                RETURN;
            END;

            IF NOT EXISTS (
                SELECT 1 FROM hr.menus
                WHERE id = @MENU_ID AND by_jobsite = @Jobsite AND deleted_at IS NULL
            )
            BEGIN
                SELECT CAST(0 AS BIT) AS success, N'Menu not found.' AS message;
                RETURN;
            END;

            SELECT @ExistingId = lp.id
            FROM hr.level_permissions lp
            WHERE lp.by_jobsite = @Jobsite
              AND lp.level_id = @LEVEL_ID
              AND lp.menu_id = @MENU_ID
              AND lp.deleted_at IS NULL;

            IF @ExistingId IS NULL AND @ID IS NOT NULL
            BEGIN
                SELECT @ExistingId = lp.id
                FROM hr.level_permissions lp
                WHERE lp.id = @ID
                  AND lp.by_jobsite = @Jobsite
                  AND lp.deleted_at IS NULL;
            END;

            IF @ExistingId IS NULL
            BEGIN
                INSERT INTO hr.level_permissions (
                    by_jobsite, level_id, menu_id,
                    can_read, can_insert, can_update, can_delete, can_export, can_approve,
                    audience, created_by
                )
                VALUES (
                    @Jobsite, @LEVEL_ID, @MENU_ID,
                    ISNULL(@CAN_READ, 0),
                    ISNULL(@CAN_INSERT, 0),
                    ISNULL(@CAN_UPDATE, 0),
                    ISNULL(@CAN_DELETE, 0),
                    ISNULL(@CAN_EXPORT, 0),
                    ISNULL(@CAN_APPROVE, 0),
                    CASE WHEN @CLEAR_AUDIENCE = 1 THEN NULL ELSE @AUDIENCE END,
                    @Actor
                );

                SELECT CAST(1 AS BIT) AS success,
                       N'Level permission created.' AS message,
                       SCOPE_IDENTITY() AS id;
            END
            ELSE
            BEGIN
                UPDATE hr.level_permissions
                SET can_read = ISNULL(@CAN_READ, can_read),
                    can_insert = ISNULL(@CAN_INSERT, can_insert),
                    can_update = ISNULL(@CAN_UPDATE, can_update),
                    can_delete = ISNULL(@CAN_DELETE, can_delete),
                    can_export = ISNULL(@CAN_EXPORT, can_export),
                    can_approve = ISNULL(@CAN_APPROVE, can_approve),
                    audience = CASE
                        WHEN @CLEAR_AUDIENCE = 1 THEN NULL
                        WHEN @AUDIENCE IS NOT NULL THEN @AUDIENCE
                        ELSE audience
                    END,
                    updated_at = SYSUTCDATETIME(),
                    updated_by = @Actor
                WHERE id = @ExistingId
                  AND by_jobsite = @Jobsite
                  AND deleted_at IS NULL;

                SELECT CAST(1 AS BIT) AS success,
                       N'Level permission updated.' AS message,
                       @ExistingId AS id;
            END
        END
        ELSE
        BEGIN
            SELECT CAST(0 AS BIT) AS success, N'Unknown ACTION_SP.' AS message;
        END
    END TRY
    BEGIN CATCH
        SELECT CAST(0 AS BIT) AS success,
               ERROR_MESSAGE() AS message;
    END CATCH
END
GO
