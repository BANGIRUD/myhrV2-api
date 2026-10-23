-- =============================================
-- Tables: tickets, ticket_replies, ticket_attachments, ticket_history
-- SPs: TICKETS_SP, TICKET_REPLIES_SP, TICKET_ATTACHMENTS_SP
-- Lookups are enums rows:
--   ticket_status | ticket_priority | ticket_category (seed_ticket_enums.sql)
-- Run AFTER enums.sql, customers.sql, seed_ticket_enums.sql
-- =============================================
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'ticketing')
    EXEC('CREATE SCHEMA ticketing');
GO

IF OBJECT_ID('ticketing.tickets', 'U') IS NULL
BEGIN
    CREATE TABLE ticketing.tickets (
        id INT IDENTITY(1,1) NOT NULL,
        tracking_id VARCHAR(20) NOT NULL,
        customer_id INT NOT NULL,
        category_id INT NOT NULL,
        priority_id INT NOT NULL,
        status_id INT NOT NULL,
        subject VARCHAR(255) NOT NULL,
        message VARCHAR(MAX) NOT NULL,
        owner_user_id INT NULL,
        due_date DATETIME NULL,
        last_reply_by VARCHAR(10) NULL,   -- 'customer' | 'staff'
        last_reply_at DATETIME NULL,
        resolved_at DATETIME NULL,
        created_at DATETIME NOT NULL CONSTRAINT DF_tickets_created_at DEFAULT (GETDATE()),
        created_by VARCHAR(20) NULL,
        updated_at DATETIME NULL,
        updated_by VARCHAR(20) NULL,
        deleted_at DATETIME NULL,
        deleted_by VARCHAR(20) NULL,
        by_jobsite INT NULL,
        CONSTRAINT PK_tickets PRIMARY KEY CLUSTERED (id),
        CONSTRAINT UQ_tickets_tracking UNIQUE (tracking_id),
        CONSTRAINT FK_tickets_customer
            FOREIGN KEY (customer_id) REFERENCES ticketing.customers (id)
    );

    CREATE INDEX IX_tickets_customer ON ticketing.tickets (customer_id, deleted_at);
    CREATE INDEX IX_tickets_status ON ticketing.tickets (status_id, deleted_at);
    CREATE INDEX IX_tickets_owner ON ticketing.tickets (owner_user_id, deleted_at);
END
GO

IF OBJECT_ID('ticketing.ticket_replies', 'U') IS NULL
BEGIN
    CREATE TABLE ticketing.ticket_replies (
        id INT IDENTITY(1,1) NOT NULL,
        ticket_id INT NOT NULL,
        sender_type VARCHAR(10) NOT NULL,  -- 'customer' | 'staff'
        customer_id INT NULL,
        user_id INT NULL,
        message VARCHAR(MAX) NOT NULL,
        created_at DATETIME NOT NULL CONSTRAINT DF_replies_created_at DEFAULT (GETDATE()),
        deleted_at DATETIME NULL,
        deleted_by VARCHAR(20) NULL,
        CONSTRAINT PK_ticket_replies PRIMARY KEY CLUSTERED (id),
        CONSTRAINT FK_replies_ticket
            FOREIGN KEY (ticket_id) REFERENCES ticketing.tickets (id)
    );

    CREATE INDEX IX_replies_ticket ON ticketing.ticket_replies (ticket_id, created_at);
END
GO

IF OBJECT_ID('ticketing.ticket_attachments', 'U') IS NULL
BEGIN
    CREATE TABLE ticketing.ticket_attachments (
        id INT IDENTITY(1,1) NOT NULL,
        ticket_id INT NOT NULL,
        reply_id INT NULL,                     -- NULL = attachment of the opening message
        file_name VARCHAR(255) NOT NULL,       -- original name
        stored_name VARCHAR(255) NOT NULL,     -- unique name on disk (private dir, NOT /public)
        mime_type VARCHAR(100) NULL,
        file_size INT NULL,
        uploaded_by_type VARCHAR(10) NOT NULL, -- 'customer' | 'staff'
        created_at DATETIME NOT NULL CONSTRAINT DF_attachments_created_at DEFAULT (GETDATE()),
        deleted_at DATETIME NULL,
        deleted_by VARCHAR(20) NULL,
        CONSTRAINT PK_ticket_attachments PRIMARY KEY CLUSTERED (id),
        CONSTRAINT FK_attachments_ticket
            FOREIGN KEY (ticket_id) REFERENCES ticketing.tickets (id)
    );

    CREATE INDEX IX_attachments_ticket ON ticketing.ticket_attachments (ticket_id, deleted_at);
END
GO

IF OBJECT_ID('ticketing.ticket_attachments', 'U') IS NOT NULL
   AND NOT EXISTS (
       SELECT 1
       FROM sys.foreign_keys
       WHERE name = 'FK_attachments_reply'
         AND parent_object_id = OBJECT_ID('ticketing.ticket_attachments')
   )
BEGIN
    ALTER TABLE ticketing.ticket_attachments
        ADD CONSTRAINT FK_attachments_reply
        FOREIGN KEY (reply_id) REFERENCES ticketing.ticket_replies (id);
END
GO

IF OBJECT_ID('ticketing.ticket_history', 'U') IS NULL
BEGIN
    CREATE TABLE ticketing.ticket_history (
        id INT IDENTITY(1,1) NOT NULL,
        ticket_id INT NOT NULL,
        action VARCHAR(50) NOT NULL,       -- created | status_changed | assigned | replied | updated
        old_value VARCHAR(255) NULL,
        new_value VARCHAR(255) NULL,
        actor_type VARCHAR(10) NOT NULL,   -- 'customer' | 'staff' | 'system'
        actor_id INT NULL,
        created_at DATETIME NOT NULL CONSTRAINT DF_history_created_at DEFAULT (GETDATE()),
        CONSTRAINT PK_ticket_history PRIMARY KEY CLUSTERED (id),
        CONSTRAINT FK_history_ticket
            FOREIGN KEY (ticket_id) REFERENCES ticketing.tickets (id)
    );

    CREATE INDEX IX_history_ticket ON ticketing.ticket_history (ticket_id, created_at);
END
GO

-- =============================================
-- TICKETS_SP
-- Actions:
--   SELECT           staff list (filters + paging, jobsite-scoped)
--   GET              staff detail by @ID
--   GET_BY_TRACKING  public/customer detail by @TRACKING_ID + @EMAIL
--   INSERT           create ticket (find-or-create customer by email)
--   UPDATE           staff update (status/priority/category/owner/due date)
--   DELETE           soft delete
-- =============================================
CREATE OR ALTER PROCEDURE ticketing.TICKETS_SP
    @ACTION_SP VARCHAR(30) = NULL,
    @ID INT = NULL,
    @TRACKING_ID VARCHAR(20) = NULL,
    @EMAIL VARCHAR(255) = NULL,
    @CUSTOMER_NAME VARCHAR(150) = NULL,
    @CUSTOMER_PHONE VARCHAR(30) = NULL,
    @CATEGORY_ID INT = NULL,
    @PRIORITY_ID INT = NULL,
    @STATUS_ID INT = NULL,
    @SUBJECT VARCHAR(255) = NULL,
    @MESSAGE VARCHAR(MAX) = NULL,
    @OWNER_USER_ID INT = NULL,
    @DUE_DATE DATETIME = NULL,
    @PAGE INT = 1,
    @PAGE_SIZE INT = 0,
    @SEARCH VARCHAR(150) = NULL,
    @BY_USER VARCHAR(20) = NULL,
    @BY_JOBSITE INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @IDCHECK INT;
    DECLARE @CUSTOMER_ID INT;
    DECLARE @TRACK VARCHAR(20);
    DECLARE @OLD_STATUS_ID INT;
    DECLARE @OLD_OWNER_ID INT;
    DECLARE @RESOLVED_ID INT;

    BEGIN TRY
        IF @ACTION_SP = 'SELECT'
        BEGIN
            IF @PAGE IS NULL OR @PAGE < 1
                SET @PAGE = 1;

            IF @PAGE_SIZE IS NULL
                SET @PAGE_SIZE = 0;

            SELECT
                t.id,
                t.tracking_id,
                t.subject,
                t.customer_id,
                c.name AS customer_name,
                c.email AS customer_email,
                t.category_id,
                cat.name AS category_name,
                t.priority_id,
                pri.code AS priority_code,
                pri.name AS priority_name,
                t.status_id,
                st.code AS status_code,
                st.name AS status_name,
                t.owner_user_id,
                own.nama_lengkap AS owner_name,
                t.due_date,
                t.last_reply_by,
                t.last_reply_at,
                t.created_at,
                t.by_jobsite
            FROM ticketing.tickets t
            INNER JOIN ticketing.customers c ON c.id = t.customer_id
            LEFT JOIN ticketing.enums cat ON cat.id = t.category_id
            LEFT JOIN ticketing.enums pri ON pri.id = t.priority_id
            LEFT JOIN ticketing.enums st ON st.id = t.status_id
            LEFT JOIN ticketing.users own ON own.id = t.owner_user_id AND own.deleted_at IS NULL
            WHERE t.deleted_at IS NULL
              AND (@BY_JOBSITE IS NULL OR t.by_jobsite = @BY_JOBSITE OR t.by_jobsite IS NULL)
              AND (@STATUS_ID IS NULL OR t.status_id = @STATUS_ID)
              AND (@PRIORITY_ID IS NULL OR t.priority_id = @PRIORITY_ID)
              AND (@CATEGORY_ID IS NULL OR t.category_id = @CATEGORY_ID)
              AND (@OWNER_USER_ID IS NULL OR t.owner_user_id = @OWNER_USER_ID)
              AND (
                    @SEARCH IS NULL
                 OR LTRIM(RTRIM(@SEARCH)) = ''
                 OR t.tracking_id LIKE '%' + @SEARCH + '%'
                 OR t.subject LIKE '%' + @SEARCH + '%'
                 OR c.name LIKE '%' + @SEARCH + '%'
                 OR c.email LIKE '%' + @SEARCH + '%'
              )
            ORDER BY t.created_at DESC
            OFFSET CASE WHEN @PAGE_SIZE > 0 THEN (@PAGE - 1) * @PAGE_SIZE ELSE 0 END ROWS
            FETCH NEXT CASE WHEN @PAGE_SIZE > 0 THEN @PAGE_SIZE ELSE 100000 END ROWS ONLY;

            SELECT COUNT(*) AS total_count
            FROM ticketing.tickets t
            INNER JOIN ticketing.customers c ON c.id = t.customer_id
            WHERE t.deleted_at IS NULL
              AND (@BY_JOBSITE IS NULL OR t.by_jobsite = @BY_JOBSITE OR t.by_jobsite IS NULL)
              AND (@STATUS_ID IS NULL OR t.status_id = @STATUS_ID)
              AND (@PRIORITY_ID IS NULL OR t.priority_id = @PRIORITY_ID)
              AND (@CATEGORY_ID IS NULL OR t.category_id = @CATEGORY_ID)
              AND (@OWNER_USER_ID IS NULL OR t.owner_user_id = @OWNER_USER_ID)
              AND (
                    @SEARCH IS NULL
                 OR LTRIM(RTRIM(@SEARCH)) = ''
                 OR t.tracking_id LIKE '%' + @SEARCH + '%'
                 OR t.subject LIKE '%' + @SEARCH + '%'
                 OR c.name LIKE '%' + @SEARCH + '%'
                 OR c.email LIKE '%' + @SEARCH + '%'
              );
        END
        ELSE IF @ACTION_SP = 'GET' OR @ACTION_SP = 'GET_BY_TRACKING'
        BEGIN
            IF @ACTION_SP = 'GET_BY_TRACKING'
            BEGIN
                -- Public path: both tracking id and matching customer email required
                SELECT @IDCHECK = t.id
                FROM ticketing.tickets t
                INNER JOIN ticketing.customers c ON c.id = t.customer_id
                WHERE t.deleted_at IS NULL
                  AND t.tracking_id = @TRACKING_ID
                  AND c.email = @EMAIL
                  AND (@BY_JOBSITE IS NULL OR t.by_jobsite = @BY_JOBSITE);

                IF @IDCHECK IS NULL
                BEGIN
                    SELECT CAST(0 AS BIT) AS success, 'Ticket not found.' AS message;
                    RETURN;
                END
            END
            ELSE
                SET @IDCHECK = @ID;

            SELECT
                t.id,
                t.tracking_id,
                t.subject,
                t.message,
                t.customer_id,
                c.name AS customer_name,
                c.email AS customer_email,
                c.phone AS customer_phone,
                t.category_id,
                cat.name AS category_name,
                t.priority_id,
                pri.code AS priority_code,
                pri.name AS priority_name,
                t.status_id,
                st.code AS status_code,
                st.name AS status_name,
                t.owner_user_id,
                own.nama_lengkap AS owner_name,
                t.due_date,
                t.last_reply_by,
                t.last_reply_at,
                t.resolved_at,
                t.created_at,
                t.updated_at,
                t.by_jobsite
            FROM ticketing.tickets t
            INNER JOIN ticketing.customers c ON c.id = t.customer_id
            LEFT JOIN ticketing.enums cat ON cat.id = t.category_id
            LEFT JOIN ticketing.enums pri ON pri.id = t.priority_id
            LEFT JOIN ticketing.enums st ON st.id = t.status_id
            LEFT JOIN ticketing.users own ON own.id = t.owner_user_id AND own.deleted_at IS NULL
            WHERE t.deleted_at IS NULL
              AND t.id = @IDCHECK
              AND (@BY_JOBSITE IS NULL OR t.by_jobsite = @BY_JOBSITE OR t.by_jobsite IS NULL);
        END
        ELSE IF @ACTION_SP = 'INSERT'
        BEGIN
            IF @EMAIL IS NULL OR @CUSTOMER_NAME IS NULL OR @SUBJECT IS NULL OR @MESSAGE IS NULL OR @CATEGORY_ID IS NULL
            BEGIN
                SELECT CAST(0 AS BIT) AS success, 'Email, name, category, subject, and message are required.' AS message;
                RETURN;
            END

            IF @STATUS_ID IS NULL
                SELECT @STATUS_ID = id FROM ticketing.enums
                WHERE deleted_at IS NULL AND type = 'ticket_status' AND code = 'new';

            IF @PRIORITY_ID IS NULL
                SELECT @PRIORITY_ID = id FROM ticketing.enums
                WHERE deleted_at IS NULL AND type = 'ticket_priority' AND code = 'medium';

            IF @STATUS_ID IS NULL OR @PRIORITY_ID IS NULL
            BEGIN
                SELECT CAST(0 AS BIT) AS success, 'Ticket status/priority enums are not seeded.' AS message;
                RETURN;
            END

            -- Unique public tracking id from NEWID (8 hex chars)
            DECLARE @TRIES INT = 0;
            WHILE 1 = 1
            BEGIN
                SET @TRACK = 'TCK-' + UPPER(LEFT(REPLACE(CAST(NEWID() AS VARCHAR(36)), '-', ''), 8));
                IF NOT EXISTS (SELECT 1 FROM ticketing.tickets WHERE tracking_id = @TRACK)
                    BREAK;
                SET @TRIES += 1;
                IF @TRIES > 10
                BEGIN
                    SELECT CAST(0 AS BIT) AS success, 'Failed to generate tracking id.' AS message;
                    RETURN;
                END
            END

            BEGIN TRANSACTION;

            -- Find-or-create customer by email
            SELECT @CUSTOMER_ID = id FROM ticketing.customers
            WHERE deleted_at IS NULL AND email = @EMAIL;

            IF @CUSTOMER_ID IS NULL
            BEGIN
                INSERT INTO ticketing.customers (email, name, phone, created_by, by_jobsite)
                VALUES (@EMAIL, @CUSTOMER_NAME, @CUSTOMER_PHONE, ISNULL(@BY_USER, 'public'), @BY_JOBSITE);
                SET @CUSTOMER_ID = SCOPE_IDENTITY();
            END

            INSERT INTO ticketing.tickets (
                tracking_id, customer_id, category_id, priority_id, status_id,
                subject, message, owner_user_id, due_date, created_by, by_jobsite
            ) VALUES (
                @TRACK, @CUSTOMER_ID, @CATEGORY_ID, @PRIORITY_ID, @STATUS_ID,
                @SUBJECT, @MESSAGE, @OWNER_USER_ID, @DUE_DATE, ISNULL(@BY_USER, 'public'), @BY_JOBSITE
            );

            DECLARE @NEW_ID INT = SCOPE_IDENTITY();

            INSERT INTO ticketing.ticket_history (ticket_id, action, new_value, actor_type, actor_id)
            VALUES (@NEW_ID, 'created', @TRACK,
                    CASE WHEN @BY_USER IS NULL THEN 'customer' ELSE 'staff' END,
                    TRY_CAST(@BY_USER AS INT));

            COMMIT TRANSACTION;

            SELECT CAST(1 AS BIT) AS success, 'Ticket created successfully.' AS message,
                   @NEW_ID AS id, @TRACK AS tracking_id;
        END
        ELSE IF @ACTION_SP = 'UPDATE'
        BEGIN
            SELECT @IDCHECK = id, @OLD_STATUS_ID = status_id, @OLD_OWNER_ID = owner_user_id
            FROM ticketing.tickets
            WHERE deleted_at IS NULL
              AND id = @ID
              AND (@BY_JOBSITE IS NULL OR by_jobsite = @BY_JOBSITE OR by_jobsite IS NULL);

            IF @IDCHECK IS NULL
            BEGIN
                SELECT CAST(0 AS BIT) AS success, 'Ticket not found.' AS message;
                RETURN;
            END

            SELECT @RESOLVED_ID = id FROM ticketing.enums
            WHERE deleted_at IS NULL AND type = 'ticket_status' AND code = 'resolved';

            BEGIN TRANSACTION;

            UPDATE ticketing.tickets
            SET
                category_id = ISNULL(@CATEGORY_ID, category_id),
                priority_id = ISNULL(@PRIORITY_ID, priority_id),
                status_id = ISNULL(@STATUS_ID, status_id),
                owner_user_id = ISNULL(@OWNER_USER_ID, owner_user_id),
                due_date = ISNULL(@DUE_DATE, due_date),
                subject = ISNULL(@SUBJECT, subject),
                resolved_at = CASE
                    WHEN @STATUS_ID IS NOT NULL AND @STATUS_ID = @RESOLVED_ID THEN GETDATE()
                    WHEN @STATUS_ID IS NOT NULL AND @STATUS_ID <> @RESOLVED_ID THEN NULL
                    ELSE resolved_at
                END,
                updated_at = GETDATE(),
                updated_by = @BY_USER
            WHERE id = @IDCHECK;

            IF @STATUS_ID IS NOT NULL AND @STATUS_ID <> @OLD_STATUS_ID
                INSERT INTO ticketing.ticket_history (ticket_id, action, old_value, new_value, actor_type, actor_id)
                VALUES (@IDCHECK, 'status_changed',
                        CAST(@OLD_STATUS_ID AS VARCHAR(255)), CAST(@STATUS_ID AS VARCHAR(255)),
                        'staff', TRY_CAST(@BY_USER AS INT));

            IF @OWNER_USER_ID IS NOT NULL AND (@OLD_OWNER_ID IS NULL OR @OWNER_USER_ID <> @OLD_OWNER_ID)
                INSERT INTO ticketing.ticket_history (ticket_id, action, old_value, new_value, actor_type, actor_id)
                VALUES (@IDCHECK, 'assigned',
                        CAST(@OLD_OWNER_ID AS VARCHAR(255)), CAST(@OWNER_USER_ID AS VARCHAR(255)),
                        'staff', TRY_CAST(@BY_USER AS INT));

            COMMIT TRANSACTION;

            SELECT CAST(1 AS BIT) AS success, 'Ticket updated successfully.' AS message;
        END
        ELSE IF @ACTION_SP = 'DELETE'
        BEGIN
            SELECT @IDCHECK = id
            FROM ticketing.tickets
            WHERE deleted_at IS NULL
              AND id = @ID
              AND (@BY_JOBSITE IS NULL OR by_jobsite = @BY_JOBSITE OR by_jobsite IS NULL);
            IF @IDCHECK IS NULL
            BEGIN
                SELECT CAST(0 AS BIT) AS success, 'Ticket not found.' AS message;
                RETURN;
            END

            UPDATE ticketing.tickets
            SET deleted_at = GETDATE(), deleted_by = @BY_USER
            WHERE id = @IDCHECK;

            SELECT CAST(1 AS BIT) AS success, 'Ticket deleted successfully.' AS message;
        END
        ELSE
        BEGIN
            SELECT 1;
        END
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        SELECT
            CAST(0 AS BIT) AS success,
            'Failed to process ticket data.' AS message,
            ERROR_NUMBER() AS error_number,
            ERROR_MESSAGE() AS error_message;
    END CATCH
END
GO

-- =============================================
-- TICKET_REPLIES_SP
-- Actions:
--   SELECT  replies of a ticket (@TICKET_ID)
--   INSERT  add reply; updates ticket last_reply_* and status:
--           customer reply -> waiting_reply, staff reply -> replied
-- Ownership for the public path (tracking id + email) is resolved
-- by the service via TICKETS_SP GET_BY_TRACKING before calling this.
-- =============================================
CREATE OR ALTER PROCEDURE ticketing.TICKET_REPLIES_SP
    @ACTION_SP VARCHAR(20) = NULL,
    @ID INT = NULL,
    @TICKET_ID INT = NULL,
    @SENDER_TYPE VARCHAR(10) = NULL,
    @CUSTOMER_ID INT = NULL,
    @USER_ID INT = NULL,
    @MESSAGE VARCHAR(MAX) = NULL,
    @BY_USER VARCHAR(20) = NULL,
    @BY_JOBSITE INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @NEW_STATUS_ID INT;

    BEGIN TRY
        IF @ACTION_SP = 'SELECT'
        BEGIN
            SELECT
                r.id,
                r.ticket_id,
                r.sender_type,
                r.customer_id,
                c.name AS customer_name,
                r.user_id,
                u.nama_lengkap AS user_name,
                r.message,
                r.created_at
            FROM ticketing.ticket_replies r
            INNER JOIN ticketing.tickets t ON t.id = r.ticket_id AND t.deleted_at IS NULL
            LEFT JOIN ticketing.customers c ON c.id = r.customer_id
            LEFT JOIN ticketing.users u ON u.id = r.user_id
            WHERE r.deleted_at IS NULL
              AND r.ticket_id = @TICKET_ID
              AND (@BY_JOBSITE IS NULL OR t.by_jobsite = @BY_JOBSITE OR t.by_jobsite IS NULL)
            ORDER BY r.created_at ASC;
        END
        ELSE IF @ACTION_SP = 'INSERT'
        BEGIN
            IF @TICKET_ID IS NULL OR @MESSAGE IS NULL
               OR @SENDER_TYPE NOT IN ('customer', 'staff')
            BEGIN
                SELECT CAST(0 AS BIT) AS success, 'Ticket, sender type, and message are required.' AS message;
                RETURN;
            END

            IF NOT EXISTS (
                SELECT 1 FROM ticketing.tickets
                WHERE deleted_at IS NULL
                  AND id = @TICKET_ID
                  AND (@BY_JOBSITE IS NULL OR by_jobsite = @BY_JOBSITE OR by_jobsite IS NULL)
            )
            BEGIN
                SELECT CAST(0 AS BIT) AS success, 'Ticket not found.' AS message;
                RETURN;
            END

            SELECT @NEW_STATUS_ID = id FROM ticketing.enums
            WHERE deleted_at IS NULL
              AND type = 'ticket_status'
              AND code = CASE WHEN @SENDER_TYPE = 'customer' THEN 'waiting_reply' ELSE 'replied' END;

            BEGIN TRANSACTION;

            INSERT INTO ticketing.ticket_replies (ticket_id, sender_type, customer_id, user_id, message)
            VALUES (@TICKET_ID, @SENDER_TYPE, @CUSTOMER_ID, @USER_ID, @MESSAGE);

            DECLARE @REPLY_ID INT = SCOPE_IDENTITY();

            UPDATE ticketing.tickets
            SET
                last_reply_by = @SENDER_TYPE,
                last_reply_at = GETDATE(),
                status_id = ISNULL(@NEW_STATUS_ID, status_id),
                resolved_at = NULL,
                updated_at = GETDATE(),
                updated_by = ISNULL(@BY_USER, updated_by)
            WHERE id = @TICKET_ID;

            INSERT INTO ticketing.ticket_history (ticket_id, action, new_value, actor_type, actor_id)
            VALUES (@TICKET_ID, 'replied', CAST(@REPLY_ID AS VARCHAR(255)),
                    @SENDER_TYPE,
                    CASE WHEN @SENDER_TYPE = 'customer' THEN @CUSTOMER_ID ELSE @USER_ID END);

            COMMIT TRANSACTION;

            SELECT CAST(1 AS BIT) AS success, 'Reply saved successfully.' AS message, @REPLY_ID AS id;
        END
        ELSE
        BEGIN
            SELECT 1;
        END
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        SELECT
            CAST(0 AS BIT) AS success,
            'Failed to process reply data.' AS message,
            ERROR_NUMBER() AS error_number,
            ERROR_MESSAGE() AS error_message;
    END CATCH
END
GO

-- =============================================
-- TICKET_ATTACHMENTS_SP
-- Actions: SELECT (per ticket) | GET (download metadata) | INSERT | DELETE
-- Files live in a private upload dir; download endpoint must verify
-- ownership (tracking id + email) or staff permission first.
-- =============================================
CREATE OR ALTER PROCEDURE ticketing.TICKET_ATTACHMENTS_SP
    @ACTION_SP VARCHAR(20) = NULL,
    @ID INT = NULL,
    @TICKET_ID INT = NULL,
    @REPLY_ID INT = NULL,
    @FILE_NAME VARCHAR(255) = NULL,
    @STORED_NAME VARCHAR(255) = NULL,
    @MIME_TYPE VARCHAR(100) = NULL,
    @FILE_SIZE INT = NULL,
    @UPLOADED_BY_TYPE VARCHAR(10) = NULL,
    @BY_USER VARCHAR(20) = NULL,
    @BY_JOBSITE INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @IDCHECK INT;

    BEGIN TRY
        IF @ACTION_SP = 'SELECT'
        BEGIN
            SELECT
                a.id, a.ticket_id, a.reply_id, a.file_name,
                a.mime_type, a.file_size, a.uploaded_by_type, a.created_at
            FROM ticketing.ticket_attachments a
            INNER JOIN ticketing.tickets t ON t.id = a.ticket_id AND t.deleted_at IS NULL
            WHERE a.deleted_at IS NULL
              AND a.ticket_id = @TICKET_ID
              AND (@BY_JOBSITE IS NULL OR t.by_jobsite = @BY_JOBSITE OR t.by_jobsite IS NULL)
            ORDER BY a.created_at ASC;
        END
        ELSE IF @ACTION_SP = 'GET'
        BEGIN
            SELECT
                a.id, a.ticket_id, a.reply_id, a.file_name, a.stored_name,
                a.mime_type, a.file_size, a.uploaded_by_type, a.created_at
            FROM ticketing.ticket_attachments a
            INNER JOIN ticketing.tickets t ON t.id = a.ticket_id AND t.deleted_at IS NULL
            WHERE a.deleted_at IS NULL
              AND a.id = @ID
              AND (@BY_JOBSITE IS NULL OR t.by_jobsite = @BY_JOBSITE OR t.by_jobsite IS NULL);
        END
        ELSE IF @ACTION_SP = 'INSERT'
        BEGIN
            IF @TICKET_ID IS NULL OR @FILE_NAME IS NULL OR @STORED_NAME IS NULL
               OR @UPLOADED_BY_TYPE NOT IN ('customer', 'staff')
            BEGIN
                SELECT CAST(0 AS BIT) AS success, 'Ticket, file name, stored name, and uploader type are required.' AS message;
                RETURN;
            END

            IF NOT EXISTS (
                SELECT 1 FROM ticketing.tickets
                WHERE deleted_at IS NULL
                  AND id = @TICKET_ID
                  AND (@BY_JOBSITE IS NULL OR by_jobsite = @BY_JOBSITE OR by_jobsite IS NULL)
            )
            BEGIN
                SELECT CAST(0 AS BIT) AS success, 'Ticket not found.' AS message;
                RETURN;
            END

            IF @REPLY_ID IS NOT NULL
               AND NOT EXISTS (
                   SELECT 1 FROM ticketing.ticket_replies
                   WHERE deleted_at IS NULL
                     AND id = @REPLY_ID
                     AND ticket_id = @TICKET_ID
               )
            BEGIN
                SELECT CAST(0 AS BIT) AS success, 'Reply does not belong to the ticket.' AS message;
                RETURN;
            END

            INSERT INTO ticketing.ticket_attachments (
                ticket_id, reply_id, file_name, stored_name,
                mime_type, file_size, uploaded_by_type
            ) VALUES (
                @TICKET_ID, @REPLY_ID, @FILE_NAME, @STORED_NAME,
                @MIME_TYPE, @FILE_SIZE, @UPLOADED_BY_TYPE
            );

            SELECT CAST(1 AS BIT) AS success, 'Attachment saved successfully.' AS message, SCOPE_IDENTITY() AS id;
        END
        ELSE IF @ACTION_SP = 'DELETE'
        BEGIN
            SELECT @IDCHECK = a.id
            FROM ticketing.ticket_attachments a
            INNER JOIN ticketing.tickets t ON t.id = a.ticket_id AND t.deleted_at IS NULL
            WHERE a.deleted_at IS NULL
              AND a.id = @ID
              AND (@BY_JOBSITE IS NULL OR t.by_jobsite = @BY_JOBSITE OR t.by_jobsite IS NULL);
            IF @IDCHECK IS NULL
            BEGIN
                SELECT CAST(0 AS BIT) AS success, 'Attachment not found.' AS message;
                RETURN;
            END

            UPDATE ticketing.ticket_attachments
            SET deleted_at = GETDATE(), deleted_by = @BY_USER
            WHERE id = @IDCHECK;

            SELECT CAST(1 AS BIT) AS success, 'Attachment deleted successfully.' AS message;
        END
        ELSE
        BEGIN
            SELECT 1;
        END
    END TRY
    BEGIN CATCH
        SELECT
            CAST(0 AS BIT) AS success,
            'Failed to process attachment data.' AS message,
            ERROR_NUMBER() AS error_number,
            ERROR_MESSAGE() AS error_message;
    END CATCH
END
GO
