-- =============================================
-- Table: equipments
-- =============================================
IF OBJECT_ID('dbo.equipments', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.equipments (
        id INT IDENTITY(1,1) NOT NULL,
        jigsaw_id VARCHAR(50) NOT NULL,
        ellipse VARCHAR(50) NULL,
        old_ellipse VARCHAR(50) NULL,
        equipment_type_id INT NULL,
        [type] VARCHAR(25) NULL,
        loader_fleet VARCHAR(50) NULL,
        pit_id INT NULL,
        [status] INT NOT NULL CONSTRAINT DF_equipments_status DEFAULT (1),
        created_at DATETIME NOT NULL CONSTRAINT DF_equipments_created_at DEFAULT (GETDATE()),
        created_by VARCHAR(100) NULL,
        updated_at DATETIME NULL,
        updated_by VARCHAR(100) NULL,
        deleted_at DATETIME NULL,
        deleted_by VARCHAR(100) NULL,
        by_jobsite INT NULL,
        CONSTRAINT PK_equipments PRIMARY KEY CLUSTERED (id),
        CONSTRAINT UQ_equipments_jigsaw_id UNIQUE (jigsaw_id)
    );
END
GO

-- =============================================
-- Sample data (optional)
-- =============================================
/*
INSERT INTO dbo.equipments (jigsaw_id, ellipse, old_ellipse, equipment_type_id, [type], loader_fleet, pit_id, [status])
VALUES
    ('X7-005', 'EX350-0005A', 'R9400-05A', 49, 'loader', NULL, 15, 1),
    ('S6-003', 'SH300-0003A', 'R9350-SH03', 48, 'loader', NULL, 17, 1),
    ('D3-049', 'DT090-0049', NULL, 65, 'hauler', 'X4-001', 15, 1),
    ('D3-053', 'DT090-0053', NULL, 62, 'hauler', 'X4-011', 15, 1),
    ('D3-063', 'DT090-0063', NULL, 65, 'hauler', 'X4-011', 17, 3);
*/
GO

-- =============================================
-- Stored Procedure: EQUIPMENTS_SP
-- =============================================
CREATE OR ALTER PROCEDURE EQUIPMENTS_SP
    @ACTION_SP VARCHAR(15) = NULL,
    @ID INT = NULL,
    @JIGSAW_ID VARCHAR(50) = NULL,
    @ELLIPSE VARCHAR(50) = NULL,
    @OLD_ELLIPSE VARCHAR(50) = NULL,
    @EQUIPMENT_TYPE_ID INT = NULL,
    @TYPE VARCHAR(25) = NULL,
    @LOADER_FLEET VARCHAR(50) = NULL,
    @PIT_ID INT = NULL,
    @STATUS INT = NULL,
    @BY_USER VARCHAR(100) = NULL,
    @BY_JOBSITE INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @IDCHECK INT;

    BEGIN TRY
        IF @ACTION_SP = 'SELECT'
        BEGIN
            SELECT
                e.id,
                e.jigsaw_id,
                e.ellipse,
                e.old_ellipse,
                e.equipment_type_id,
                et.name AS equipment_type_name,
                et.code AS equipment_type_code,
                e.[type],
                e.loader_fleet,
                e.pit_id,
                pit.name AS pit_name,
                pit.code AS pit_code,
                e.[status],
                st.name AS status_name,
                st.code AS status_code,
                e.created_at,
                e.created_by,
                e.updated_at,
                e.updated_by,
                e.by_jobsite
            FROM dbo.equipments e
            LEFT JOIN dbo.enums et
                ON et.id = e.equipment_type_id
               AND et.deleted_at IS NULL
               AND et.type = 'equipment_type'
            LEFT JOIN dbo.enums pit
                ON pit.id = e.pit_id
               AND pit.deleted_at IS NULL
               AND pit.type = 'pit'
            LEFT JOIN dbo.enums st
                ON st.id = e.[status]
               AND st.deleted_at IS NULL
               AND st.type = 'equipment_status'
            WHERE e.deleted_at IS NULL
            ORDER BY e.jigsaw_id;
        END
        ELSE IF @ACTION_SP = 'GET'
        BEGIN
            SELECT
                e.id,
                e.jigsaw_id,
                e.ellipse,
                e.old_ellipse,
                e.equipment_type_id,
                et.name AS equipment_type_name,
                et.code AS equipment_type_code,
                e.[type],
                e.loader_fleet,
                e.pit_id,
                pit.name AS pit_name,
                pit.code AS pit_code,
                e.[status],
                st.name AS status_name,
                st.code AS status_code,
                e.created_at,
                e.created_by,
                e.updated_at,
                e.updated_by,
                e.by_jobsite
            FROM dbo.equipments e
            LEFT JOIN dbo.enums et
                ON et.id = e.equipment_type_id
               AND et.deleted_at IS NULL
               AND et.type = 'equipment_type'
            LEFT JOIN dbo.enums pit
                ON pit.id = e.pit_id
               AND pit.deleted_at IS NULL
               AND pit.type = 'pit'
            LEFT JOIN dbo.enums st
                ON st.id = e.[status]
               AND st.deleted_at IS NULL
               AND st.type = 'equipment_status'
            WHERE e.deleted_at IS NULL
              AND (
                    (@ID IS NOT NULL AND e.id = @ID)
                 OR (@JIGSAW_ID IS NOT NULL AND e.jigsaw_id = @JIGSAW_ID)
              );
        END
        ELSE IF @ACTION_SP = 'INSERT'
        BEGIN
            IF EXISTS (
                SELECT 1
                FROM dbo.equipments
                WHERE deleted_at IS NULL
                  AND jigsaw_id = @JIGSAW_ID
            )
            BEGIN
                SELECT
                    CAST(0 AS BIT) AS success,
                    'Failed! Jigsaw ID already exists.' AS message;
                RETURN;
            END

            IF @JIGSAW_ID IS NULL OR LTRIM(RTRIM(@JIGSAW_ID)) = ''
            BEGIN
                SELECT
                    CAST(0 AS BIT) AS success,
                    'Failed! Jigsaw ID is required.' AS message;
                RETURN;
            END

            INSERT INTO dbo.equipments (
                jigsaw_id,
                ellipse,
                old_ellipse,
                equipment_type_id,
                [type],
                loader_fleet,
                pit_id,
                [status],
                created_by,
                by_jobsite
            ) VALUES (
                @JIGSAW_ID,
                @ELLIPSE,
                @OLD_ELLIPSE,
                @EQUIPMENT_TYPE_ID,
                @TYPE,
                @LOADER_FLEET,
                @PIT_ID,
                ISNULL(@STATUS, 1),
                @BY_USER,
                @BY_JOBSITE
            );

            SELECT
                CAST(1 AS BIT) AS success,
                'Equipment saved successfully' AS message;
        END
        ELSE IF @ACTION_SP = 'UPDATE'
        BEGIN
            SELECT @IDCHECK = id
            FROM dbo.equipments
            WHERE deleted_at IS NULL
              AND id = @ID;

            IF @IDCHECK IS NULL
            BEGIN
                SELECT
                    CAST(0 AS BIT) AS success,
                    'Failed! Equipment not found.' AS message;
                RETURN;
            END

            IF EXISTS (
                SELECT 1
                FROM dbo.equipments
                WHERE deleted_at IS NULL
                  AND jigsaw_id = @JIGSAW_ID
                  AND id <> @IDCHECK
            )
            BEGIN
                SELECT
                    CAST(0 AS BIT) AS success,
                    'Failed! Jigsaw ID already exists.' AS message;
                RETURN;
            END

            UPDATE dbo.equipments
            SET
                jigsaw_id = @JIGSAW_ID,
                ellipse = @ELLIPSE,
                old_ellipse = @OLD_ELLIPSE,
                equipment_type_id = @EQUIPMENT_TYPE_ID,
                [type] = @TYPE,
                loader_fleet = @LOADER_FLEET,
                pit_id = @PIT_ID,
                [status] = ISNULL(@STATUS, [status]),
                updated_at = GETDATE(),
                updated_by = @BY_USER
            WHERE id = @IDCHECK;

            SELECT
                CAST(1 AS BIT) AS success,
                'Equipment has been updated!' AS message;
        END
        ELSE IF @ACTION_SP = 'DELETE'
        BEGIN
            SELECT @IDCHECK = id
            FROM dbo.equipments
            WHERE deleted_at IS NULL
              AND id = @ID;

            IF @IDCHECK IS NULL
            BEGIN
                SELECT
                    CAST(0 AS BIT) AS success,
                    'Failed! Equipment not found.' AS message;
                RETURN;
            END

            UPDATE dbo.equipments
            SET
                deleted_at = GETDATE(),
                deleted_by = @BY_USER
            WHERE id = @IDCHECK;

            SELECT
                CAST(1 AS BIT) AS success,
                'Equipment has been deleted!' AS message;
        END
        ELSE
        BEGIN
            SELECT 1;
        END
    END TRY
    BEGIN CATCH
        SELECT
            CAST(0 AS BIT) AS success,
            'Failed to save data' AS message,
            ERROR_NUMBER() AS error_number,
            ERROR_MESSAGE() AS error_message;
    END CATCH
END
GO
