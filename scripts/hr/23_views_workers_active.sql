-- =============================================
-- View: hr.v_workers_active — active employees + vendor workers
-- hr replacement for dbo.v_workers_active.
--   sis    : hr.workers, status in hr.enums workers_status
--            235 STAFF MINING, 236 NONSTAFF MINING, 237 STAFF HAULING,
--            238 NONSTAFF HAULING, 242 MAGANG
--   vendor : hr.workers_vendor, any non-deleted row
-- (worker_source, id) is unique; id alone overlaps between sources.
-- Run AFTER 19_workers.sql + 21_workers_vendor.sql
-- =============================================
CREATE OR ALTER VIEW hr.v_workers_active
AS
WITH workers_union AS (
    SELECT
        w.id,
        N'sis' AS worker_source,
        w.by_jobsite,
        w.key_id,
        w.nrp,
        CAST(w.nrp_int AS NVARCHAR(255)) AS nrp_int,
        CAST(w.nrp_int AS NVARCHAR(30)) AS id_finger,
        w.full_name,
        w.jabatan,
        w.level_jabatan,
        w.job_rank,
        w.department,
        w.section,
        w.grade,
        w.status,
        w.lokasi_kerja,
        w.staff_nonstaff,
        w.lokal_nonlokal,
        w.gender,
        w.email_sis,
        w.no_wa,
        w.path_foto,
        w.tanggal_masuk,
        CAST(NULL AS NVARCHAR(255)) AS vendor_code,
        w.legacy_id
    FROM hr.workers w
    WHERE w.deleted_at IS NULL
      AND w.status IN (235, 236, 237, 238, 242)

    UNION ALL

    SELECT
        v.id,
        N'vendor',
        v.by_jobsite,
        v.key_id,
        v.nrp,
        v.nrp_int,
        v.id_finger,
        v.full_name,
        v.jabatan,
        v.level_jabatan,
        v.job_rank,
        v.department,
        v.section,
        v.grade,
        v.status,
        v.lokasi_kerja,
        v.staff_nonstaff,
        v.lokal_nonlokal,
        v.gender,
        v.email_sis,
        v.no_wa,
        v.path_foto,
        v.tanggal_masuk,
        v.vendor,
        v.legacy_id
    FROM hr.workers_vendor v
    WHERE v.deleted_at IS NULL
)
SELECT
    wu.id,
    wu.worker_source,
    wu.by_jobsite,
    wu.key_id,
    wu.nrp,
    wu.nrp_int,
    wu.id_finger,
    wu.full_name,
    wu.jabatan,
    wu.level_jabatan,
    wu.job_rank,
    wu.department,
    d.name AS department_name,
    wu.section,
    s.name AS section_name,
    wu.grade,
    wu.status,
    st.name AS status_name,
    CASE
        WHEN wu.lokasi_kerja IN (N'KM_35', N'KELANIS', N'KM 64', N'KM. 35', N'KM.35', N'HAULING')
            THEN N'HAULING'
        ELSE N'MINING'
    END AS lokasi_kerja,
    UPPER(wu.staff_nonstaff) AS staff_nonstaff,
    wu.lokal_nonlokal,
    wu.gender,
    wu.email_sis,
    wu.no_wa,
    wu.path_foto,
    wu.tanggal_masuk,
    wu.vendor_code,
    vn.name AS vendor_name,
    wu.legacy_id
FROM workers_union wu
LEFT JOIN hr.structure d
    ON d.id = wu.department
   AND d.by_jobsite = wu.by_jobsite
   AND d.type = N'department'
LEFT JOIN hr.structure s
    ON s.id = wu.section
   AND s.by_jobsite = wu.by_jobsite
   AND s.type = N'section'
LEFT JOIN hr.enums st
    ON st.id = wu.status
   AND st.by_jobsite = wu.by_jobsite
   AND st.type = N'workers_status'
LEFT JOIN hr.enums vn
    ON vn.code = wu.vendor_code
   AND vn.by_jobsite = wu.by_jobsite
   AND vn.type = N'list_vendor'
   AND vn.deleted_at IS NULL;
GO
