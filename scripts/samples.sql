CREATE PROCEDURE SAMPLES_SP
@ACTION_SP VARCHAR(15) = NULL,
@ID VARCHAR(100) = NULL,
@DORMITORY_ID VARCHAR(100) = NULL,
@BUILDING_ID VARCHAR(100) = NULL,
@ROOM_ID VARCHAR(100) = NULL,
@BED_NUMBER VARCHAR(10) = NULL,
@STATUS VARCHAR(25) = NULL,
@DESCRIPTION VARCHAR(MAX) = NULL,
@BY_USER VARCHAR(100) = NULL,
@BY_JOBSITE INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
		DECLARE @IDCHECK VARCHAR(100);
    BEGIN TRY
        IF @ACTION_SP = 'SELECT'
        BEGIN
            SELECT
							e.id,
							e.dormitory_id,
							d.dormitory_name,
							e.building_id,
							b.building_name,
							e.room_id,
							r.room_number,
							e.bed_number,
							e.description,
							e.status,
							CASE WHEN e.status = 'INACTIVE' THEN 'Unavailable'
								ELSE IIF(re.employee_name IS NOT NULL, 'Occupied', 'Vacant')
							END occupancy_status,
							re.employee_name resident_name,
							re.employee_nrp resident_nrp,
							re.employee_gender
						FROM dbo.beds e 
						JOIN dormitories d ON e.dormitory_id = d.id
						JOIN buildings b ON e.building_id = b.id
						JOIN rooms r ON e.room_id = r.id
						LEFT JOIN residents re ON e.id = re.bed_id
						WHERE e.deleted_at IS NULL and d.deleted_at  is null and b.deleted_at is null and r.deleted_at is null;
        END
        ELSE IF @ACTION_SP = 'INSERT'
        BEGIN
					SELECT
						@ROOM_ID = id
					FROM rooms WHERE deleted_at is null and dormitory_id = @DORMITORY_ID and
					building_id = @BUILDING_ID and id = @ROOM_ID;
					
					IF @IDCHECK IS NULL
					BEGIN
						SELECT 
							CAST(0 AS BIT) AS success,
							'Failed! Room not valid.' AS message
						RETURN
					END
					
					INSERT INTO dbo.beds (
						dormitory_id,
						building_id,
						room_id,
						bed_number,
						description,
						created_by,
						by_jobsite
					) VALUES (
						@DORMITORY_ID,
						@BUILDING_ID,
						@ROOM_ID,
						@BED_NUMBER,
						@DESCRIPTION,
						@BY_USER,
						@BY_JOBSITE
					);
					SELECT 
						CAST(1 AS BIT) AS success,
						'Bed saved successfully' AS message;
        END
        ELSE IF @ACTION_SP = 'UPDATE'
        BEGIN
					SELECT
						@IDCHECK = id
					FROM beds WHERE deleted_at is null and id = @ID;
						
					IF @IDCHECK IS NULL
					BEGIN
						SELECT 
							CAST(0 AS BIT) AS success,
							'Failed! Bed not found.' AS message
						RETURN
					END
					
					DECLARE @CHECKROOM VARCHAR(100);
					
					SELECT
						@CHECKROOM = id
					FROM rooms WHERE deleted_at is null and dormitory_id = @DORMITORY_ID and
					building_id = @BUILDING_ID and id = @ROOM_ID;
					
					IF @CHECKROOM IS NULL
					BEGIN
						SELECT 
							CAST(0 AS BIT) AS success,
							'Failed! Room not valid.' AS message
						RETURN
					END
						
					UPDATE [dbo].[beds] 
					SET 
						dormitory_id = @DORMITORY_ID,
						building_id = @BUILDING_ID,
						room_id = @ROOM_ID,
						bed_number = @BED_NUMBER,
						status = @STATUS,
						description = @DESCRIPTION,
						updated_at = GETDATE(),
						updated_by = @BY_USER
					WHERE [id] = @IDCHECK;
					
					SELECT 
						CAST(1 AS BIT) AS success,
						'Beds has been updated!' AS message;
        END
        ELSE IF @ACTION_SP = 'DELETE'
        BEGIN
					SELECT
						@IDCHECK = id
					FROM beds WHERE deleted_at is null and id = @ID;
						
					IF @IDCHECK IS NULL
					BEGIN
						SELECT 
							CAST(0 AS BIT) AS success,
							'Failed! Bed not found.' AS message
						RETURN
					END
					
					UPDATE [dbo].[beds] 
					SET 
						deleted_at = GETDATE(),
						deleted_by = @BY_USER
					WHERE [id] = @IDCHECK;
					
					SELECT 
						CAST(1 AS BIT) AS success,
						'Beds has been deleted!' AS message;
        END
        ELSE IF @ACTION_SP = 'GET'
        BEGIN
            SELECT
							e.id,
							e.dormitory_id,
							e.building_id,
							e.room_id,
							e.bed_number,
							e.description
						FROM dbo.beds e
						WHERE e.deleted_at IS NULL and e.room_id = @ROOM_ID;
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
			ERROR_NUMBER()  AS error_number,
			ERROR_MESSAGE() AS error_message;
    END CATCH
END