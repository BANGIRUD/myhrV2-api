-- =============================================
-- Indexes for the sakit month list (parent start / parent end).
-- The list seeks rows that start in the month, plus rows that started
-- earlier and are still open into the month.
-- Run AFTER 65_sakit_checker_role.sql
-- =============================================
IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE name = N'IX_hr_workers_sickness_parent_start'
      AND object_id = OBJECT_ID(N'hr.workers_sickness')
)
BEGIN
    CREATE INDEX IX_hr_workers_sickness_parent_start
        ON hr.workers_sickness (by_jobsite, start_date)
        INCLUDE (end_date, nrp)
        WHERE deleted_at IS NULL AND ref_id IS NULL;
END;
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE name = N'IX_hr_workers_sickness_parent_end'
      AND object_id = OBJECT_ID(N'hr.workers_sickness')
)
BEGIN
    CREATE INDEX IX_hr_workers_sickness_parent_end
        ON hr.workers_sickness (by_jobsite, end_date)
        INCLUDE (start_date, nrp)
        WHERE deleted_at IS NULL AND ref_id IS NULL AND end_date IS NOT NULL;
END;
GO
