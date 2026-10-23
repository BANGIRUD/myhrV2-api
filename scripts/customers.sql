-- =============================================
-- Table: customers + CUSTOMERS_SP
-- Ticket requesters. password_hash stays NULL for guests;
-- customer accounts (login) are a later phase.
-- =============================================
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'ticketing')
    EXEC('CREATE SCHEMA ticketing');
GO

IF OBJECT_ID('ticketing.customers', 'U') IS NULL
BEGIN
    CREATE TABLE ticketing.customers (
        id INT IDENTITY(1,1) NOT NULL,
        email VARCHAR(255) NOT NULL,
        name VARCHAR(150) NOT NULL,
        phone VARCHAR(30) NULL,
        password_hash VARCHAR(255) NULL,
        is_verified BIT NOT NULL CONSTRAINT DF_customers_is_verified DEFAULT (0),
        created_at DATETIME NOT NULL CONSTRAINT DF_customers_created_at DEFAULT (GETDATE()),
        created_by VARCHAR(20) NULL,
        updated_at DATETIME NULL,
        updated_by VARCHAR(20) NULL,
        deleted_at DATETIME NULL,
        deleted_by VARCHAR(20) NULL,
        by_jobsite INT NULL,
        CONSTRAINT PK_customers PRIMARY KEY CLUSTERED (id)
    );

    -- Allow email reuse after soft delete
    CREATE UNIQUE INDEX UQ_customers_email_active
        ON ticketing.customers (email)
        WHERE deleted_at IS NULL;
END
GO

-- =============================================
-- CUSTOMERS_SP
-- Actions: SELECT | GET | GET_BY_EMAIL | INSERT | UPDATE | DELETE
-- =============================================
CREATE OR ALTER PROCEDURE ticketing.CUSTOMERS_SP
    @ACTION_SP VARCHAR(20) = NULL,
    @ID INT = NULL,
    @EMAIL VARCHAR(255) = NULL,
    @NAME VARCHAR(150) = NULL,
    @PHONE VARCHAR(30) = NULL,
    @IS_VERIFIED BIT = NULL,
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
                c.id,
                c.email,
                c.name,
                c.phone,
                c.is_verified,
                c.by_jobsite,
                c.created_at,
                c.updated_at,
                (SELECT COUNT(*) FROM ticketing.tickets t
                  WHERE t.customer_id = c.id AND t.deleted_at IS NULL) AS ticket_count
            FROM ticketing.customers c
            WHERE c.deleted_at IS NULL
              AND (@BY_JOBSITE IS NULL OR c.by_jobsite = @BY_JOBSITE OR c.by_jobsite IS NULL)
              AND (
                    @SEARCH IS NULL
                 OR LTRIM(RTRIM(@SEARCH)) = ''
                 OR c.name LIKE '%' + @SEARCH + '%'
                 OR c.email LIKE '%' + @SEARCH + '%'
                 OR c.phone LIKE '%' + @SEARCH + '%'
              )
            ORDER BY c.name
            OFFSET CASE WHEN @PAGE_SIZE > 0 THEN (@PAGE - 1) * @PAGE_SIZE ELSE 0 END ROWS
            FETCH NEXT CASE WHEN @PAGE_SIZE > 0 THEN @PAGE_SIZE ELSE 100000 END ROWS ONLY;

            SELECT COUNT(*) AS total_count
            FROM ticketing.customers c
            WHERE c.deleted_at IS NULL
              AND (@BY_JOBSITE IS NULL OR c.by_jobsite = @BY_JOBSITE OR c.by_jobsite IS NULL)
              AND (
                    @SEARCH IS NULL
                 OR LTRIM(RTRIM(@SEARCH)) = ''
                 OR c.name LIKE '%' + @SEARCH + '%'
                 OR c.email LIKE '%' + @SEARCH + '%'
                 OR c.phone LIKE '%' + @SEARCH + '%'
              );
        END
        ELSE IF @ACTION_SP = 'GET'
        BEGIN
            SELECT
                c.id, c.email, c.name, c.phone, c.is_verified,
                c.by_jobsite, c.created_at, c.updated_at
            FROM ticketing.customers c
            WHERE c.deleted_at IS NULL
              AND c.id = @ID
              AND (@BY_JOBSITE IS NULL OR c.by_jobsite = @BY_JOBSITE OR c.by_jobsite IS NULL);
        END
        ELSE IF @ACTION_SP = 'GET_BY_EMAIL'
        BEGIN
            SELECT
                c.id, c.email, c.name, c.phone, c.is_verified,
                c.by_jobsite, c.created_at, c.updated_at
            FROM ticketing.customers c
            WHERE c.deleted_at IS NULL
              AND c.email = @EMAIL
              AND (@BY_JOBSITE IS NULL OR c.by_jobsite = @BY_JOBSITE OR c.by_jobsite IS NULL);
        END
        ELSE IF @ACTION_SP = 'INSERT'
        BEGIN
            IF @EMAIL IS NULL OR @NAME IS NULL
            BEGIN
                SELECT CAST(0 AS BIT) AS success, 'Email and name are required.' AS message;
                RETURN;
            END

            IF EXISTS (SELECT 1 FROM ticketing.customers WHERE deleted_at IS NULL AND email = @EMAIL)
            BEGIN
                SELECT CAST(0 AS BIT) AS success, 'Email already exists.' AS message;
                RETURN;
            END

            INSERT INTO ticketing.customers (email, name, phone, is_verified, created_by, by_jobsite)
            VALUES (@EMAIL, @NAME, @PHONE, ISNULL(@IS_VERIFIED, 0), @BY_USER, @BY_JOBSITE);

            SELECT CAST(1 AS BIT) AS success, 'Customer saved successfully.' AS message, SCOPE_IDENTITY() AS id;
        END
        ELSE IF @ACTION_SP = 'UPDATE'
        BEGIN
            SELECT @IDCHECK = id
            FROM ticketing.customers
            WHERE deleted_at IS NULL
              AND id = @ID
              AND (@BY_JOBSITE IS NULL OR by_jobsite = @BY_JOBSITE OR by_jobsite IS NULL);
            IF @IDCHECK IS NULL
            BEGIN
                SELECT CAST(0 AS BIT) AS success, 'Customer not found.' AS message;
                RETURN;
            END

            IF @EMAIL IS NOT NULL AND EXISTS (
                SELECT 1 FROM ticketing.customers
                WHERE deleted_at IS NULL AND email = @EMAIL AND id <> @IDCHECK
            )
            BEGIN
                SELECT CAST(0 AS BIT) AS success, 'Email already exists.' AS message;
                RETURN;
            END

            UPDATE ticketing.customers
            SET
                email = ISNULL(@EMAIL, email),
                name = ISNULL(@NAME, name),
                phone = ISNULL(@PHONE, phone),
                is_verified = ISNULL(@IS_VERIFIED, is_verified),
                updated_at = GETDATE(),
                updated_by = @BY_USER
            WHERE id = @IDCHECK;

            SELECT CAST(1 AS BIT) AS success, 'Customer updated successfully.' AS message;
        END
        ELSE IF @ACTION_SP = 'DELETE'
        BEGIN
            SELECT @IDCHECK = id
            FROM ticketing.customers
            WHERE deleted_at IS NULL
              AND id = @ID
              AND (@BY_JOBSITE IS NULL OR by_jobsite = @BY_JOBSITE OR by_jobsite IS NULL);
            IF @IDCHECK IS NULL
            BEGIN
                SELECT CAST(0 AS BIT) AS success, 'Customer not found.' AS message;
                RETURN;
            END

            IF EXISTS (
                SELECT 1 FROM ticketing.tickets
                WHERE deleted_at IS NULL AND customer_id = @IDCHECK
            )
            BEGIN
                SELECT CAST(0 AS BIT) AS success, 'Customer still has active tickets.' AS message;
                RETURN;
            END

            UPDATE ticketing.customers
            SET deleted_at = GETDATE(), deleted_by = @BY_USER
            WHERE id = @IDCHECK;

            SELECT CAST(1 AS BIT) AS success, 'Customer deleted successfully.' AS message;
        END
        ELSE
        BEGIN
            SELECT 1;
        END
    END TRY
    BEGIN CATCH
        SELECT
            CAST(0 AS BIT) AS success,
            'Failed to process customer data.' AS message,
            ERROR_NUMBER() AS error_number,
            ERROR_MESSAGE() AS error_message;
    END CATCH
END
GO
