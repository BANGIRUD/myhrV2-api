-- Recon auto-approve on insert (temporary scope).
-- When superadmin / sa / hr_administrator creates a sickness, permit, or
-- fingerprint row, promote it straight to "Approve by HR":
--   parent  verify=user          approve=true  by_verified = inputter
--   child   verify=section       approve=true  by_user/by_verified = inputter
--   child   verify=administrator approve=false by_user = inputter
-- Same three-row shape as a normal SH→HR approve chain; all verifiers = inputter.
-- Apply: node scripts/hr/run_migrate.js 84

SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE hr.RECON_AUTO_APPROVE_SP
    @ACTION_SP NVARCHAR(30) = NULL,
    @MODULE NVARCHAR(40) = NULL,       -- sickness | permit | finger_error
    @ID INT = NULL,
    @BY_USER INT = NULL,
    @BY_JOBSITE INT = 1
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Jobsite INT = ISNULL(@BY_JOBSITE, 1);
    DECLARE @ModuleKey NVARCHAR(40) = LOWER(LTRIM(RTRIM(ISNULL(@MODULE, N''))));
    DECLARE @LevelCode NVARCHAR(50) = NULL;
    DECLARE @ActorLegacy BIGINT = NULL;
    DECLARE @ParentOk BIT = 0;

    BEGIN TRY
        IF @ACTION_SP IS NULL OR LTRIM(RTRIM(@ACTION_SP)) = N''
        BEGIN
            SELECT CAST(0 AS BIT) AS success, N'ACTION_SP is required.' AS message, CAST(0 AS BIT) AS applied;
            RETURN;
        END

        IF @ACTION_SP <> N'APPLY'
        BEGIN
            SELECT CAST(0 AS BIT) AS success, N'Unknown ACTION_SP' AS message, CAST(0 AS BIT) AS applied;
            RETURN;
        END

        IF @ID IS NULL OR @BY_USER IS NULL
           OR @ModuleKey NOT IN (N'sickness', N'permit', N'finger_error')
        BEGIN
            SELECT CAST(0 AS BIT) AS success,
                   N'MODULE, ID, and BY_USER are required.' AS message,
                   CAST(0 AS BIT) AS applied;
            RETURN;
        END

        SELECT
            @ActorLegacy = CAST(ISNULL(u.legacy_id, u.id) AS BIGINT),
            @LevelCode = LOWER(LTRIM(RTRIM(ISNULL(l.code, N''))))
        FROM hr.users u
        LEFT JOIN hr.levels l
            ON l.id = u.level_id
           AND l.by_jobsite = u.by_jobsite
           AND l.deleted_at IS NULL
        WHERE u.id = @BY_USER
          AND u.by_jobsite = @Jobsite
          AND u.deleted_at IS NULL;

        IF @ActorLegacy IS NULL
        BEGIN
            SELECT CAST(0 AS BIT) AS success, N'Actor user not found.' AS message, CAST(0 AS BIT) AS applied;
            RETURN;
        END

        -- Temporary: recon input by superadmin / hr_administrator only (sa = superadmin alias).
        IF @LevelCode NOT IN (N'superadmin', N'sa', N'hr_administrator')
        BEGIN
            SELECT CAST(1 AS BIT) AS success,
                   N'Not eligible; left as pending.' AS message,
                   CAST(0 AS BIT) AS applied,
                   @ID AS id;
            RETURN;
        END

        IF @ModuleKey = N'sickness'
        BEGIN
            IF EXISTS (
                SELECT 1 FROM hr.workers_sickness s
                WHERE s.id = @ID
                  AND s.by_jobsite = @Jobsite
                  AND s.deleted_at IS NULL
                  AND s.ref_id IS NULL
                  AND s.verify = N'user'
                  AND ISNULL(s.approve, N'false') = N'false'
                  AND ISNULL(s.reject, N'false') = N'false'
                  AND NOT EXISTS (
                        SELECT 1 FROM hr.workers_sickness c
                        WHERE c.ref_id = s.id AND c.deleted_at IS NULL
                  )
            )
                SET @ParentOk = 1;

            IF @ParentOk = 0
            BEGIN
                SELECT CAST(0 AS BIT) AS success,
                       N'Sickness not pending or already has children.' AS message,
                       CAST(0 AS BIT) AS applied,
                       @ID AS id;
                RETURN;
            END

            BEGIN TRANSACTION;

            UPDATE hr.workers_sickness
            SET approve = N'true',
                reject = N'false',
                by_verified = @ActorLegacy,
                updated_at = SYSUTCDATETIME(),
                updated_by = @BY_USER
            WHERE id = @ID;

            INSERT INTO hr.workers_sickness (
                by_jobsite, ref_id, key_id, [date], nrp, nrp_int, full_name,
                diagnosa, name_doctor, name_agency, date_issue, category,
                start_date, end_date, description, note,
                verify, approve, reject, by_user, by_verified,
                created_by, updated_at, updated_by
            )
            SELECT
                s.by_jobsite, s.id,
                UPPER(CONVERT(VARCHAR(40), HASHBYTES(
                    'SHA1',
                    CONCAT(CAST(s.id AS NVARCHAR(20)), N'_sec_', CONVERT(VARCHAR(19), GETDATE(), 120))
                ), 2)),
                s.[date], s.nrp, s.nrp_int, s.full_name,
                s.diagnosa, s.name_doctor, s.name_agency, s.date_issue, s.category,
                s.start_date, s.end_date, s.description, s.note,
                N'section', N'true', N'false',
                @ActorLegacy, @ActorLegacy,
                @BY_USER, SYSUTCDATETIME(), @BY_USER
            FROM hr.workers_sickness s
            WHERE s.id = @ID;

            INSERT INTO hr.workers_sickness (
                by_jobsite, ref_id, key_id, [date], nrp, nrp_int, full_name,
                diagnosa, name_doctor, name_agency, date_issue, category,
                start_date, end_date, description, note,
                verify, approve, reject, by_user,
                created_by, updated_at, updated_by
            )
            SELECT
                s.by_jobsite, s.id,
                UPPER(CONVERT(VARCHAR(40), HASHBYTES(
                    'SHA1',
                    CONCAT(CAST(s.id AS NVARCHAR(20)), N'_hr_', CONVERT(VARCHAR(19), GETDATE(), 120))
                ), 2)),
                s.[date], s.nrp, s.nrp_int, s.full_name,
                s.diagnosa, s.name_doctor, s.name_agency, s.date_issue, s.category,
                s.start_date, s.end_date, s.description, s.note,
                N'administrator', N'false', N'false',
                @ActorLegacy,
                @BY_USER, SYSUTCDATETIME(), @BY_USER
            FROM hr.workers_sickness s
            WHERE s.id = @ID;

            COMMIT TRANSACTION;
        END
        ELSE IF @ModuleKey = N'permit'
        BEGIN
            IF EXISTS (
                SELECT 1 FROM hr.workers_permit s
                WHERE s.id = @ID
                  AND s.by_jobsite = @Jobsite
                  AND s.deleted_at IS NULL
                  AND s.ref_id IS NULL
                  AND s.verify = N'user'
                  AND ISNULL(s.approve, N'false') = N'false'
                  AND ISNULL(s.reject, N'false') = N'false'
                  AND NOT EXISTS (
                        SELECT 1 FROM hr.workers_permit c
                        WHERE c.ref_id = s.id AND c.deleted_at IS NULL
                  )
            )
                SET @ParentOk = 1;

            IF @ParentOk = 0
            BEGIN
                SELECT CAST(0 AS BIT) AS success,
                       N'Permit not pending or already has children.' AS message,
                       CAST(0 AS BIT) AS applied,
                       @ID AS id;
                RETURN;
            END

            BEGIN TRANSACTION;

            UPDATE hr.workers_permit
            SET approve = N'true',
                reject = N'false',
                by_verified = @ActorLegacy,
                updated_at = SYSUTCDATETIME(),
                updated_by = @BY_USER
            WHERE id = @ID;

            INSERT INTO hr.workers_permit (
                by_jobsite, ref_id, key_id, [date], nrp, nrp_int, full_name,
                category, [day], path_evident,
                start_date, end_date, description, note,
                verify, approve, reject, by_user, by_verified,
                created_by, updated_at, updated_by
            )
            SELECT
                s.by_jobsite, s.id,
                UPPER(CONVERT(VARCHAR(40), HASHBYTES(
                    'SHA1',
                    CONCAT(CAST(s.id AS NVARCHAR(20)), N'_sec_', CONVERT(VARCHAR(19), GETDATE(), 120))
                ), 2)),
                s.[date], s.nrp, s.nrp_int, s.full_name,
                s.category, s.[day], s.path_evident,
                s.start_date, s.end_date, s.description, s.note,
                N'section', N'true', N'false',
                @ActorLegacy, @ActorLegacy,
                @BY_USER, SYSUTCDATETIME(), @BY_USER
            FROM hr.workers_permit s
            WHERE s.id = @ID;

            INSERT INTO hr.workers_permit (
                by_jobsite, ref_id, key_id, [date], nrp, nrp_int, full_name,
                category, [day], path_evident,
                start_date, end_date, description, note,
                verify, approve, reject, by_user,
                created_by, updated_at, updated_by
            )
            SELECT
                s.by_jobsite, s.id,
                UPPER(CONVERT(VARCHAR(40), HASHBYTES(
                    'SHA1',
                    CONCAT(CAST(s.id AS NVARCHAR(20)), N'_hr_', CONVERT(VARCHAR(19), GETDATE(), 120))
                ), 2)),
                s.[date], s.nrp, s.nrp_int, s.full_name,
                s.category, s.[day], s.path_evident,
                s.start_date, s.end_date, s.description, s.note,
                N'administrator', N'false', N'false',
                @ActorLegacy,
                @BY_USER, SYSUTCDATETIME(), @BY_USER
            FROM hr.workers_permit s
            WHERE s.id = @ID;

            COMMIT TRANSACTION;
        END
        ELSE -- finger_error
        BEGIN
            IF EXISTS (
                SELECT 1 FROM hr.workers_finger_error s
                WHERE s.id = @ID
                  AND s.by_jobsite = @Jobsite
                  AND s.deleted_at IS NULL
                  AND s.ref_id IS NULL
                  AND s.verify = N'user'
                  AND ISNULL(s.approve, N'false') = N'false'
                  AND ISNULL(s.reject, N'false') = N'false'
                  AND NOT EXISTS (
                        SELECT 1 FROM hr.workers_finger_error c
                        WHERE c.ref_id = s.id AND c.deleted_at IS NULL
                  )
            )
                SET @ParentOk = 1;

            IF @ParentOk = 0
            BEGIN
                SELECT CAST(0 AS BIT) AS success,
                       N'Fingerprint not pending or already has children.' AS message,
                       CAST(0 AS BIT) AS applied,
                       @ID AS id;
                RETURN;
            END

            BEGIN TRANSACTION;

            UPDATE hr.workers_finger_error
            SET approve = N'true',
                reject = N'false',
                by_verified = @ActorLegacy,
                updated_at = SYSUTCDATETIME(),
                updated_by = @BY_USER
            WHERE id = @ID;

            INSERT INTO hr.workers_finger_error (
                by_jobsite, ref_id, key_id, [date], nrp, nrp_int, full_name,
                location, finger_in, finger_out, category, shift, remark,
                path_evident, description, note,
                verify, approve, reject, by_user, by_verified,
                created_by, updated_at, updated_by
            )
            SELECT
                s.by_jobsite, s.id,
                UPPER(CONVERT(VARCHAR(40), HASHBYTES(
                    'SHA1',
                    CONCAT(CAST(s.id AS NVARCHAR(20)), N'_sec_', CONVERT(VARCHAR(19), GETDATE(), 120))
                ), 2)),
                s.[date], s.nrp, s.nrp_int, s.full_name,
                s.location, s.finger_in, s.finger_out, s.category, s.shift, s.remark,
                s.path_evident, s.description, s.note,
                N'section', N'true', N'false',
                @ActorLegacy, @ActorLegacy,
                @BY_USER, SYSUTCDATETIME(), @BY_USER
            FROM hr.workers_finger_error s
            WHERE s.id = @ID;

            INSERT INTO hr.workers_finger_error (
                by_jobsite, ref_id, key_id, [date], nrp, nrp_int, full_name,
                location, finger_in, finger_out, category, shift, remark,
                path_evident, description, note,
                verify, approve, reject, by_user,
                created_by, updated_at, updated_by
            )
            SELECT
                s.by_jobsite, s.id,
                UPPER(CONVERT(VARCHAR(40), HASHBYTES(
                    'SHA1',
                    CONCAT(CAST(s.id AS NVARCHAR(20)), N'_hr_', CONVERT(VARCHAR(19), GETDATE(), 120))
                ), 2)),
                s.[date], s.nrp, s.nrp_int, s.full_name,
                s.location, s.finger_in, s.finger_out, s.category, s.shift, s.remark,
                s.path_evident, s.description, s.note,
                N'administrator', N'false', N'false',
                @ActorLegacy,
                @BY_USER, SYSUTCDATETIME(), @BY_USER
            FROM hr.workers_finger_error s
            WHERE s.id = @ID;

            COMMIT TRANSACTION;
        END

        SELECT CAST(1 AS BIT) AS success,
               N'Recon auto-approved to HR.' AS message,
               CAST(1 AS BIT) AS applied,
               @ID AS id;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        SELECT CAST(0 AS BIT) AS success, ERROR_MESSAGE() AS message, CAST(0 AS BIT) AS applied;
    END CATCH
END
GO
