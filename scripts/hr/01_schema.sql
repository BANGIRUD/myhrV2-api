-- =============================================
-- MyHR multi-site schema (wave 1: auth foundation)
-- Schema: hr  (parallel to legacy dbo + ticketing)
-- Run order:
--   01_schema.sql
--   02_jobsites.sql
--   03_menu_privilege.sql
--   04_users.sql
--   05_views_login.sql
--   06_seed_from_dbo.sql   (optional ETL from legacy dbo)
--   … 07–13 levels/menus/permissions …
--   14_users_sp.sql
--   15_menus_sp.sql
--   16_enums.sql
--   17_structure.sql
--   18_seed_enums_structure_from_dbo.sql  (or seed_enums_structure_from_azure.js)
-- =============================================
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'hr')
    EXEC('CREATE SCHEMA hr');
GO
