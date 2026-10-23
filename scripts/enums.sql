-- =============================================
-- Schema: ticketing (all app tables/SPs live here)
-- Set DB_SCHEMA=ticketing in .env
-- =============================================
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'ticketing')
    EXEC('CREATE SCHEMA ticketing');
GO

-- =============================================
-- Table: enums (generic typed lookup)
-- =============================================
IF OBJECT_ID('ticketing.enums', 'U') IS NULL
BEGIN
    CREATE TABLE ticketing.enums (
        id INT IDENTITY(1,1) NOT NULL,
        code VARCHAR(100) NULL,
        name VARCHAR(150) NOT NULL,
        category VARCHAR(100) NULL,
        category_description VARCHAR(255) NULL,
        type VARCHAR(100) NOT NULL,
        include BIT NOT NULL CONSTRAINT DF_enums_include DEFAULT (1),
        ref_id INT NULL,
        created_at DATETIME NOT NULL CONSTRAINT DF_enums_created_at DEFAULT (GETDATE()),
        created_by VARCHAR(20) NULL,
        updated_at DATETIME NULL,
        updated_by VARCHAR(20) NULL,
        deleted_at DATETIME NULL,
        deleted_by VARCHAR(20) NULL,
        by_jobsite INT NULL,
        CONSTRAINT PK_enums PRIMARY KEY CLUSTERED (id)
    );

    CREATE INDEX IX_enums_type ON ticketing.enums (type, deleted_at);
END
GO

-- =============================================
-- Seed: user levels (type = 'level')
-- isSuperadminUser(): level_id = 1 OR level_code in admin|superadmin|sa
-- =============================================
SET IDENTITY_INSERT ticketing.enums ON;

IF NOT EXISTS (SELECT 1 FROM ticketing.enums WHERE id = 1)
    INSERT INTO ticketing.enums (id, code, name, category, category_description, type, include)
    VALUES (1, 'superadmin', 'Super Admin', 'level', 'User level', 'level', 1);

SET IDENTITY_INSERT ticketing.enums OFF;
GO

IF NOT EXISTS (SELECT 1 FROM ticketing.enums WHERE deleted_at IS NULL AND type = 'level' AND code = 'staff')
    INSERT INTO ticketing.enums (code, name, category, category_description, type, include)
    VALUES ('staff', 'Staff', 'level', 'User level', 'level', 1);
GO

-- =============================================
-- ENUMS_SP (list by type/category for selects)
-- =============================================
CREATE OR ALTER PROCEDURE ticketing.ENUMS_SP
    @ACTION_SP VARCHAR(20) = NULL,
    @ID INT = NULL,
    @CODE VARCHAR(100) = NULL,
    @NAME VARCHAR(150) = NULL,
    @CATEGORY VARCHAR(100) = NULL,
    @CATEGORY_DESCRIPTION VARCHAR(255) = NULL,
    @TYPE VARCHAR(100) = NULL,
    @INCLUDE BIT = NULL,
    @REF_ID INT = NULL,
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
                e.id,
                e.code,
                e.name,
                e.category,
                e.category_description,
                e.type,
                e.include,
                e.ref_id,
                e.created_at,
                e.updated_at,
                e.by_jobsite
            FROM ticketing.enums e
            WHERE e.deleted_at IS NULL
              AND ISNULL(e.include, 1) = 1
              AND (@BY_JOBSITE IS NULL OR e.by_jobsite = @BY_JOBSITE OR e.by_jobsite IS NULL)
              AND (
                    @CATEGORY IS NULL
                 OR e.category = @CATEGORY
              )
              AND (
                    @TYPE IS NULL
                 OR e.type = @TYPE
                 OR e.category = @TYPE
              )
              AND (
                    @SEARCH IS NULL
                 OR LTRIM(RTRIM(@SEARCH)) = ''
                 OR e.name LIKE '%' + @SEARCH + '%'
                 OR e.code LIKE '%' + @SEARCH + '%'
              )
            ORDER BY e.name
            OFFSET CASE WHEN @PAGE_SIZE > 0 THEN (@PAGE - 1) * @PAGE_SIZE ELSE 0 END ROWS
            FETCH NEXT CASE WHEN @PAGE_SIZE > 0 THEN @PAGE_SIZE ELSE 100000 END ROWS ONLY;

            SELECT COUNT(*) AS total_count
            FROM ticketing.enums e
            WHERE e.deleted_at IS NULL
              AND ISNULL(e.include, 1) = 1
              AND (@BY_JOBSITE IS NULL OR e.by_jobsite = @BY_JOBSITE OR e.by_jobsite IS NULL)
              AND (
                    @CATEGORY IS NULL
                 OR e.category = @CATEGORY
              )
              AND (
                    @TYPE IS NULL
                 OR e.type = @TYPE
                 OR e.category = @TYPE
              )
              AND (
                    @SEARCH IS NULL
                 OR LTRIM(RTRIM(@SEARCH)) = ''
                 OR e.name LIKE '%' + @SEARCH + '%'
                 OR e.code LIKE '%' + @SEARCH + '%'
              );
        END
        ELSE IF @ACTION_SP = 'GET'
        BEGIN
            SELECT
                e.id,
                e.code,
                e.name,
                e.category,
                e.category_description,
                e.type,
                e.include,
                e.ref_id,
                e.created_at,
                e.updated_at,
                e.by_jobsite
            FROM ticketing.enums e
            WHERE e.deleted_at IS NULL
              AND e.id = @ID;
        END
        ELSE IF @ACTION_SP = 'INSERT'
        BEGIN
            IF @NAME IS NULL OR @TYPE IS NULL
            BEGIN
                SELECT CAST(0 AS BIT) AS success, 'Name and type are required.' AS message;
                RETURN;
            END

            INSERT INTO ticketing.enums (
                code, name, category, category_description, type, include, ref_id, created_by, by_jobsite
            ) VALUES (
                @CODE, @NAME, @CATEGORY, @CATEGORY_DESCRIPTION, @TYPE, ISNULL(@INCLUDE, 1), @REF_ID, @BY_USER, @BY_JOBSITE
            );

            SELECT CAST(1 AS BIT) AS success, 'Enum saved successfully.' AS message;
        END
        ELSE IF @ACTION_SP = 'UPDATE'
        BEGIN
            SELECT @IDCHECK = id FROM ticketing.enums WHERE deleted_at IS NULL AND id = @ID;
            IF @IDCHECK IS NULL
            BEGIN
                SELECT CAST(0 AS BIT) AS success, 'Enum not found.' AS message;
                RETURN;
            END

            UPDATE ticketing.enums
            SET
                code = ISNULL(@CODE, code),
                name = ISNULL(@NAME, name),
                category = ISNULL(@CATEGORY, category),
                category_description = ISNULL(@CATEGORY_DESCRIPTION, category_description),
                type = ISNULL(@TYPE, type),
                include = ISNULL(@INCLUDE, include),
                ref_id = @REF_ID,
                updated_at = GETDATE(),
                updated_by = @BY_USER
            WHERE id = @IDCHECK;

            SELECT CAST(1 AS BIT) AS success, 'Enum updated successfully.' AS message;
        END
        ELSE IF @ACTION_SP = 'DELETE'
        BEGIN
            SELECT @IDCHECK = id FROM ticketing.enums WHERE deleted_at IS NULL AND id = @ID;
            IF @IDCHECK IS NULL
            BEGIN
                SELECT CAST(0 AS BIT) AS success, 'Enum not found.' AS message;
                RETURN;
            END

            UPDATE ticketing.enums
            SET deleted_at = GETDATE(), deleted_by = @BY_USER
            WHERE id = @IDCHECK;

            SELECT CAST(1 AS BIT) AS success, 'Enum deleted successfully.' AS message;
        END
        ELSE
        BEGIN
            SELECT 1;
        END
    END TRY
    BEGIN CATCH
        SELECT
            CAST(0 AS BIT) AS success,
            'Failed to process enum data.' AS message,
            ERROR_NUMBER() AS error_number,
            ERROR_MESSAGE() AS error_message;
    END CATCH
END
GO

-- =============================================
-- Seed: pit / equipment_type / equipment_status
-- =============================================
SET IDENTITY_INSERT ticketing.enums ON;

IF NOT EXISTS (SELECT 1 FROM ticketing.enums WHERE id = 15)
    INSERT INTO ticketing.enums (id, code, name, category, category_description, type, include)
    VALUES (15, 'PIT15', 'Pit 15', 'pit', 'Pit location', 'pit', 1);

IF NOT EXISTS (SELECT 1 FROM ticketing.enums WHERE id = 17)
    INSERT INTO ticketing.enums (id, code, name, category, category_description, type, include)
    VALUES (17, 'PIT17', 'Pit 17', 'pit', 'Pit location', 'pit', 1);

IF NOT EXISTS (SELECT 1 FROM ticketing.enums WHERE id = 48)
    INSERT INTO ticketing.enums (id, code, name, category, category_description, type, include)
    VALUES (48, 'SH300', 'SH300', 'equipment_type', 'Equipment type', 'equipment_type', 1);

IF NOT EXISTS (SELECT 1 FROM ticketing.enums WHERE id = 49)
    INSERT INTO ticketing.enums (id, code, name, category, category_description, type, include)
    VALUES (49, 'EX350', 'EX350', 'equipment_type', 'Equipment type', 'equipment_type', 1);

IF NOT EXISTS (SELECT 1 FROM ticketing.enums WHERE id = 62)
    INSERT INTO ticketing.enums (id, code, name, category, category_description, type, include)
    VALUES (62, 'DT090-62', 'DT090 (62)', 'equipment_type', 'Equipment type', 'equipment_type', 1);

IF NOT EXISTS (SELECT 1 FROM ticketing.enums WHERE id = 65)
    INSERT INTO ticketing.enums (id, code, name, category, category_description, type, include)
    VALUES (65, 'DT090-65', 'DT090 (65)', 'equipment_type', 'Equipment type', 'equipment_type', 1);

SET IDENTITY_INSERT ticketing.enums OFF;
GO

IF NOT EXISTS (SELECT 1 FROM ticketing.enums WHERE deleted_at IS NULL AND type = 'equipment_status' AND code = 'active')
    INSERT INTO ticketing.enums (code, name, category, category_description, type, include)
    VALUES ('active', 'Active', 'equipment_status', 'Equipment status', 'equipment_status', 1);

IF NOT EXISTS (SELECT 1 FROM ticketing.enums WHERE deleted_at IS NULL AND type = 'equipment_status' AND code = 'standby')
    INSERT INTO ticketing.enums (code, name, category, category_description, type, include)
    VALUES ('standby', 'Standby', 'equipment_status', 'Equipment status', 'equipment_status', 1);

IF NOT EXISTS (SELECT 1 FROM ticketing.enums WHERE deleted_at IS NULL AND type = 'equipment_status' AND code = 'breakdown')
    INSERT INTO ticketing.enums (code, name, category, category_description, type, include)
    VALUES ('breakdown', 'Breakdown', 'equipment_status', 'Equipment status', 'equipment_status', 1);
GO

-- Map legacy status codes (1/3) to equipment_status enum ids when possible
DECLARE @active_id INT = (SELECT TOP 1 id FROM ticketing.enums WHERE deleted_at IS NULL AND type = 'equipment_status' AND code = 'active');
DECLARE @breakdown_id INT = (SELECT TOP 1 id FROM ticketing.enums WHERE deleted_at IS NULL AND type = 'equipment_status' AND code = 'breakdown');

IF OBJECT_ID('dbo.equipments', 'U') IS NOT NULL AND @active_id IS NOT NULL
BEGIN
    UPDATE dbo.equipments
    SET [status] = @active_id
    WHERE deleted_at IS NULL
      AND [status] = 1
      AND NOT EXISTS (
          SELECT 1 FROM ticketing.enums es
          WHERE es.id = equipments.[status] AND es.type = 'equipment_status' AND es.deleted_at IS NULL
      );

    IF @breakdown_id IS NOT NULL
    BEGIN
        UPDATE dbo.equipments
        SET [status] = @breakdown_id
        WHERE deleted_at IS NULL
          AND [status] = 3
          AND NOT EXISTS (
              SELECT 1 FROM ticketing.enums es
              WHERE es.id = equipments.[status] AND es.type = 'equipment_status' AND es.deleted_at IS NULL
          );
    END
END
GO
