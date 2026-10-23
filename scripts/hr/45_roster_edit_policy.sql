-- =============================================
-- hr.roster_edit_policy — per-level roster remark edit window
-- Change H-n / who may edit WITHOUT app code changes:
--   UPDATE hr.roster_edit_policy SET past_days = 5 WHERE level_code = N'admin_section';
--   INSERT a row for a new level; omit or set can_edit=0 to deny.
-- Run AFTER 07_levels.sql / 27_levels_consolidate.sql
-- =============================================
IF OBJECT_ID(N'hr.roster_edit_policy', N'U') IS NULL
BEGIN
    CREATE TABLE hr.roster_edit_policy (
        id INT IDENTITY(1,1) NOT NULL,
        by_jobsite INT NOT NULL,
        level_code NVARCHAR(50) NOT NULL,
        can_edit BIT NOT NULL
            CONSTRAINT DF_hr_roster_edit_policy_can_edit DEFAULT (1),
        past_days INT NOT NULL
            CONSTRAINT DF_hr_roster_edit_policy_past_days DEFAULT (0),
        allow_past BIT NOT NULL
            CONSTRAINT DF_hr_roster_edit_policy_allow_past DEFAULT (0),
        description NVARCHAR(255) NULL,
        created_at DATETIME2 NOT NULL
            CONSTRAINT DF_hr_roster_edit_policy_created_at DEFAULT (SYSUTCDATETIME()),
        created_by INT NULL,
        updated_at DATETIME2 NULL,
        updated_by INT NULL,
        deleted_at DATETIME2 NULL,
        deleted_by INT NULL,
        CONSTRAINT PK_hr_roster_edit_policy PRIMARY KEY CLUSTERED (id),
        CONSTRAINT FK_hr_roster_edit_policy_jobsite
            FOREIGN KEY (by_jobsite) REFERENCES hr.jobsites (id),
        CONSTRAINT CK_hr_roster_edit_policy_past_days
            CHECK (past_days >= 0)
    );

    CREATE UNIQUE INDEX UQ_hr_roster_edit_policy_jobsite_level
        ON hr.roster_edit_policy (by_jobsite, level_code)
        WHERE deleted_at IS NULL;
END
GO

DECLARE @JobsiteId INT = 1;

-- Superadmin / sa: unlimited past dates
MERGE hr.roster_edit_policy AS t
USING (
    SELECT @JobsiteId AS by_jobsite, v.level_code, v.can_edit, v.past_days, v.allow_past, v.description
    FROM (VALUES
        (N'superadmin',    CAST(1 AS BIT), 0, CAST(1 AS BIT), N'Full bypass — any date'),
        (N'sa',            CAST(1 AS BIT), 0, CAST(1 AS BIT), N'Legacy superadmin alias'),
        (N'admin_section', CAST(1 AS BIT), 3, CAST(0 AS BIT), N'Legacy admin — H-3 window'),
        (N'admin',         CAST(1 AS BIT), 3, CAST(0 AS BIT), N'Legacy level code alias → same as admin_section')
    ) AS v(level_code, can_edit, past_days, allow_past, description)
) AS s
ON t.by_jobsite = s.by_jobsite
   AND t.level_code = s.level_code
   AND t.deleted_at IS NULL
WHEN MATCHED THEN
    UPDATE SET
        can_edit = s.can_edit,
        past_days = s.past_days,
        allow_past = s.allow_past,
        description = s.description,
        updated_at = SYSUTCDATETIME(),
        updated_by = NULL
WHEN NOT MATCHED THEN
    INSERT (by_jobsite, level_code, can_edit, past_days, allow_past, description, created_by)
    VALUES (s.by_jobsite, s.level_code, s.can_edit, s.past_days, s.allow_past, s.description, NULL);

-- approval_stage = all → today+ only (unless already seeded above)
INSERT INTO hr.roster_edit_policy (
    by_jobsite, level_code, can_edit, past_days, allow_past, description, created_by
)
SELECT
    @JobsiteId,
    l.code,
    1,
    0,
    0,
    N'approval_stage=all — today and future only', NULL
FROM hr.levels l
WHERE l.by_jobsite = @JobsiteId
  AND l.deleted_at IS NULL
  AND l.is_active = 1
  AND l.approval_stage = N'all'
  AND l.code NOT IN (N'superadmin', N'sa', N'admin_section', N'admin')
  AND NOT EXISTS (
      SELECT 1
      FROM hr.roster_edit_policy p
      WHERE p.by_jobsite = @JobsiteId
        AND p.level_code = l.code
        AND p.deleted_at IS NULL
  );

DECLARE @PolicyCount INT = (
    SELECT COUNT(*)
    FROM hr.roster_edit_policy
    WHERE by_jobsite = @JobsiteId AND deleted_at IS NULL
);
PRINT CONCAT('hr.roster_edit_policy rows: ', @PolicyCount);
GO
