-- =============================================
-- Finger Pulse — schedule templates (manual)
-- Prefer CmdExec → Node runner (avoids MSDTC on linked-server INSERT…EXEC).
-- See docs/FINGER_PULSE.md
-- =============================================

/*
-- Example SQL Agent job step (Operating system / CmdExec):
--   Command:
--     node "D:\01_MyProjects\Company\SIS-AlamtriGeo\nodeJs\myhr-backend\scripts\hr\run_finger_pulse.js" pulse
--   Working directory:
--     D:\01_MyProjects\Company\SIS-AlamtriGeo\nodeJs\myhr-backend
--
-- Jobs:
--   MYHR_FingerPulse_Pulse      — every 15 minutes — pulse
--   MYHR_FingerPulse_Reconcile  — daily 23:00      — reconcile
--   MYHR_FingerPulse_Purge      — weekly Sunday 01:00 — purge
--
-- Pure T-SQL STATUS / PURGE (no Biostar pull):
--   EXEC hr.FINGER_PULSE_SP @ACTION_SP = N'STATUS';
--   EXEC hr.FINGER_PULSE_SP @ACTION_SP = N'PURGE';
*/
