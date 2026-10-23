-- =============================================
-- Table: users (staff) + USERS_SP
-- Levels are enums rows (type = 'level'); users.level_id -> enums.id
-- Run AFTER enums.sql (needs ticketing.enums for level join + seed)
-- =============================================
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'ticketing')
    EXEC('CREATE SCHEMA ticketing');
GO

IF OBJECT_ID('ticketing.users', 'U') IS NULL
BEGIN
    CREATE TABLE ticketing.users (
        id INT IDENTITY(1,1) NOT NULL,
        username VARCHAR(100) NOT NULL,
        password VARCHAR(255) NOT NULL,
        nrp VARCHAR(30) NULL,
        first_name VARCHAR(100) NULL,
        last_name VARCHAR(100) NULL,
        nama_lengkap VARCHAR(150) NOT NULL,
        email VARCHAR(255) NULL,
        phone VARCHAR(30) NULL,
        level_id INT NOT NULL,
        is_active BIT NOT NULL CONSTRAINT DF_users_is_active DEFAULT (1),
        created_at DATETIME NOT NULL CONSTRAINT DF_users_created_at DEFAULT (GETDATE()),
        created_by VARCHAR(20) NULL,
        updated_at DATETIME NULL,
        updated_by VARCHAR(20) NULL,
        deleted_at DATETIME NULL,
        deleted_by VARCHAR(20) NULL,
        by_jobsite INT NULL,
        CONSTRAINT PK_users PRIMARY KEY CLUSTERED (id)
    );

    -- Allow username reuse after soft delete
    CREATE UNIQUE INDEX UQ_users_username_active
        ON ticketing.users (username)
        WHERE deleted_at IS NULL;
END
GO

-- =============================================
-- USERS_SP
-- Actions: SELECT | GET | GET_BY_USERNAME | INSERT | UPDATE | UPDATE_PROFILE | DELETE
-- GET_BY_USERNAME is the only action returning the password hash (login).
-- =============================================
CREATE OR ALTER PROCEDURE ticketing.USERS_SP
    @ACTION_SP VARCHAR(30) = NULL,
    @ID INT = NULL,
    @USERNAME VARCHAR(100) = NULL,
    @PASSWORD VARCHAR(255) = NULL,
    @NRP VARCHAR(30) = NULL,
    @FIRST_NAME VARCHAR(100) = NULL,
    @LAST_NAME VARCHAR(100) = NULL,
    @NAMA_LENGKAP VARCHAR(150) = NULL,
    @EMAIL VARCHAR(255) = NULL,
    @PHONE VARCHAR(30) = NULL,
    @LEVEL_ID INT = NULL,
    @IS_ACTIVE BIT = NULL,
    @PAGE INT = 1,
    @PAGE_SIZE INT = 0,
    @SEARCH VARCHAR(150) = NULL,
    @BY_USER VARCHAR(20) = NULL,
    @BY_JOBSITE INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @IDCHECK INT;

    BEGIN TRY
        IF @ACTION_SP = 'SELECT'
        BEGIN
            IF @PAGE IS NULL OR @PAGE < 1
                SET @PAGE = 1;

            IF @PAGE_SIZE IS NULL
                SET @PAGE_SIZE = 0;

            SELECT
                u.id,
                u.username,
                u.nrp,
                u.first_name,
                u.last_name,
                u.nama_lengkap,
                u.email,
                u.phone,
                u.level_id,
                l.code AS level_code,
                l.name AS level_name,
                u.is_active,
                u.by_jobsite,
                u.created_at,
                u.updated_at
            FROM ticketing.users u
            LEFT JOIN ticketing.enums l
                ON l.id = u.level_id AND l.deleted_at IS NULL
            WHERE u.deleted_at IS NULL
              AND (@BY_JOBSITE IS NULL OR u.by_jobsite = @BY_JOBSITE OR u.by_jobsite IS NULL)
              AND (@LEVEL_ID IS NULL OR u.level_id = @LEVEL_ID)
              AND (@IS_ACTIVE IS NULL OR u.is_active = @IS_ACTIVE)
              AND (
                    @SEARCH IS NULL
                 OR LTRIM(RTRIM(@SEARCH)) = ''
                 OR u.username LIKE '%' + @SEARCH + '%'
                 OR u.nama_lengkap LIKE '%' + @SEARCH + '%'
                 OR u.nrp LIKE '%' + @SEARCH + '%'
                 OR u.email LIKE '%' + @SEARCH + '%'
              )
            ORDER BY u.nama_lengkap
            OFFSET CASE WHEN @PAGE_SIZE > 0 THEN (@PAGE - 1) * @PAGE_SIZE ELSE 0 END ROWS
            FETCH NEXT CASE WHEN @PAGE_SIZE > 0 THEN @PAGE_SIZE ELSE 100000 END ROWS ONLY;

            SELECT COUNT(*) AS total_count
            FROM ticketing.users u
            WHERE u.deleted_at IS NULL
              AND (@BY_JOBSITE IS NULL OR u.by_jobsite = @BY_JOBSITE OR u.by_jobsite IS NULL)
              AND (@LEVEL_ID IS NULL OR u.level_id = @LEVEL_ID)
              AND (@IS_ACTIVE IS NULL OR u.is_active = @IS_ACTIVE)
              AND (
                    @SEARCH IS NULL
                 OR LTRIM(RTRIM(@SEARCH)) = ''
                 OR u.username LIKE '%' + @SEARCH + '%'
                 OR u.nama_lengkap LIKE '%' + @SEARCH + '%'
                 OR u.nrp LIKE '%' + @SEARCH + '%'
                 OR u.email LIKE '%' + @SEARCH + '%'
              );
        END
        ELSE IF @ACTION_SP = 'GET'
        BEGIN
            SELECT
                u.id,
                u.username,
                u.nrp,
                u.first_name,
                u.last_name,
                u.nama_lengkap,
                u.email,
                u.phone,
                u.level_id,
                l.code AS level_code,
                l.name AS level_name,
                u.is_active,
                u.by_jobsite,
                u.created_at,
                u.updated_at
            FROM ticketing.users u
            LEFT JOIN ticketing.enums l
                ON l.id = u.level_id AND l.deleted_at IS NULL
            WHERE u.deleted_at IS NULL
              AND u.id = @ID;
        END
        ELSE IF @ACTION_SP = 'GET_BY_USERNAME'
        BEGIN
            SELECT
                u.id,
                u.username,
                u.password,
                u.nrp,
                u.first_name,
                u.last_name,
                u.nama_lengkap,
                u.email,
                u.phone,
                u.level_id,
                l.code AS level_code,
                l.name AS level_name,
                u.by_jobsite
            FROM ticketing.users u
            LEFT JOIN ticketing.enums l
                ON l.id = u.level_id AND l.deleted_at IS NULL
            WHERE u.deleted_at IS NULL
              AND u.is_active = 1
              AND u.username = @USERNAME;
        END
        ELSE IF @ACTION_SP = 'INSERT'
        BEGIN
            IF @USERNAME IS NULL OR @PASSWORD IS NULL OR @NAMA_LENGKAP IS NULL OR @LEVEL_ID IS NULL
            BEGIN
                SELECT CAST(0 AS BIT) AS success, 'Username, password, full name, and level are required.' AS message;
                RETURN;
            END

            IF EXISTS (SELECT 1 FROM ticketing.users WHERE deleted_at IS NULL AND username = @USERNAME)
            BEGIN
                SELECT CAST(0 AS BIT) AS success, 'Username already exists.' AS message;
                RETURN;
            END

            INSERT INTO ticketing.users (
                username, password, nrp, first_name, last_name, nama_lengkap,
                email, phone, level_id, is_active, created_by, by_jobsite
            ) VALUES (
                @USERNAME, @PASSWORD, @NRP, @FIRST_NAME, @LAST_NAME, @NAMA_LENGKAP,
                @EMAIL, @PHONE, @LEVEL_ID, ISNULL(@IS_ACTIVE, 1), @BY_USER, @BY_JOBSITE
            );

            SELECT CAST(1 AS BIT) AS success, 'User saved successfully.' AS message, SCOPE_IDENTITY() AS id;
        END
        ELSE IF @ACTION_SP = 'UPDATE'
        BEGIN
            SELECT @IDCHECK = id FROM ticketing.users WHERE deleted_at IS NULL AND id = @ID;
            IF @IDCHECK IS NULL
            BEGIN
                SELECT CAST(0 AS BIT) AS success, 'User not found.' AS message;
                RETURN;
            END

            IF @USERNAME IS NOT NULL AND EXISTS (
                SELECT 1 FROM ticketing.users
                WHERE deleted_at IS NULL AND username = @USERNAME AND id <> @IDCHECK
            )
            BEGIN
                SELECT CAST(0 AS BIT) AS success, 'Username already exists.' AS message;
                RETURN;
            END

            UPDATE ticketing.users
            SET
                username = ISNULL(@USERNAME, username),
                password = ISNULL(@PASSWORD, password),
                nrp = ISNULL(@NRP, nrp),
                first_name = ISNULL(@FIRST_NAME, first_name),
                last_name = ISNULL(@LAST_NAME, last_name),
                nama_lengkap = ISNULL(@NAMA_LENGKAP, nama_lengkap),
                email = ISNULL(@EMAIL, email),
                phone = ISNULL(@PHONE, phone),
                level_id = ISNULL(@LEVEL_ID, level_id),
                is_active = ISNULL(@IS_ACTIVE, is_active),
                updated_at = GETDATE(),
                updated_by = @BY_USER
            WHERE id = @IDCHECK;

            SELECT CAST(1 AS BIT) AS success, 'User updated successfully.' AS message;
        END
        ELSE IF @ACTION_SP = 'UPDATE_PROFILE'
        BEGIN
            SELECT @IDCHECK = id FROM ticketing.users WHERE deleted_at IS NULL AND id = @ID;
            IF @IDCHECK IS NULL
            BEGIN
                SELECT CAST(0 AS BIT) AS success, 'User not found.' AS message;
                RETURN;
            END

            IF @USERNAME IS NOT NULL AND EXISTS (
                SELECT 1 FROM ticketing.users
                WHERE deleted_at IS NULL AND username = @USERNAME AND id <> @IDCHECK
            )
            BEGIN
                SELECT CAST(0 AS BIT) AS success, 'Username already exists.' AS message;
                RETURN;
            END

            UPDATE ticketing.users
            SET
                username = ISNULL(@USERNAME, username),
                nrp = ISNULL(@NRP, nrp),
                email = ISNULL(@EMAIL, email),
                phone = ISNULL(@PHONE, phone),
                password = ISNULL(@PASSWORD, password),
                updated_at = GETDATE(),
                updated_by = @BY_USER
            WHERE id = @IDCHECK;

            SELECT CAST(1 AS BIT) AS success, 'Profile updated successfully.' AS message;
        END
        ELSE IF @ACTION_SP = 'DELETE'
        BEGIN
            SELECT @IDCHECK = id FROM ticketing.users WHERE deleted_at IS NULL AND id = @ID;
            IF @IDCHECK IS NULL
            BEGIN
                SELECT CAST(0 AS BIT) AS success, 'User not found.' AS message;
                RETURN;
            END

            UPDATE ticketing.users
            SET deleted_at = GETDATE(), deleted_by = @BY_USER, is_active = 0
            WHERE id = @IDCHECK;

            SELECT CAST(1 AS BIT) AS success, 'User deleted successfully.' AS message;
        END
        ELSE
        BEGIN
            SELECT 1;
        END
    END TRY
    BEGIN CATCH
        SELECT
            CAST(0 AS BIT) AS success,
            'Failed to process user data.' AS message,
            ERROR_NUMBER() AS error_number,
            ERROR_MESSAGE() AS error_message;
    END CATCH
END
GO

-- =============================================
-- Seed: superadmin user
-- 1) Generate a bcrypt hash first:
--      node scripts/hash-password.js "YourStrongPassword"
-- 2) Replace <BCRYPT_HASH> below, then run this block.
--    (With the placeholder left in place, login stays impossible.)
-- =============================================
DECLARE @level_id INT = (
    SELECT TOP 1 id FROM ticketing.enums
    WHERE deleted_at IS NULL AND type = 'level' AND code = 'superadmin'
);

IF @level_id IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM ticketing.users WHERE deleted_at IS NULL AND username = 'superadmin')
BEGIN
    INSERT INTO ticketing.users (
        username, password, nama_lengkap, level_id, is_active, created_by, by_jobsite
    )
    VALUES (
        'superadmin', '<BCRYPT_HASH>', 'Super Admin', @level_id, 1, 'system', 1
    );
END
GO
