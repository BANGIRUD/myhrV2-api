-- =============================================
-- Convert created_by / updated_by / deleted_by from NVARCHAR(username)
-- to INT (hr.users.id) so audit actors can be joined for username/full_name.
-- Idempotent: skips columns that are already INT.
--
-- After this script, re-apply SP definitions so @BY_USER is INT
-- (run_migrate sorts by number, so use two commands):
--   node scripts/hr/run_migrate.js 54
--   node scripts/hr/run_migrate.js 14 15 25 28 36 39 42 46 48 49 52
-- =============================================
SET NOCOUNT ON;

IF OBJECT_ID(N'tempdb..#audit_tables') IS NOT NULL DROP TABLE #audit_tables;
CREATE TABLE #audit_tables (
    table_name SYSNAME NOT NULL PRIMARY KEY,
    has_jobsite BIT NOT NULL
);

INSERT INTO #audit_tables (table_name, has_jobsite) VALUES
    (N'jobsites', 0),
    (N'menu_privilege', 1),
    (N'users', 1),
    (N'menus', 1),
    (N'levels', 1),
    (N'level_permissions', 1),
    (N'enums', 1),
    (N'structure', 1),
    (N'workers', 1),
    (N'workers_vendor', 1),
    (N'workers_standby', 1),
    (N'workers_roster_kerja', 1),
    (N'attendance_ratio', 1),
    (N'workers_pola_kerja', 1),
    (N'workers_travel', 1),
    (N'workers_cuti_period_master', 1),
    (N'workers_cuti_period', 1),
    (N'workers_sickness', 1),
    (N'workers_permit', 1),
    (N'workers_cuti_kerja', 1),
    (N'workers_finger_error', 1),
    (N'date_holiday', 1),
    (N'workers_finger_log', 1),
    (N'workers_finger_oams', 1),
    (N'roster_edit_policy', 1),
    (N'edit_policy_modules', 1),
    (N'edit_policy', 1);

DECLARE @table SYSNAME;
DECLARE @hasJobsite BIT;
DECLARE @col SYSNAME;
DECLARE @sql NVARCHAR(MAX);
DECLARE @objId INT;
DECLARE @typeName SYSNAME;
DECLARE @tmp SYSNAME;

DECLARE table_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT table_name, has_jobsite FROM #audit_tables ORDER BY table_name;

OPEN table_cursor;
FETCH NEXT FROM table_cursor INTO @table, @hasJobsite;

WHILE @@FETCH_STATUS = 0
BEGIN
    SET @objId = OBJECT_ID(N'hr.' + QUOTENAME(@table));
    IF @objId IS NULL
    BEGIN
        PRINT CONCAT('skip missing table hr.', @table);
        FETCH NEXT FROM table_cursor INTO @table, @hasJobsite;
        CONTINUE;
    END

    DECLARE col_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT v.col
        FROM (VALUES (N'created_by'), (N'updated_by'), (N'deleted_by')) AS v(col);

    OPEN col_cursor;
    FETCH NEXT FROM col_cursor INTO @col;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SELECT @typeName = t.name
        FROM sys.columns c
        INNER JOIN sys.types t ON t.user_type_id = c.user_type_id
        WHERE c.object_id = @objId
          AND c.name = @col;

        IF @typeName IS NULL
        BEGIN
            PRINT CONCAT('skip missing column hr.', @table, '.', @col);
            FETCH NEXT FROM col_cursor INTO @col;
            CONTINUE;
        END

        IF @typeName IN (N'int', N'bigint', N'smallint', N'tinyint')
        BEGIN
            PRINT CONCAT('ok already int hr.', @table, '.', @col);
            FETCH NEXT FROM col_cursor INTO @col;
            CONTINUE;
        END

        IF @typeName NOT IN (N'nvarchar', N'varchar', N'nchar', N'char')
        BEGIN
            PRINT CONCAT('skip unsupported type hr.', @table, '.', @col, ' (', @typeName, ')');
            FETCH NEXT FROM col_cursor INTO @col;
            CONTINUE;
        END

        SET @tmp = @col + N'__id_tmp';
        IF COL_LENGTH(N'hr.' + @table, @tmp) IS NOT NULL
        BEGIN
            SET @sql = N'ALTER TABLE hr.' + QUOTENAME(@table) + N' DROP COLUMN ' + QUOTENAME(@tmp) + N';';
            EXEC sp_executesql @sql;
        END

        SET @sql = N'ALTER TABLE hr.' + QUOTENAME(@table) + N' ADD ' + QUOTENAME(@tmp) + N' INT NULL;';
        EXEC sp_executesql @sql;

        -- Backfill: numeric id → legacy_id → username(+jobsite) → username any
        SET @sql = N'
UPDATE t
SET t.' + QUOTENAME(@tmp) + N' = COALESCE(
    CASE
        WHEN TRY_CAST(NULLIF(LTRIM(RTRIM(t.' + QUOTENAME(@col) + N')), N'''') AS INT) IS NOT NULL
         AND EXISTS (
             SELECT 1 FROM hr.users u
             WHERE u.id = TRY_CAST(t.' + QUOTENAME(@col) + N' AS INT)
         )
        THEN TRY_CAST(t.' + QUOTENAME(@col) + N' AS INT)
    END,
    (
        SELECT TOP (1) u.id
        FROM hr.users u
        WHERE u.legacy_id = TRY_CAST(NULLIF(LTRIM(RTRIM(t.' + QUOTENAME(@col) + N')), N'''') AS INT)
          AND u.deleted_at IS NULL
        ORDER BY u.id
    ),
    (
        SELECT TOP (1) u.id
        FROM hr.users u
        WHERE u.username = NULLIF(LTRIM(RTRIM(t.' + QUOTENAME(@col) + N')), N'''')
          AND u.deleted_at IS NULL
          ' + CASE WHEN @hasJobsite = 1
                   THEN N'AND u.by_jobsite = t.by_jobsite'
                   ELSE N''
              END + N'
        ORDER BY u.id
    ),
    (
        SELECT TOP (1) u.id
        FROM hr.users u
        WHERE u.username = NULLIF(LTRIM(RTRIM(t.' + QUOTENAME(@col) + N')), N'''')
          AND u.deleted_at IS NULL
        ORDER BY u.id
    )
)
FROM hr.' + QUOTENAME(@table) + N' AS t
WHERE NULLIF(LTRIM(RTRIM(t.' + QUOTENAME(@col) + N')), N'''') IS NOT NULL;';
        EXEC sp_executesql @sql;

        SET @sql = N'ALTER TABLE hr.' + QUOTENAME(@table) + N' DROP COLUMN ' + QUOTENAME(@col) + N';';
        EXEC sp_executesql @sql;

        SET @sql = N'EXEC sp_rename N''hr.' + @table + N'.' + @tmp + N''', N''' + @col + N''', N''COLUMN'';';
        EXEC sp_executesql @sql;

        PRINT CONCAT('converted hr.', @table, '.', @col, ' → INT');
        FETCH NEXT FROM col_cursor INTO @col;
    END

    CLOSE col_cursor;
    DEALLOCATE col_cursor;

    FETCH NEXT FROM table_cursor INTO @table, @hasJobsite;
END

CLOSE table_cursor;
DEALLOCATE table_cursor;

DROP TABLE #audit_tables;

PRINT '54_audit_by_user_id: column conversion done.';
PRINT 'Next: node scripts/hr/run_migrate.js 14 15 25 28 36 39 42 46 48 49 52';
GO
