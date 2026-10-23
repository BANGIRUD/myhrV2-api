-- =============================================
-- hr.USERS_SP — CRUD for master Users menu
-- Actions: SELECT | GET | INSERT | UPDATE | DELETE | RESET_PASSWORD
-- Run AFTER 09_users_level_id.sql (+ 08_level_legacy_map for level resolve)
-- Password hash is always supplied by the app (bcrypt); SP never hashes.
-- =============================================
CREATE OR ALTER PROCEDURE hr.USERS_SP
    @ACTION_SP NVARCHAR(30) = NULL,
    @ID INT = NULL,
    @USERNAME NVARCHAR(50) = NULL,
    @PASSWORD NVARCHAR(255) = NULL,
    @FULL_NAME NVARCHAR(150) = NULL,
    @EMAIL NVARCHAR(150) = NULL,
    @PHONE NVARCHAR(30) = NULL,
    @DEPARTMENT NVARCHAR(100) = NULL,
    @SECTION NVARCHAR(100) = NULL,
    @DESCRIPTION NVARCHAR(MAX) = NULL,
    @LEVEL NVARCHAR(50) = NULL,          -- legacy menu_privilege.id
    @LEVEL_ID INT = NULL,              -- canonical hr.levels.id
    @WORKER_SCOPE NVARCHAR(10) = NULL, -- sis | ls | all ('' clears)
    @MODULE NVARCHAR(30) = NULL,       -- irel | meals | safety | attendance ('' clears)
    @PRIVILEGE_MENU NVARCHAR(MAX) = NULL,
    @IS_ACTIVE BIT = NULL,
    @PAGE INT = 1,
    @PAGE_SIZE INT = 0,
    @SEARCH NVARCHAR(150) = NULL,
    @BY_USER INT = NULL,
    @BY_JOBSITE INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @IDCHECK INT;
    DECLARE @ResolvedLevel NVARCHAR(50);
    DECLARE @ResolvedLevelId INT;
    DECLARE @ResolvedScope NVARCHAR(10);
    DECLARE @ResolvedModule NVARCHAR(30);
    DECLARE @Jobsite INT = ISNULL(@BY_JOBSITE, 1);

    BEGIN TRY
        IF @ACTION_SP = N'SELECT'
        BEGIN
            IF @PAGE IS NULL OR @PAGE < 1
                SET @PAGE = 1;

            IF @PAGE_SIZE IS NULL
                SET @PAGE_SIZE = 0;

            SELECT
                u.id,
                u.by_jobsite,
                u.username,
                u.full_name,
                u.email,
                u.phone,
                u.department,
                (
                    SELECT STRING_AGG(d.name, N', ') WITHIN GROUP (ORDER BY d.by_order, d.name)
                    FROM STRING_SPLIT(REPLACE(ISNULL(u.department, N''), N' ', N''), N',') ss
                    INNER JOIN hr.structure d
                        ON d.by_jobsite = u.by_jobsite
                       AND d.deleted_at IS NULL
                       AND d.type = N'department'
                       AND d.id = TRY_CAST(ss.value AS INT)
                    WHERE LTRIM(RTRIM(ss.value)) <> N''
                ) AS department_name,
                u.section,
                (
                    SELECT STRING_AGG(s.name, N', ') WITHIN GROUP (ORDER BY s.by_order, s.name)
                    FROM STRING_SPLIT(REPLACE(ISNULL(u.section, N''), N' ', N''), N',') ss
                    INNER JOIN hr.structure s
                        ON s.by_jobsite = u.by_jobsite
                       AND s.deleted_at IS NULL
                       AND s.type = N'section'
                       AND s.id = TRY_CAST(ss.value AS INT)
                    WHERE LTRIM(RTRIM(ss.value)) <> N''
                ) AS section_name,
                u.description,
                u.level,
                u.level_id,
                u.worker_scope,
                u.module,
                l.code AS level_code,
                l.name AS level_name,
                l.sort_order AS level_sort_order,
                u.privilege_menu,
                u.is_active,
                u.last_login,
                u.created_at,
                u.updated_at
            FROM hr.users u
            LEFT JOIN hr.levels l
                ON l.id = u.level_id AND l.deleted_at IS NULL
            WHERE u.deleted_at IS NULL
              AND u.by_jobsite = @Jobsite
              AND (@LEVEL_ID IS NULL OR u.level_id = @LEVEL_ID)
              AND (
                    @DEPARTMENT IS NULL
                 OR LTRIM(RTRIM(@DEPARTMENT)) = N''
                 OR CONCAT(N',', REPLACE(ISNULL(u.department, N''), N' ', N''), N',')
                    LIKE CONCAT(N'%,', LTRIM(RTRIM(@DEPARTMENT)), N',%')
              )
              AND (
                    @SECTION IS NULL
                 OR LTRIM(RTRIM(@SECTION)) = N''
                 OR CONCAT(N',', REPLACE(ISNULL(u.section, N''), N' ', N''), N',')
                    LIKE CONCAT(N'%,', LTRIM(RTRIM(@SECTION)), N',%')
              )
              AND (@IS_ACTIVE IS NULL OR u.is_active = @IS_ACTIVE)
              AND (
                    @SEARCH IS NULL
                 OR LTRIM(RTRIM(@SEARCH)) = N''
                 OR u.username LIKE N'%' + @SEARCH + N'%'
                 OR u.full_name LIKE N'%' + @SEARCH + N'%'
                 OR u.email LIKE N'%' + @SEARCH + N'%'
                 OR l.name LIKE N'%' + @SEARCH + N'%'
                 OR l.code LIKE N'%' + @SEARCH + N'%'
                 OR EXISTS (
                        SELECT 1
                        FROM STRING_SPLIT(REPLACE(ISNULL(u.department, N''), N' ', N''), N',') ss
                        INNER JOIN hr.structure d
                            ON d.by_jobsite = u.by_jobsite
                           AND d.deleted_at IS NULL
                           AND d.type = N'department'
                           AND d.id = TRY_CAST(ss.value AS INT)
                        WHERE d.name LIKE N'%' + @SEARCH + N'%'
                   )
                 OR EXISTS (
                        SELECT 1
                        FROM STRING_SPLIT(REPLACE(ISNULL(u.section, N''), N' ', N''), N',') ss
                        INNER JOIN hr.structure s
                            ON s.by_jobsite = u.by_jobsite
                           AND s.deleted_at IS NULL
                           AND s.type = N'section'
                           AND s.id = TRY_CAST(ss.value AS INT)
                        WHERE s.name LIKE N'%' + @SEARCH + N'%'
                   )
              )
            ORDER BY
                ISNULL(l.sort_order, 9999),
                l.name,
                u.full_name,
                u.username
            OFFSET CASE WHEN @PAGE_SIZE > 0 THEN (@PAGE - 1) * @PAGE_SIZE ELSE 0 END ROWS
            FETCH NEXT CASE WHEN @PAGE_SIZE > 0 THEN @PAGE_SIZE ELSE 100000 END ROWS ONLY;

            SELECT COUNT(*) AS total_count
            FROM hr.users u
            LEFT JOIN hr.levels l
                ON l.id = u.level_id AND l.deleted_at IS NULL
            WHERE u.deleted_at IS NULL
              AND u.by_jobsite = @Jobsite
              AND (@LEVEL_ID IS NULL OR u.level_id = @LEVEL_ID)
              AND (
                    @DEPARTMENT IS NULL
                 OR LTRIM(RTRIM(@DEPARTMENT)) = N''
                 OR CONCAT(N',', REPLACE(ISNULL(u.department, N''), N' ', N''), N',')
                    LIKE CONCAT(N'%,', LTRIM(RTRIM(@DEPARTMENT)), N',%')
              )
              AND (
                    @SECTION IS NULL
                 OR LTRIM(RTRIM(@SECTION)) = N''
                 OR CONCAT(N',', REPLACE(ISNULL(u.section, N''), N' ', N''), N',')
                    LIKE CONCAT(N'%,', LTRIM(RTRIM(@SECTION)), N',%')
              )
              AND (@IS_ACTIVE IS NULL OR u.is_active = @IS_ACTIVE)
              AND (
                    @SEARCH IS NULL
                 OR LTRIM(RTRIM(@SEARCH)) = N''
                 OR u.username LIKE N'%' + @SEARCH + N'%'
                 OR u.full_name LIKE N'%' + @SEARCH + N'%'
                 OR u.email LIKE N'%' + @SEARCH + N'%'
                 OR l.name LIKE N'%' + @SEARCH + N'%'
                 OR l.code LIKE N'%' + @SEARCH + N'%'
                 OR EXISTS (
                        SELECT 1
                        FROM STRING_SPLIT(REPLACE(ISNULL(u.department, N''), N' ', N''), N',') ss
                        INNER JOIN hr.structure d
                            ON d.by_jobsite = u.by_jobsite
                           AND d.deleted_at IS NULL
                           AND d.type = N'department'
                           AND d.id = TRY_CAST(ss.value AS INT)
                        WHERE d.name LIKE N'%' + @SEARCH + N'%'
                   )
                 OR EXISTS (
                        SELECT 1
                        FROM STRING_SPLIT(REPLACE(ISNULL(u.section, N''), N' ', N''), N',') ss
                        INNER JOIN hr.structure s
                            ON s.by_jobsite = u.by_jobsite
                           AND s.deleted_at IS NULL
                           AND s.type = N'section'
                           AND s.id = TRY_CAST(ss.value AS INT)
                        WHERE s.name LIKE N'%' + @SEARCH + N'%'
                   )
              );
        END
        ELSE IF @ACTION_SP = N'GET'
        BEGIN
            SELECT
                u.id,
                u.by_jobsite,
                u.username,
                u.full_name,
                u.email,
                u.phone,
                u.department,
                (
                    SELECT STRING_AGG(d.name, N', ') WITHIN GROUP (ORDER BY d.by_order, d.name)
                    FROM STRING_SPLIT(REPLACE(ISNULL(u.department, N''), N' ', N''), N',') ss
                    INNER JOIN hr.structure d
                        ON d.by_jobsite = u.by_jobsite
                       AND d.deleted_at IS NULL
                       AND d.type = N'department'
                       AND d.id = TRY_CAST(ss.value AS INT)
                    WHERE LTRIM(RTRIM(ss.value)) <> N''
                ) AS department_name,
                u.section,
                (
                    SELECT STRING_AGG(s.name, N', ') WITHIN GROUP (ORDER BY s.by_order, s.name)
                    FROM STRING_SPLIT(REPLACE(ISNULL(u.section, N''), N' ', N''), N',') ss
                    INNER JOIN hr.structure s
                        ON s.by_jobsite = u.by_jobsite
                       AND s.deleted_at IS NULL
                       AND s.type = N'section'
                       AND s.id = TRY_CAST(ss.value AS INT)
                    WHERE LTRIM(RTRIM(ss.value)) <> N''
                ) AS section_name,
                u.description,
                u.level,
                u.level_id,
                u.worker_scope,
                u.module,
                l.code AS level_code,
                l.name AS level_name,
                u.privilege_menu,
                u.is_active,
                u.last_login,
                u.created_at,
                u.updated_at
            FROM hr.users u
            LEFT JOIN hr.levels l
                ON l.id = u.level_id AND l.deleted_at IS NULL
            WHERE u.deleted_at IS NULL
              AND u.id = @ID
              AND u.by_jobsite = @Jobsite;
        END
        ELSE IF @ACTION_SP IN (N'INSERT', N'UPDATE')
        BEGIN
            SET @ResolvedLevel = NULLIF(LTRIM(RTRIM(@LEVEL)), N'');
            SET @ResolvedLevelId = @LEVEL_ID;

            -- Attribute inputs: NULL = leave as is, '' = clear, else validated value
            SET @WORKER_SCOPE = LOWER(LTRIM(RTRIM(@WORKER_SCOPE)));
            SET @MODULE = LOWER(LTRIM(RTRIM(@MODULE)));

            IF @WORKER_SCOPE IS NOT NULL AND @WORKER_SCOPE <> N''
               AND @WORKER_SCOPE NOT IN (N'sis', N'ls', N'all')
            BEGIN
                SELECT CAST(0 AS BIT) AS success,
                       N'worker_scope must be one of: sis, ls, all.' AS message;
                RETURN;
            END

            IF @MODULE IS NOT NULL AND @MODULE <> N''
               AND @MODULE NOT IN (N'irel', N'meals', N'safety', N'attendance')
            BEGIN
                SELECT CAST(0 AS BIT) AS success,
                       N'module must be one of: irel, meals, safety, attendance.' AS message;
                RETURN;
            END

            IF @ResolvedLevelId IS NOT NULL AND @ResolvedLevel IS NULL
            BEGIN
                -- Prefer the legacy code matching the chosen module / worker_scope,
                -- then the one named like the level, then the oldest mapping.
                SELECT TOP 1 @ResolvedLevel = m.legacy_code
                FROM hr.level_legacy_map m
                INNER JOIN hr.levels lv ON lv.id = m.level_id
                WHERE m.by_jobsite = @Jobsite
                  AND m.level_id = @ResolvedLevelId
                ORDER BY
                    CASE
                        WHEN m.module IS NOT NULL AND m.module = @MODULE THEN 0
                        WHEN m.worker_scope IS NOT NULL AND m.worker_scope = @WORKER_SCOPE THEN 0
                        WHEN m.legacy_code = lv.code THEN 1
                        ELSE 2
                    END,
                    m.id;
            END

            IF @ResolvedLevel IS NOT NULL AND @ResolvedLevelId IS NULL
            BEGIN
                SELECT TOP 1 @ResolvedLevelId = m.level_id
                FROM hr.level_legacy_map m
                WHERE m.by_jobsite = @Jobsite
                  AND m.legacy_code = @ResolvedLevel;
            END

            IF @ACTION_SP = N'INSERT'
            BEGIN
                IF @USERNAME IS NULL
                   OR LTRIM(RTRIM(@USERNAME)) = N''
                   OR @PASSWORD IS NULL
                   OR @FULL_NAME IS NULL
                   OR LTRIM(RTRIM(@FULL_NAME)) = N''
                   OR @ResolvedLevel IS NULL
                BEGIN
                    SELECT CAST(0 AS BIT) AS success,
                           N'Username, password, full name, and level (or level_id) are required.' AS message;
                    RETURN;
                END

                IF NOT EXISTS (
                    SELECT 1
                    FROM hr.menu_privilege
                    WHERE by_jobsite = @Jobsite
                      AND id = @ResolvedLevel
                      AND deleted_at IS NULL
                )
                BEGIN
                    SELECT CAST(0 AS BIT) AS success,
                           N'Legacy level not found in menu_privilege for this jobsite.' AS message;
                    RETURN;
                END

                IF @ResolvedLevelId IS NOT NULL AND NOT EXISTS (
                    SELECT 1 FROM hr.levels
                    WHERE id = @ResolvedLevelId
                      AND by_jobsite = @Jobsite
                      AND deleted_at IS NULL
                )
                BEGIN
                    SELECT CAST(0 AS BIT) AS success, N'Level not found for this jobsite.' AS message;
                    RETURN;
                END

                IF EXISTS (
                    SELECT 1 FROM hr.users
                    WHERE deleted_at IS NULL
                      AND by_jobsite = @Jobsite
                      AND username = LTRIM(RTRIM(@USERNAME))
                )
                BEGIN
                    SELECT CAST(0 AS BIT) AS success, N'Username already exists.' AS message;
                    RETURN;
                END

                -- Defaults implied by the legacy code, overridable by explicit input
                SELECT TOP 1
                    @ResolvedScope = m.worker_scope,
                    @ResolvedModule = m.module
                FROM hr.level_legacy_map m
                WHERE m.by_jobsite = @Jobsite
                  AND m.legacy_code = @ResolvedLevel;

                SET @ResolvedScope = CASE
                    WHEN @WORKER_SCOPE IS NULL THEN @ResolvedScope
                    ELSE NULLIF(@WORKER_SCOPE, N'')
                END;
                SET @ResolvedModule = CASE
                    WHEN @MODULE IS NULL THEN @ResolvedModule
                    ELSE NULLIF(@MODULE, N'')
                END;

                INSERT INTO hr.users (
                    by_jobsite, username, password, full_name, email, phone,
                    department, section, description, level, level_id,
                    worker_scope, module,
                    privilege_menu, is_active, created_by
                )
                VALUES (
                    @Jobsite,
                    LTRIM(RTRIM(@USERNAME)),
                    @PASSWORD,
                    LTRIM(RTRIM(@FULL_NAME)),
                    NULLIF(LTRIM(RTRIM(@EMAIL)), N''),
                    NULLIF(LTRIM(RTRIM(@PHONE)), N''),
                    NULLIF(LTRIM(RTRIM(@DEPARTMENT)), N''),
                    NULLIF(LTRIM(RTRIM(@SECTION)), N''),
                    @DESCRIPTION,
                    @ResolvedLevel,
                    @ResolvedLevelId,
                    @ResolvedScope,
                    @ResolvedModule,
                    @PRIVILEGE_MENU,
                    ISNULL(@IS_ACTIVE, 1),
                    @BY_USER
                );

                SELECT CAST(1 AS BIT) AS success,
                       N'User saved successfully.' AS message,
                       SCOPE_IDENTITY() AS id;
            END
            ELSE
            BEGIN
                SELECT @IDCHECK = id
                FROM hr.users
                WHERE deleted_at IS NULL
                  AND id = @ID
                  AND by_jobsite = @Jobsite;

                IF @IDCHECK IS NULL
                BEGIN
                    SELECT CAST(0 AS BIT) AS success, N'User not found.' AS message;
                    RETURN;
                END

                IF @USERNAME IS NOT NULL AND EXISTS (
                    SELECT 1 FROM hr.users
                    WHERE deleted_at IS NULL
                      AND by_jobsite = @Jobsite
                      AND username = LTRIM(RTRIM(@USERNAME))
                      AND id <> @IDCHECK
                )
                BEGIN
                    SELECT CAST(0 AS BIT) AS success, N'Username already exists.' AS message;
                    RETURN;
                END

                IF @ResolvedLevel IS NOT NULL AND NOT EXISTS (
                    SELECT 1
                    FROM hr.menu_privilege
                    WHERE by_jobsite = @Jobsite
                      AND id = @ResolvedLevel
                      AND deleted_at IS NULL
                )
                BEGIN
                    SELECT CAST(0 AS BIT) AS success,
                           N'Legacy level not found in menu_privilege for this jobsite.' AS message;
                    RETURN;
                END

                IF @ResolvedLevelId IS NOT NULL AND NOT EXISTS (
                    SELECT 1 FROM hr.levels
                    WHERE id = @ResolvedLevelId
                      AND by_jobsite = @Jobsite
                      AND deleted_at IS NULL
                )
                BEGIN
                    SELECT CAST(0 AS BIT) AS success, N'Level not found for this jobsite.' AS message;
                    RETURN;
                END

                UPDATE hr.users
                SET
                    username = CASE
                        WHEN @USERNAME IS NULL OR LTRIM(RTRIM(@USERNAME)) = N'' THEN username
                        ELSE LTRIM(RTRIM(@USERNAME))
                    END,
                    password = ISNULL(@PASSWORD, password),
                    full_name = CASE
                        WHEN @FULL_NAME IS NULL OR LTRIM(RTRIM(@FULL_NAME)) = N'' THEN full_name
                        ELSE LTRIM(RTRIM(@FULL_NAME))
                    END,
                    email = CASE WHEN @EMAIL IS NULL THEN email ELSE NULLIF(LTRIM(RTRIM(@EMAIL)), N'') END,
                    phone = CASE WHEN @PHONE IS NULL THEN phone ELSE NULLIF(LTRIM(RTRIM(@PHONE)), N'') END,
                    department = CASE
                        WHEN @DEPARTMENT IS NULL THEN department
                        ELSE NULLIF(LTRIM(RTRIM(@DEPARTMENT)), N'')
                    END,
                    section = CASE
                        WHEN @SECTION IS NULL THEN section
                        ELSE NULLIF(LTRIM(RTRIM(@SECTION)), N'')
                    END,
                    description = CASE WHEN @DESCRIPTION IS NULL THEN description ELSE @DESCRIPTION END,
                    level = ISNULL(@ResolvedLevel, level),
                    level_id = ISNULL(@ResolvedLevelId, level_id),
                    worker_scope = CASE
                        WHEN @WORKER_SCOPE IS NULL THEN worker_scope
                        ELSE NULLIF(@WORKER_SCOPE, N'')
                    END,
                    module = CASE
                        WHEN @MODULE IS NULL THEN module
                        ELSE NULLIF(@MODULE, N'')
                    END,
                    privilege_menu = CASE
                        WHEN @PRIVILEGE_MENU IS NULL THEN privilege_menu
                        ELSE @PRIVILEGE_MENU
                    END,
                    is_active = ISNULL(@IS_ACTIVE, is_active),
                    updated_at = SYSUTCDATETIME(),
                    updated_by = @BY_USER
                WHERE id = @IDCHECK;

                SELECT CAST(1 AS BIT) AS success, N'User updated successfully.' AS message;
            END
        END
        ELSE IF @ACTION_SP = N'RESET_PASSWORD'
        BEGIN
            IF @PASSWORD IS NULL OR LTRIM(RTRIM(@PASSWORD)) = N''
            BEGIN
                SELECT CAST(0 AS BIT) AS success, N'Password hash is required.' AS message;
                RETURN;
            END

            SELECT @IDCHECK = id
            FROM hr.users
            WHERE deleted_at IS NULL
              AND id = @ID
              AND by_jobsite = @Jobsite;

            IF @IDCHECK IS NULL
            BEGIN
                SELECT CAST(0 AS BIT) AS success, N'User not found.' AS message;
                RETURN;
            END

            UPDATE hr.users
            SET password = @PASSWORD,
                updated_at = SYSUTCDATETIME(),
                updated_by = @BY_USER
            WHERE id = @IDCHECK;

            SELECT CAST(1 AS BIT) AS success,
                   N'Password reset successfully. Default password is the username.' AS message;
        END
        ELSE IF @ACTION_SP = N'DELETE'
        BEGIN
            SELECT @IDCHECK = id
            FROM hr.users
            WHERE deleted_at IS NULL
              AND id = @ID
              AND by_jobsite = @Jobsite;

            IF @IDCHECK IS NULL
            BEGIN
                SELECT CAST(0 AS BIT) AS success, N'User not found.' AS message;
                RETURN;
            END

            UPDATE hr.users
            SET deleted_at = SYSUTCDATETIME(),
                deleted_by = @BY_USER,
                is_active = 0,
                updated_at = SYSUTCDATETIME(),
                updated_by = @BY_USER
            WHERE id = @IDCHECK;

            SELECT CAST(1 AS BIT) AS success, N'User deleted successfully.' AS message;
        END
        ELSE
        BEGIN
            SELECT CAST(0 AS BIT) AS success, N'Unknown ACTION_SP.' AS message;
        END
    END TRY
    BEGIN CATCH
        SELECT
            CAST(0 AS BIT) AS success,
            N'Failed to process user data.' AS message,
            ERROR_NUMBER() AS error_number,
            ERROR_MESSAGE() AS error_message;
    END CATCH
END
GO
