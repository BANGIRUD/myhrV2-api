-- =============================================
-- Generalized edit policy (multi-module)
--   hr.edit_policy_modules  — catalog (roster_kerja, …)
--   hr.edit_policy          — per module + level: can_edit / past_days / allow_past
-- Migrates rows from hr.roster_edit_policy → module_code = N'roster_kerja'
-- Menu: hr_edit_policy (/master/edit-policy) under Master Data
--         (rehomes / replaces hr_roster_edit_policy)
-- Run AFTER 45 + 46 + 47
-- =============================================

-- 1) Module catalog
IF OBJECT_ID(N'hr.edit_policy_modules', N'U') IS NULL
BEGIN
    CREATE TABLE hr.edit_policy_modules (
        id INT IDENTITY(1,1) NOT NULL,
        by_jobsite INT NOT NULL,
        module_code NVARCHAR(50) NOT NULL,
        module_name NVARCHAR(100) NOT NULL,
        description NVARCHAR(255) NULL,
        sort_order INT NOT NULL
            CONSTRAINT DF_hr_edit_policy_modules_sort DEFAULT (0),
        is_active BIT NOT NULL
            CONSTRAINT DF_hr_edit_policy_modules_active DEFAULT (1),
        created_at DATETIME2 NOT NULL
            CONSTRAINT DF_hr_edit_policy_modules_created_at DEFAULT (SYSUTCDATETIME()),
        created_by INT NULL,
        updated_at DATETIME2 NULL,
        updated_by INT NULL,
        deleted_at DATETIME2 NULL,
        deleted_by INT NULL,
        CONSTRAINT PK_hr_edit_policy_modules PRIMARY KEY CLUSTERED (id),
        CONSTRAINT FK_hr_edit_policy_modules_jobsite
            FOREIGN KEY (by_jobsite) REFERENCES hr.jobsites (id)
    );

    CREATE UNIQUE INDEX UQ_hr_edit_policy_modules_code
        ON hr.edit_policy_modules (by_jobsite, module_code)
        WHERE deleted_at IS NULL;
END
GO

-- 2) Generalized policy rows
IF OBJECT_ID(N'hr.edit_policy', N'U') IS NULL
BEGIN
    CREATE TABLE hr.edit_policy (
        id INT IDENTITY(1,1) NOT NULL,
        by_jobsite INT NOT NULL,
        module_code NVARCHAR(50) NOT NULL,
        level_code NVARCHAR(50) NOT NULL,
        can_edit BIT NOT NULL
            CONSTRAINT DF_hr_edit_policy_can_edit DEFAULT (1),
        past_days INT NOT NULL
            CONSTRAINT DF_hr_edit_policy_past_days DEFAULT (0),
        allow_past BIT NOT NULL
            CONSTRAINT DF_hr_edit_policy_allow_past DEFAULT (0),
        description NVARCHAR(255) NULL,
        created_at DATETIME2 NOT NULL
            CONSTRAINT DF_hr_edit_policy_created_at DEFAULT (SYSUTCDATETIME()),
        created_by INT NULL,
        updated_at DATETIME2 NULL,
        updated_by INT NULL,
        deleted_at DATETIME2 NULL,
        deleted_by INT NULL,
        CONSTRAINT PK_hr_edit_policy PRIMARY KEY CLUSTERED (id),
        CONSTRAINT FK_hr_edit_policy_jobsite
            FOREIGN KEY (by_jobsite) REFERENCES hr.jobsites (id),
        CONSTRAINT CK_hr_edit_policy_past_days
            CHECK (past_days >= 0)
    );

    CREATE UNIQUE INDEX UQ_hr_edit_policy_module_level
        ON hr.edit_policy (by_jobsite, module_code, level_code)
        WHERE deleted_at IS NULL;

    CREATE INDEX IX_hr_edit_policy_module
        ON hr.edit_policy (by_jobsite, module_code)
        WHERE deleted_at IS NULL;
END
GO

DECLARE @JobsiteId INT = 1;

-- Seed modules (add new modules here later — no new menu needed)
MERGE hr.edit_policy_modules AS t
USING (
    SELECT @JobsiteId AS by_jobsite, v.module_code, v.module_name, v.description, v.sort_order
    FROM (VALUES
        (N'roster_kerja', N'Roster Kerja', N'Jendela edit Status Absen (remark) harian', 10)
        -- Future examples (uncomment / insert when ready):
        -- (N'pola_kerja', N'Pola Kerja', N'…', 20),
        -- (N'attendance', N'Attendance', N'…', 30)
    ) AS v(module_code, module_name, description, sort_order)
) AS s
ON t.by_jobsite = s.by_jobsite
   AND t.module_code = s.module_code
   AND t.deleted_at IS NULL
WHEN MATCHED THEN
    UPDATE SET
        module_name = s.module_name,
        description = s.description,
        sort_order = s.sort_order,
        is_active = 1,
        updated_at = SYSUTCDATETIME(),
        updated_by = NULL
WHEN NOT MATCHED THEN
    INSERT (by_jobsite, module_code, module_name, description, sort_order, is_active, created_by)
    VALUES (s.by_jobsite, s.module_code, s.module_name, s.description, s.sort_order, 1, NULL);

-- Migrate legacy roster_edit_policy → edit_policy (module roster_kerja)
IF OBJECT_ID(N'hr.roster_edit_policy', N'U') IS NOT NULL
BEGIN
    INSERT INTO hr.edit_policy (
        by_jobsite, module_code, level_code, can_edit, past_days, allow_past,
        description, created_by, created_at, updated_by, updated_at
    )
    SELECT
        r.by_jobsite,
        N'roster_kerja',
        LOWER(r.level_code),
        r.can_edit,
        r.past_days,
        r.allow_past,
        r.description,
        r.created_by,
        r.created_at,
        r.updated_by,
        r.updated_at
    FROM hr.roster_edit_policy r
    WHERE r.deleted_at IS NULL
      AND NOT EXISTS (
          SELECT 1
          FROM hr.edit_policy e
          WHERE e.by_jobsite = r.by_jobsite
            AND e.module_code = N'roster_kerja'
            AND LOWER(e.level_code) = LOWER(r.level_code)
            AND e.deleted_at IS NULL
      );
END

-- Ensure defaults if migrate found nothing
IF NOT EXISTS (
    SELECT 1 FROM hr.edit_policy
    WHERE by_jobsite = @JobsiteId AND module_code = N'roster_kerja' AND deleted_at IS NULL
)
BEGIN
    INSERT INTO hr.edit_policy (
        by_jobsite, module_code, level_code, can_edit, past_days, allow_past, description, created_by
    )
    VALUES
        (@JobsiteId, N'roster_kerja', N'superadmin', 1, 0, 1, N'Full bypass — any date', NULL),
        (@JobsiteId, N'roster_kerja', N'sa', 1, 0, 1, N'Legacy superadmin alias', NULL),
        (@JobsiteId, N'roster_kerja', N'admin_section', 1, 3, 0, N'Legacy admin — H-3 window', NULL),
        (@JobsiteId, N'roster_kerja', N'admin', 1, 3, 0, N'Legacy level code alias', NULL);

    INSERT INTO hr.edit_policy (
        by_jobsite, module_code, level_code, can_edit, past_days, allow_past, description, created_by
    )
    SELECT
        @JobsiteId, N'roster_kerja', l.code, 1, 0, 0,
        N'approval_stage=all — today and future only', NULL
    FROM hr.levels l
    WHERE l.by_jobsite = @JobsiteId
      AND l.deleted_at IS NULL
      AND l.is_active = 1
      AND l.approval_stage = N'all'
      AND l.code NOT IN (N'superadmin', N'sa', N'admin_section', N'admin')
      AND NOT EXISTS (
          SELECT 1 FROM hr.edit_policy e
          WHERE e.by_jobsite = @JobsiteId
            AND e.module_code = N'roster_kerja'
            AND LOWER(e.level_code) = LOWER(l.code)
            AND e.deleted_at IS NULL
      );
END
GO

-- 3) SP for master UI
CREATE OR ALTER PROCEDURE hr.EDIT_POLICY_SP
    @ACTION_SP NVARCHAR(30) = NULL,
    @ID INT = NULL,
    @MODULE_CODE NVARCHAR(50) = NULL,
    @LEVEL_CODE NVARCHAR(50) = NULL,
    @CAN_EDIT BIT = NULL,
    @PAST_DAYS INT = NULL,
    @ALLOW_PAST BIT = NULL,
    @DESCRIPTION NVARCHAR(255) = NULL,
    @PAGE INT = 1,
    @PAGE_SIZE INT = 0,
    @SEARCH NVARCHAR(150) = NULL,
    @BY_USER INT = NULL,
    @BY_JOBSITE INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Jobsite INT = ISNULL(@BY_JOBSITE, 1);
    DECLARE @ModuleKey NVARCHAR(50) = LOWER(LTRIM(RTRIM(ISNULL(@MODULE_CODE, N''))));

    BEGIN TRY
        IF @ACTION_SP = N'LIST_MODULES'
        BEGIN
            SELECT
                m.id,
                m.module_code,
                m.module_name,
                m.description,
                m.sort_order,
                m.is_active
            FROM hr.edit_policy_modules m
            WHERE m.by_jobsite = @Jobsite
              AND m.deleted_at IS NULL
              AND m.is_active = 1
            ORDER BY m.sort_order ASC, m.module_name ASC;
        END
        ELSE IF @ACTION_SP = N'SELECT'
        BEGIN
            IF @ModuleKey = N''
                SET @ModuleKey = N'roster_kerja';

            DECLARE @Q NVARCHAR(150) = NULLIF(LTRIM(RTRIM(@SEARCH)), N'');
            IF @PAGE IS NULL OR @PAGE < 1 SET @PAGE = 1;
            IF @PAGE_SIZE IS NULL SET @PAGE_SIZE = 0;

            SELECT
                p.id,
                p.by_jobsite,
                p.module_code,
                ISNULL(mod.module_name, p.module_code) AS module_name,
                p.level_code,
                ISNULL(l.name, p.level_code) AS level_name,
                p.can_edit,
                p.past_days,
                p.allow_past,
                p.description,
                p.created_at,
                p.updated_at
            FROM hr.edit_policy p
            LEFT JOIN hr.edit_policy_modules mod
                ON mod.by_jobsite = p.by_jobsite
               AND LOWER(mod.module_code) = LOWER(p.module_code)
               AND mod.deleted_at IS NULL
            LEFT JOIN hr.levels l
                ON l.by_jobsite = p.by_jobsite
               AND LOWER(l.code) = LOWER(p.level_code)
               AND l.deleted_at IS NULL
            WHERE p.deleted_at IS NULL
              AND p.by_jobsite = @Jobsite
              AND LOWER(p.module_code) = @ModuleKey
              AND (
                    @Q IS NULL
                 OR p.level_code LIKE N'%' + @Q + N'%'
                 OR l.name LIKE N'%' + @Q + N'%'
                 OR p.description LIKE N'%' + @Q + N'%'
                  )
            ORDER BY p.level_code ASC
            OFFSET CASE WHEN @PAGE_SIZE > 0 THEN (@PAGE - 1) * @PAGE_SIZE ELSE 0 END ROWS
            FETCH NEXT CASE WHEN @PAGE_SIZE > 0 THEN @PAGE_SIZE ELSE 100000 END ROWS ONLY;

            SELECT COUNT(*) AS total_count
            FROM hr.edit_policy p
            LEFT JOIN hr.levels l
                ON l.by_jobsite = p.by_jobsite
               AND LOWER(l.code) = LOWER(p.level_code)
               AND l.deleted_at IS NULL
            WHERE p.deleted_at IS NULL
              AND p.by_jobsite = @Jobsite
              AND LOWER(p.module_code) = @ModuleKey
              AND (
                    @Q IS NULL
                 OR p.level_code LIKE N'%' + @Q + N'%'
                 OR l.name LIKE N'%' + @Q + N'%'
                 OR p.description LIKE N'%' + @Q + N'%'
                  );
        END
        ELSE IF @ACTION_SP = N'GET'
        BEGIN
            SELECT
                p.id,
                p.by_jobsite,
                p.module_code,
                ISNULL(mod.module_name, p.module_code) AS module_name,
                p.level_code,
                ISNULL(l.name, p.level_code) AS level_name,
                p.can_edit,
                p.past_days,
                p.allow_past,
                p.description,
                p.created_at,
                p.updated_at
            FROM hr.edit_policy p
            LEFT JOIN hr.edit_policy_modules mod
                ON mod.by_jobsite = p.by_jobsite
               AND LOWER(mod.module_code) = LOWER(p.module_code)
               AND mod.deleted_at IS NULL
            LEFT JOIN hr.levels l
                ON l.by_jobsite = p.by_jobsite
               AND LOWER(l.code) = LOWER(p.level_code)
               AND l.deleted_at IS NULL
            WHERE p.deleted_at IS NULL
              AND p.by_jobsite = @Jobsite
              AND p.id = @ID;
        END
        ELSE IF @ACTION_SP = N'INSERT'
        BEGIN
            IF @ModuleKey = N'' SET @ModuleKey = N'roster_kerja';
            DECLARE @InsCode NVARCHAR(50) = LOWER(LTRIM(RTRIM(ISNULL(@LEVEL_CODE, N''))));

            IF @InsCode = N''
            BEGIN
                SELECT CAST(0 AS BIT) AS success, N'level_code is required.' AS message;
                RETURN;
            END
            IF ISNULL(@PAST_DAYS, 0) < 0
            BEGIN
                SELECT CAST(0 AS BIT) AS success, N'past_days must be >= 0.' AS message;
                RETURN;
            END
            IF NOT EXISTS (
                SELECT 1 FROM hr.edit_policy_modules
                WHERE by_jobsite = @Jobsite AND deleted_at IS NULL
                  AND is_active = 1 AND LOWER(module_code) = @ModuleKey
            )
            BEGIN
                SELECT CAST(0 AS BIT) AS success,
                       N'Unknown or inactive module_code. Add it to hr.edit_policy_modules first.' AS message;
                RETURN;
            END
            IF EXISTS (
                SELECT 1 FROM hr.edit_policy
                WHERE by_jobsite = @Jobsite AND deleted_at IS NULL
                  AND LOWER(module_code) = @ModuleKey
                  AND LOWER(level_code) = @InsCode
            )
            BEGIN
                SELECT CAST(0 AS BIT) AS success,
                       N'A policy row already exists for this module + level.' AS message;
                RETURN;
            END

            INSERT INTO hr.edit_policy (
                by_jobsite, module_code, level_code, can_edit, past_days, allow_past, description, created_by
            )
            VALUES (
                @Jobsite, @ModuleKey, @InsCode,
                ISNULL(@CAN_EDIT, 1), ISNULL(@PAST_DAYS, 0), ISNULL(@ALLOW_PAST, 0),
                NULLIF(LTRIM(RTRIM(@DESCRIPTION)), N''), @BY_USER
            );

            SELECT CAST(1 AS BIT) AS success, N'Edit policy created.' AS message,
                   CAST(SCOPE_IDENTITY() AS INT) AS id;
        END
        ELSE IF @ACTION_SP = N'UPDATE'
        BEGIN
            IF @ID IS NULL
            BEGIN
                SELECT CAST(0 AS BIT) AS success, N'id is required.' AS message;
                RETURN;
            END
            IF @ModuleKey = N'' SET @ModuleKey = N'roster_kerja';
            DECLARE @UpdCode NVARCHAR(50) = LOWER(LTRIM(RTRIM(ISNULL(@LEVEL_CODE, N''))));
            IF @UpdCode = N''
            BEGIN
                SELECT CAST(0 AS BIT) AS success, N'level_code is required.' AS message;
                RETURN;
            END
            IF ISNULL(@PAST_DAYS, 0) < 0
            BEGIN
                SELECT CAST(0 AS BIT) AS success, N'past_days must be >= 0.' AS message;
                RETURN;
            END
            IF NOT EXISTS (
                SELECT 1 FROM hr.edit_policy
                WHERE id = @ID AND by_jobsite = @Jobsite AND deleted_at IS NULL
            )
            BEGIN
                SELECT CAST(0 AS BIT) AS success, N'Policy not found.' AS message;
                RETURN;
            END
            IF EXISTS (
                SELECT 1 FROM hr.edit_policy
                WHERE by_jobsite = @Jobsite AND deleted_at IS NULL
                  AND LOWER(module_code) = @ModuleKey
                  AND LOWER(level_code) = @UpdCode
                  AND id <> @ID
            )
            BEGIN
                SELECT CAST(0 AS BIT) AS success,
                       N'A policy row already exists for this module + level.' AS message;
                RETURN;
            END

            UPDATE hr.edit_policy
            SET module_code = @ModuleKey,
                level_code = @UpdCode,
                can_edit = ISNULL(@CAN_EDIT, can_edit),
                past_days = ISNULL(@PAST_DAYS, past_days),
                allow_past = ISNULL(@ALLOW_PAST, allow_past),
                description = NULLIF(LTRIM(RTRIM(@DESCRIPTION)), N''),
                updated_at = SYSUTCDATETIME(),
                updated_by = @BY_USER
            WHERE id = @ID AND by_jobsite = @Jobsite AND deleted_at IS NULL;

            SELECT CAST(1 AS BIT) AS success, N'Edit policy updated.' AS message, @ID AS id;
        END
        ELSE IF @ACTION_SP = N'DELETE'
        BEGIN
            IF @ID IS NULL
            BEGIN
                SELECT CAST(0 AS BIT) AS success, N'id is required.' AS message;
                RETURN;
            END
            IF NOT EXISTS (
                SELECT 1 FROM hr.edit_policy
                WHERE id = @ID AND by_jobsite = @Jobsite AND deleted_at IS NULL
            )
            BEGIN
                SELECT CAST(0 AS BIT) AS success, N'Policy not found.' AS message;
                RETURN;
            END

            UPDATE hr.edit_policy
            SET deleted_at = SYSUTCDATETIME(), deleted_by = @BY_USER
            WHERE id = @ID AND by_jobsite = @Jobsite AND deleted_at IS NULL;

            SELECT CAST(1 AS BIT) AS success, N'Edit policy deleted.' AS message, @ID AS id;
        END
        ELSE
        BEGIN
            SELECT CAST(0 AS BIT) AS success,
                   N'Unsupported ACTION_SP for EDIT_POLICY_SP.' AS message;
        END
    END TRY
    BEGIN CATCH
        SELECT CAST(0 AS BIT) AS success,
               CONCAT(N'EDIT_POLICY_SP error: ', ERROR_MESSAGE()) AS message;
    END CATCH
END
GO

-- 4) Menu: rehome roster-specific → generic Edit Policy
DECLARE @JobsiteId INT = 1;

DECLARE @MasterId INT = (
    SELECT TOP 1 id FROM hr.menus
    WHERE by_jobsite = @JobsiteId AND menu_code = N'hr_master' AND deleted_at IS NULL
);

IF @MasterId IS NULL
BEGIN
    THROW 50048, 'hr_master menu missing.', 1;
END;

-- Soft-delete old roster-only menu code if a separate hr_edit_policy will be inserted
-- Prefer rename-in-place when hr_roster_edit_policy exists
IF EXISTS (
    SELECT 1 FROM hr.menus
    WHERE by_jobsite = @JobsiteId AND menu_code = N'hr_roster_edit_policy' AND deleted_at IS NULL
)
BEGIN
    UPDATE hr.menus
    SET menu_code = N'hr_edit_policy',
        menu_name = N'Edit Policy',
        menu_url = N'/master/edit-policy',
        icon = N'pencil',
        menu_type = N'children',
        parent_id = @MasterId,
        sort_order = 28,
        show_sidebar = 1,
        is_active = 1,
        description = N'hr.edit_policy — H-n / can_edit per module + level',
        updated_at = SYSUTCDATETIME(),
        updated_by = NULL
    WHERE by_jobsite = @JobsiteId
      AND menu_code = N'hr_roster_edit_policy'
      AND deleted_at IS NULL
      AND NOT EXISTS (
          SELECT 1 FROM hr.menus
          WHERE by_jobsite = @JobsiteId AND menu_code = N'hr_edit_policy' AND deleted_at IS NULL
      );
END;

IF EXISTS (
    SELECT 1 FROM hr.menus
    WHERE by_jobsite = @JobsiteId AND menu_code = N'hr_edit_policy' AND deleted_at IS NULL
)
BEGIN
    UPDATE hr.menus
    SET menu_name = N'Edit Policy',
        menu_url = N'/master/edit-policy',
        icon = N'pencil',
        parent_id = @MasterId,
        sort_order = 28,
        show_sidebar = 1,
        is_active = 1,
        description = N'hr.edit_policy — H-n / can_edit per module + level',
        updated_at = SYSUTCDATETIME(),
        updated_by = NULL
    WHERE by_jobsite = @JobsiteId AND menu_code = N'hr_edit_policy' AND deleted_at IS NULL;
END
ELSE
BEGIN
    INSERT INTO hr.menus (
        by_jobsite, menu_code, menu_name, menu_url, icon, menu_type,
        parent_id, sort_order, show_sidebar, is_active, description, created_by
    )
    VALUES (
        @JobsiteId, N'hr_edit_policy', N'Edit Policy', N'/master/edit-policy', N'pencil', N'children',
        @MasterId, 28, 1, 1, N'hr.edit_policy — H-n / can_edit per module + level', NULL
    );
END;

-- Hide leftover roster-only menu if rename didn't consume it
UPDATE hr.menus
SET show_sidebar = 0,
    is_active = 0,
    deleted_at = SYSUTCDATETIME(),
    deleted_by = NULL
WHERE by_jobsite = @JobsiteId
  AND menu_code = N'hr_roster_edit_policy'
  AND deleted_at IS NULL;
GO

DECLARE @JobsiteId INT = 1;

INSERT INTO hr.level_permissions (
    by_jobsite, level_id, menu_id,
    can_read, can_insert, can_update, can_delete, can_export, can_approve,
    created_by
)
SELECT
    @JobsiteId, l.id, m.id,
    1, 0, 0, 0, 0, 0,
    NULL
FROM hr.levels l
CROSS JOIN hr.menus m
WHERE l.by_jobsite = @JobsiteId AND l.deleted_at IS NULL AND l.is_active = 1
  AND m.by_jobsite = @JobsiteId AND m.deleted_at IS NULL AND m.menu_code = N'hr_edit_policy'
  AND NOT EXISTS (
      SELECT 1 FROM hr.level_permissions lp
      WHERE lp.by_jobsite = @JobsiteId AND lp.level_id = l.id AND lp.menu_id = m.id AND lp.deleted_at IS NULL
  );
GO

DECLARE @JobsiteId INT = 1;

UPDATE lp
SET can_read = 1,
    can_insert = CASE WHEN l.approval_stage = N'all' THEN 1 ELSE 0 END,
    can_update = CASE WHEN l.approval_stage = N'all' THEN 1 ELSE 0 END,
    can_delete = CASE WHEN l.approval_stage = N'all' THEN 1 ELSE 0 END,
    can_export = 0,
    can_approve = 0,
    updated_at = SYSUTCDATETIME(),
    updated_by = NULL
FROM hr.level_permissions lp
INNER JOIN hr.menus m ON m.id = lp.menu_id AND m.by_jobsite = lp.by_jobsite
INNER JOIN hr.levels l ON l.id = lp.level_id AND l.by_jobsite = lp.by_jobsite
WHERE lp.by_jobsite = @JobsiteId
  AND lp.deleted_at IS NULL
  AND m.deleted_at IS NULL
  AND m.menu_code = N'hr_edit_policy'
  AND l.deleted_at IS NULL;

PRINT CONCAT('hr_edit_policy permissions updated: ', @@ROWCOUNT);
GO
