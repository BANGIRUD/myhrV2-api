-- =============================================
-- hr.WORKERS_SP — paged list of employees (SIS / LS)
-- Actions: SELECT (fase 1 read-only)
--   @SOURCE = N'sis'     → hr.workers
--   @SOURCE = N'vendor'  → hr.workers_vendor (UI label: LS)
-- Filters: DEPARTMENT, SECTION, JOB_RANK, STATUS, STATUS_MODE, VENDOR, LOKASI_KERJA, SEARCH
--   @STATUS_MODE: active (default) | inactive | all
--     active   = same set as hr.v_workers_active (235–238, 242)
--     inactive = PHK and other non-active statuses
--     all      = every non-deleted row
--   @STATUS (specific enum id) overrides @STATUS_MODE when set.
-- Run AFTER 19_workers.sql + 21_workers_vendor.sql + 17_structure.sql + 16_enums.sql
-- =============================================
CREATE OR ALTER PROCEDURE hr.WORKERS_SP
    @ACTION_SP NVARCHAR(30) = NULL,
    @SOURCE NVARCHAR(20) = NULL,
    @ID INT = NULL,
    @DEPARTMENT INT = NULL,
    @SECTION INT = NULL,
    @JOB_RANK INT = NULL,
    @STATUS INT = NULL,
    @STATUS_MODE NVARCHAR(20) = N'active',
    @VENDOR NVARCHAR(255) = NULL,
    @LOKASI_KERJA NVARCHAR(50) = NULL,
    @PAGE INT = 1,
    @PAGE_SIZE INT = 0,
    @SEARCH NVARCHAR(150) = NULL,
    @BY_USER INT = NULL,
    @BY_JOBSITE INT = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Jobsite INT = ISNULL(@BY_JOBSITE, 1);
    DECLARE @Src NVARCHAR(20) = LOWER(LTRIM(RTRIM(ISNULL(@SOURCE, N''))));
    DECLARE @SearchTerm NVARCHAR(150) = NULLIF(LTRIM(RTRIM(@SEARCH)), N'');
    DECLARE @Lokasi NVARCHAR(50) = UPPER(LTRIM(RTRIM(ISNULL(@LOKASI_KERJA, N''))));
    DECLARE @VendorCode NVARCHAR(255) = NULLIF(LTRIM(RTRIM(@VENDOR)), N'');
    DECLARE @Mode NVARCHAR(20) = LOWER(LTRIM(RTRIM(ISNULL(@STATUS_MODE, N'active'))));

    IF @Mode NOT IN (N'active', N'inactive', N'all')
        SET @Mode = N'active';

    BEGIN TRY
        IF @ACTION_SP = N'SELECT'
        BEGIN
            IF @Src NOT IN (N'sis', N'vendor')
            BEGIN
                SELECT CAST(0 AS BIT) AS success,
                       N'SOURCE must be sis or vendor.' AS message;
                RETURN;
            END

            IF @PAGE IS NULL OR @PAGE < 1
                SET @PAGE = 1;

            IF @PAGE_SIZE IS NULL
                SET @PAGE_SIZE = 0;

            IF @Src = N'sis'
            BEGIN
                ;WITH base AS (
                    SELECT
                        w.id,
                        N'sis' AS worker_source,
                        w.by_jobsite,
                        w.nrp,
                        w.full_name,
                        w.jabatan,
                        w.job_rank,
                        jr.name AS job_rank_name,
                        w.department,
                        d.name AS department_name,
                        w.section,
                        s.name AS section_name,
                        w.status,
                        st.name AS status_name,
                        CASE
                            WHEN w.lokasi_kerja IN (
                                N'KM_35', N'KELANIS', N'KM 64', N'KM. 35', N'KM.35', N'HAULING'
                            ) THEN N'HAULING'
                            ELSE N'MINING'
                        END AS lokasi_kerja,
                        UPPER(w.staff_nonstaff) AS staff_nonstaff,
                        CAST(NULL AS NVARCHAR(255)) AS vendor_code,
                        CAST(NULL AS NVARCHAR(MAX)) AS vendor_name,
                        CONVERT(char(10), w.tanggal_masuk, 23) AS tanggal_masuk,
                        w.gender,
                        w.no_wa,
                        w.email_sis
                    FROM hr.workers w
                    LEFT JOIN hr.structure d
                        ON d.id = w.department
                       AND d.by_jobsite = w.by_jobsite
                       AND d.type = N'department'
                       AND d.deleted_at IS NULL
                    LEFT JOIN hr.structure s
                        ON s.id = w.section
                       AND s.by_jobsite = w.by_jobsite
                       AND s.type = N'section'
                       AND s.deleted_at IS NULL
                    LEFT JOIN hr.enums st
                        ON st.id = w.status
                       AND st.by_jobsite = w.by_jobsite
                       AND st.type = N'workers_status'
                       AND st.deleted_at IS NULL
                    LEFT JOIN hr.enums jr
                        ON jr.id = w.job_rank
                       AND jr.by_jobsite = w.by_jobsite
                       AND jr.type = N'position'
                       AND jr.deleted_at IS NULL
                    WHERE w.deleted_at IS NULL
                      AND w.by_jobsite = @Jobsite
                      AND (@DEPARTMENT IS NULL OR w.department = @DEPARTMENT)
                      AND (@SECTION IS NULL OR w.section = @SECTION)
                      AND (@JOB_RANK IS NULL OR w.job_rank = @JOB_RANK)
                      AND (
                            @STATUS IS NOT NULL AND w.status = @STATUS
                         OR @STATUS IS NULL AND @Mode = N'all'
                         OR @STATUS IS NULL AND @Mode = N'active'
                            AND w.status IN (235, 236, 237, 238, 242)
                         OR @STATUS IS NULL AND @Mode = N'inactive'
                            AND (w.status IS NULL OR w.status NOT IN (235, 236, 237, 238, 242))
                      )
                      AND (
                            @SearchTerm IS NULL
                         OR w.nrp LIKE @SearchTerm + N'%'
                         OR w.full_name LIKE N'%' + @SearchTerm + N'%'
                         OR w.jabatan LIKE N'%' + @SearchTerm + N'%'
                      )
                )
                SELECT
                    b.id,
                    b.worker_source,
                    b.by_jobsite,
                    b.nrp,
                    b.full_name,
                    b.jabatan,
                    b.job_rank,
                    b.job_rank_name,
                    b.department,
                    b.department_name,
                    b.section,
                    b.section_name,
                    b.status,
                    b.status_name,
                    b.lokasi_kerja,
                    b.staff_nonstaff,
                    b.vendor_code,
                    b.vendor_name,
                    b.tanggal_masuk,
                    b.gender,
                    b.no_wa,
                    b.email_sis
                FROM base b
                WHERE (
                        @Lokasi = N''
                     OR (@Lokasi = N'HAULING' AND b.lokasi_kerja = N'HAULING')
                     OR (@Lokasi = N'MINING' AND b.lokasi_kerja = N'MINING')
                  )
                ORDER BY
                    ISNULL(b.department_name, N''),
                    ISNULL(b.section_name, N''),
                    b.full_name,
                    b.nrp
                OFFSET CASE WHEN @PAGE_SIZE > 0 THEN (@PAGE - 1) * @PAGE_SIZE ELSE 0 END ROWS
                FETCH NEXT CASE WHEN @PAGE_SIZE > 0 THEN @PAGE_SIZE ELSE 100000 END ROWS ONLY;

                ;WITH base AS (
                    SELECT
                        w.id,
                        CASE
                            WHEN w.lokasi_kerja IN (
                                N'KM_35', N'KELANIS', N'KM 64', N'KM. 35', N'KM.35', N'HAULING'
                            ) THEN N'HAULING'
                            ELSE N'MINING'
                        END AS lokasi_kerja
                    FROM hr.workers w
                    WHERE w.deleted_at IS NULL
                      AND w.by_jobsite = @Jobsite
                      AND (@DEPARTMENT IS NULL OR w.department = @DEPARTMENT)
                      AND (@SECTION IS NULL OR w.section = @SECTION)
                      AND (@JOB_RANK IS NULL OR w.job_rank = @JOB_RANK)
                      AND (
                            @STATUS IS NOT NULL AND w.status = @STATUS
                         OR @STATUS IS NULL AND @Mode = N'all'
                         OR @STATUS IS NULL AND @Mode = N'active'
                            AND w.status IN (235, 236, 237, 238, 242)
                         OR @STATUS IS NULL AND @Mode = N'inactive'
                            AND (w.status IS NULL OR w.status NOT IN (235, 236, 237, 238, 242))
                      )
                      AND (
                            @SearchTerm IS NULL
                         OR w.nrp LIKE @SearchTerm + N'%'
                         OR w.full_name LIKE N'%' + @SearchTerm + N'%'
                         OR w.jabatan LIKE N'%' + @SearchTerm + N'%'
                      )
                )
                SELECT COUNT(*) AS total_count
                FROM base b
                WHERE (
                        @Lokasi = N''
                     OR (@Lokasi = N'HAULING' AND b.lokasi_kerja = N'HAULING')
                     OR (@Lokasi = N'MINING' AND b.lokasi_kerja = N'MINING')
                  );
            END
            ELSE
            BEGIN
                -- LS: view treats every non-deleted vendor as active; still honour
                -- status_mode using the same active id set when status is populated.
                ;WITH base AS (
                    SELECT
                        v.id,
                        N'vendor' AS worker_source,
                        v.by_jobsite,
                        v.nrp,
                        v.full_name,
                        v.jabatan,
                        v.job_rank,
                        jr.name AS job_rank_name,
                        v.department,
                        d.name AS department_name,
                        v.section,
                        s.name AS section_name,
                        v.status,
                        st.name AS status_name,
                        CASE
                            WHEN v.lokasi_kerja IN (
                                N'KM_35', N'KELANIS', N'KM 64', N'KM. 35', N'KM.35', N'HAULING'
                            ) THEN N'HAULING'
                            ELSE N'MINING'
                        END AS lokasi_kerja,
                        UPPER(v.staff_nonstaff) AS staff_nonstaff,
                        v.vendor AS vendor_code,
                        vn.name AS vendor_name,
                        CONVERT(char(10), v.tanggal_masuk, 23) AS tanggal_masuk,
                        v.gender,
                        v.no_wa,
                        v.email_sis
                    FROM hr.workers_vendor v
                    LEFT JOIN hr.structure d
                        ON d.id = v.department
                       AND d.by_jobsite = v.by_jobsite
                       AND d.type = N'department'
                       AND d.deleted_at IS NULL
                    LEFT JOIN hr.structure s
                        ON s.id = v.section
                       AND s.by_jobsite = v.by_jobsite
                       AND s.type = N'section'
                       AND s.deleted_at IS NULL
                    LEFT JOIN hr.enums st
                        ON st.id = v.status
                       AND st.by_jobsite = v.by_jobsite
                       AND st.type = N'workers_status'
                       AND st.deleted_at IS NULL
                    LEFT JOIN hr.enums jr
                        ON jr.id = v.job_rank
                       AND jr.by_jobsite = v.by_jobsite
                       AND jr.type = N'position'
                       AND jr.deleted_at IS NULL
                    LEFT JOIN hr.enums vn
                        ON vn.code = v.vendor
                       AND vn.by_jobsite = v.by_jobsite
                       AND vn.type = N'list_vendor'
                       AND vn.deleted_at IS NULL
                    WHERE v.deleted_at IS NULL
                      AND v.by_jobsite = @Jobsite
                      AND (@DEPARTMENT IS NULL OR v.department = @DEPARTMENT)
                      AND (@SECTION IS NULL OR v.section = @SECTION)
                      AND (@JOB_RANK IS NULL OR v.job_rank = @JOB_RANK)
                      AND (
                            @STATUS IS NOT NULL AND v.status = @STATUS
                         OR @STATUS IS NULL AND @Mode = N'all'
                         OR @STATUS IS NULL AND @Mode = N'active'
                            AND (v.status IS NULL OR v.status IN (235, 236, 237, 238, 242))
                         OR @STATUS IS NULL AND @Mode = N'inactive'
                            AND v.status IS NOT NULL
                            AND v.status NOT IN (235, 236, 237, 238, 242)
                      )
                      AND (@VendorCode IS NULL OR v.vendor = @VendorCode)
                      AND (
                            @SearchTerm IS NULL
                         OR v.nrp LIKE @SearchTerm + N'%'
                         OR v.full_name LIKE N'%' + @SearchTerm + N'%'
                         OR v.jabatan LIKE N'%' + @SearchTerm + N'%'
                      )
                )
                SELECT
                    b.id,
                    b.worker_source,
                    b.by_jobsite,
                    b.nrp,
                    b.full_name,
                    b.jabatan,
                    b.job_rank,
                    b.job_rank_name,
                    b.department,
                    b.department_name,
                    b.section,
                    b.section_name,
                    b.status,
                    b.status_name,
                    b.lokasi_kerja,
                    b.staff_nonstaff,
                    b.vendor_code,
                    b.vendor_name,
                    b.tanggal_masuk,
                    b.gender,
                    b.no_wa,
                    b.email_sis
                FROM base b
                WHERE (
                        @Lokasi = N''
                     OR (@Lokasi = N'HAULING' AND b.lokasi_kerja = N'HAULING')
                     OR (@Lokasi = N'MINING' AND b.lokasi_kerja = N'MINING')
                  )
                ORDER BY
                    ISNULL(b.department_name, N''),
                    ISNULL(b.section_name, N''),
                    b.full_name,
                    b.nrp
                OFFSET CASE WHEN @PAGE_SIZE > 0 THEN (@PAGE - 1) * @PAGE_SIZE ELSE 0 END ROWS
                FETCH NEXT CASE WHEN @PAGE_SIZE > 0 THEN @PAGE_SIZE ELSE 100000 END ROWS ONLY;

                ;WITH base AS (
                    SELECT
                        v.id,
                        CASE
                            WHEN v.lokasi_kerja IN (
                                N'KM_35', N'KELANIS', N'KM 64', N'KM. 35', N'KM.35', N'HAULING'
                            ) THEN N'HAULING'
                            ELSE N'MINING'
                        END AS lokasi_kerja
                    FROM hr.workers_vendor v
                    WHERE v.deleted_at IS NULL
                      AND v.by_jobsite = @Jobsite
                      AND (@DEPARTMENT IS NULL OR v.department = @DEPARTMENT)
                      AND (@SECTION IS NULL OR v.section = @SECTION)
                      AND (@JOB_RANK IS NULL OR v.job_rank = @JOB_RANK)
                      AND (
                            @STATUS IS NOT NULL AND v.status = @STATUS
                         OR @STATUS IS NULL AND @Mode = N'all'
                         OR @STATUS IS NULL AND @Mode = N'active'
                            AND (v.status IS NULL OR v.status IN (235, 236, 237, 238, 242))
                         OR @STATUS IS NULL AND @Mode = N'inactive'
                            AND v.status IS NOT NULL
                            AND v.status NOT IN (235, 236, 237, 238, 242)
                      )
                      AND (@VendorCode IS NULL OR v.vendor = @VendorCode)
                      AND (
                            @SearchTerm IS NULL
                         OR v.nrp LIKE @SearchTerm + N'%'
                         OR v.full_name LIKE N'%' + @SearchTerm + N'%'
                         OR v.jabatan LIKE N'%' + @SearchTerm + N'%'
                      )
                )
                SELECT COUNT(*) AS total_count
                FROM base b
                WHERE (
                        @Lokasi = N''
                     OR (@Lokasi = N'HAULING' AND b.lokasi_kerja = N'HAULING')
                     OR (@Lokasi = N'MINING' AND b.lokasi_kerja = N'MINING')
                  );
            END
        END
        ELSE IF @ACTION_SP = N'GET'
        BEGIN
            IF @Src NOT IN (N'sis', N'vendor') OR @ID IS NULL OR @ID <= 0
            BEGIN
                SELECT CAST(0 AS BIT) AS success,
                       N'SOURCE (sis|vendor) and ID are required.' AS message;
                RETURN;
            END

            IF @Src = N'sis'
            BEGIN
                SELECT
                    w.id,
                    N'sis' AS worker_source,
                    w.by_jobsite,
                    w.nrp,
                    w.nrp_int,
                    w.full_name,
                    w.jabatan,
                    w.level_jabatan,
                    lj.name AS level_jabatan_name,
                    w.klasifikasi_jabatan,
                    kj.name AS klasifikasi_jabatan_name,
                    w.job_rank,
                    jr.name AS job_rank_name,
                    w.department,
                    d.name AS department_name,
                    w.section,
                    s.name AS section_name,
                    w.grade,
                    w.area_kerja,
                    w.status_karyawan,
                    sk.name AS status_karyawan_name,
                    w.status,
                    st.name AS status_name,
                    CASE
                        WHEN w.lokasi_kerja IN (
                            N'KM_35', N'KELANIS', N'KM 64', N'KM. 35', N'KM.35', N'HAULING'
                        ) THEN N'HAULING'
                        ELSE N'MINING'
                    END AS lokasi_kerja,
                    UPPER(w.staff_nonstaff) AS staff_nonstaff,
                    w.lokal_nonlokal,
                    w.poh,
                    CONVERT(char(10), w.tanggal_masuk, 23) AS tanggal_masuk,
                    CONVERT(char(10), w.tanggal_akhirkontrak, 23) AS tanggal_akhirkontrak,
                    CONVERT(char(10), w.tanggal_akhirkontrak2, 23) AS tanggal_akhirkontrak2,
                    CONVERT(char(10), w.tanggal_efektif_diadaro, 23) AS tanggal_efektif_diadaro,
                    w.tempat_lahir,
                    w.kabupaten_lahir,
                    w.provinsi_lahir,
                    CONVERT(char(10), w.tanggal_lahir, 23) AS tanggal_lahir,
                    w.pendidikan,
                    w.nama_sekolah,
                    w.jurusan,
                    w.no_ijasah,
                    CONVERT(char(10), w.tanggal_masuk_sekolah, 23) AS tanggal_masuk_sekolah,
                    CONVERT(char(10), w.tanggal_lulus_sekolah, 23) AS tanggal_lulus_sekolah,
                    w.agama,
                    w.suku,
                    w.gender,
                    w.golongan_darah,
                    w.status_keluarga,
                    ms.name AS status_keluarga_name,
                    w.status_pajak,
                    w.alamat,
                    w.kabupaten_alamat,
                    w.provinsi_alamat,
                    w.no_wa,
                    w.no_telp,
                    w.keterangan_karyawan,
                    CONVERT(char(10), w.tanggal_keluar, 23) AS tanggal_keluar,
                    CONVERT(char(10), w.tanggal_final_pb, 23) AS tanggal_final_pb,
                    w.alasan_keluar,
                    w.email_sis,
                    w.email_pribadi,
                    w.no_bpjs_karyawan,
                    w.no_kk,
                    w.tinggal_dengan,
                    w.alamat_tinggal,
                    w.kabupaten_tinggal,
                    w.provinsi_tinggal,
                    w.alamat_tinggal_pasangan,
                    w.kab_tinggal_pasangan,
                    w.prov_tinggal_pasangan,
                    w.no_telp_darurat,
                    w.nama_telp_darurat,
                    w.alamat_no_telp_darurat,
                    w.hub_keluarga_darurat,
                    w.nama_telp_darurat2,
                    w.no_telp_darurat2,
                    w.alamat_no_telp_darurat2,
                    w.hub_keluarga_darurat2,
                    w.ukuran_baju,
                    w.ukuran_celana,
                    w.ukuran_sepatu,
                    w.sim,
                    w.jenis_penerimaan,
                    w.alamat_npwp,
                    CONVERT(char(10), w.tanggal_npwp, 23) AS tanggal_npwp,
                    w.jarak_titik_jemput,
                    w.no_ktp,
                    w.no_rekening,
                    w.nama_rekening,
                    w.bank_rekening,
                    w.no_jamsostek,
                    w.no_npwp,
                    w.no_simponi,
                    w.direct_indirect,
                    w.path_foto,
                    w.remark,
                    rm.name AS remark_name,
                    w.code_position,
                    CAST(NULL AS NVARCHAR(255)) AS vendor_code,
                    CAST(NULL AS NVARCHAR(MAX)) AS vendor_name,
                    w.created_at,
                    w.updated_at
                FROM hr.workers w
                LEFT JOIN hr.structure d
                    ON d.id = w.department
                   AND d.by_jobsite = w.by_jobsite
                   AND d.type = N'department'
                   AND d.deleted_at IS NULL
                LEFT JOIN hr.structure s
                    ON s.id = w.section
                   AND s.by_jobsite = w.by_jobsite
                   AND s.type = N'section'
                   AND s.deleted_at IS NULL
                LEFT JOIN hr.enums st
                    ON st.id = w.status
                   AND st.by_jobsite = w.by_jobsite
                   AND st.type = N'workers_status'
                   AND st.deleted_at IS NULL
                LEFT JOIN hr.enums sk
                    ON sk.id = w.status_karyawan
                   AND sk.by_jobsite = w.by_jobsite
                   AND sk.type = N'workers_status_karyawan'
                   AND sk.deleted_at IS NULL
                LEFT JOIN hr.enums kj
                    ON kj.id = w.klasifikasi_jabatan
                   AND kj.by_jobsite = w.by_jobsite
                   AND kj.type = N'job_rank_klasifikasi'
                   AND kj.deleted_at IS NULL
                LEFT JOIN hr.enums jr
                    ON jr.id = w.job_rank
                   AND jr.by_jobsite = w.by_jobsite
                   AND jr.type = N'position'
                   AND jr.deleted_at IS NULL
                LEFT JOIN hr.enums lj
                    ON lj.id = TRY_CAST(w.level_jabatan AS INT)
                   AND lj.by_jobsite = w.by_jobsite
                   AND lj.type = N'workers_position_level'
                   AND lj.deleted_at IS NULL
                LEFT JOIN hr.enums rm
                    ON rm.id = w.remark
                   AND rm.by_jobsite = w.by_jobsite
                   AND rm.type = N'workers_remark'
                   AND rm.deleted_at IS NULL
                LEFT JOIN hr.enums ms
                    ON ms.id = TRY_CAST(w.status_keluarga AS INT)
                   AND ms.by_jobsite = w.by_jobsite
                   AND ms.type = N'worker_married_status'
                   AND ms.deleted_at IS NULL
                WHERE w.deleted_at IS NULL
                  AND w.by_jobsite = @Jobsite
                  AND w.id = @ID;
            END
            ELSE
            BEGIN
                SELECT
                    v.id,
                    N'vendor' AS worker_source,
                    v.by_jobsite,
                    v.nrp,
                    v.nrp_int,
                    v.full_name,
                    v.jabatan,
                    v.level_jabatan,
                    lj.name AS level_jabatan_name,
                    TRY_CAST(v.klasifikasi_jabatan AS INT) AS klasifikasi_jabatan,
                    kj.name AS klasifikasi_jabatan_name,
                    v.job_rank,
                    jr.name AS job_rank_name,
                    v.department,
                    d.name AS department_name,
                    v.section,
                    s.name AS section_name,
                    v.grade,
                    v.area_kerja,
                    v.status_karyawan,
                    sk.name AS status_karyawan_name,
                    v.status,
                    st.name AS status_name,
                    CASE
                        WHEN v.lokasi_kerja IN (
                            N'KM_35', N'KELANIS', N'KM 64', N'KM. 35', N'KM.35', N'HAULING'
                        ) THEN N'HAULING'
                        ELSE N'MINING'
                    END AS lokasi_kerja,
                    UPPER(v.staff_nonstaff) AS staff_nonstaff,
                    v.lokal_nonlokal,
                    v.poh,
                    CONVERT(char(10), v.tanggal_masuk, 23) AS tanggal_masuk,
                    CONVERT(char(10), v.tanggal_akhirkontrak, 23) AS tanggal_akhirkontrak,
                    CONVERT(char(10), v.tanggal_akhirkontrak2, 23) AS tanggal_akhirkontrak2,
                    CONVERT(char(10), v.tanggal_efektif_diadaro, 23) AS tanggal_efektif_diadaro,
                    v.tempat_lahir,
                    v.kabupaten_lahir,
                    v.provinsi_lahir,
                    CONVERT(char(10), v.tanggal_lahir, 23) AS tanggal_lahir,
                    v.pendidikan,
                    v.nama_sekolah,
                    v.jurusan,
                    v.no_ijasah,
                    CONVERT(char(10), v.tanggal_masuk_sekolah, 23) AS tanggal_masuk_sekolah,
                    CONVERT(char(10), v.tanggal_lulus_sekolah, 23) AS tanggal_lulus_sekolah,
                    v.agama,
                    v.suku,
                    v.gender,
                    v.golongan_darah,
                    v.status_keluarga,
                    ms.name AS status_keluarga_name,
                    v.status_pajak,
                    v.alamat,
                    v.kabupaten_alamat,
                    v.provinsi_alamat,
                    v.no_wa,
                    v.no_telp,
                    v.keterangan_karyawan,
                    CONVERT(char(10), v.tanggal_keluar, 23) AS tanggal_keluar,
                    CONVERT(char(10), v.tanggal_final_pb, 23) AS tanggal_final_pb,
                    v.alasan_keluar,
                    v.email_sis,
                    v.email_pribadi,
                    v.no_bpjs_karyawan,
                    v.no_kk,
                    v.tinggal_dengan,
                    v.alamat_tinggal,
                    v.kabupaten_tinggal,
                    v.provinsi_tinggal,
                    v.alamat_tinggal_pasangan,
                    v.kab_tinggal_pasangan,
                    v.prov_tinggal_pasangan,
                    v.no_telp_darurat,
                    v.nama_telp_darurat,
                    v.alamat_no_telp_darurat,
                    v.hub_keluarga_darurat,
                    v.nama_telp_darurat2,
                    v.no_telp_darurat2,
                    v.alamat_no_telp_darurat2,
                    v.hub_keluarga_darurat2,
                    v.ukuran_baju,
                    v.ukuran_celana,
                    v.ukuran_sepatu,
                    v.sim,
                    v.jenis_penerimaan,
                    v.alamat_npwp,
                    CONVERT(char(10), v.tanggal_npwp, 23) AS tanggal_npwp,
                    v.jarak_titik_jemput,
                    v.no_ktp,
                    v.no_rekening,
                    v.nama_rekening,
                    v.bank_rekening,
                    v.no_jamsostek,
                    v.no_npwp,
                    v.no_simponi,
                    v.direct_indirect,
                    v.path_foto,
                    v.remark,
                    rm.name AS remark_name,
                    v.code_position,
                    v.vendor AS vendor_code,
                    vn.name AS vendor_name,
                    v.created_at,
                    v.updated_at
                FROM hr.workers_vendor v
                LEFT JOIN hr.structure d
                    ON d.id = v.department
                   AND d.by_jobsite = v.by_jobsite
                   AND d.type = N'department'
                   AND d.deleted_at IS NULL
                LEFT JOIN hr.structure s
                    ON s.id = v.section
                   AND s.by_jobsite = v.by_jobsite
                   AND s.type = N'section'
                   AND s.deleted_at IS NULL
                LEFT JOIN hr.enums st
                    ON st.id = v.status
                   AND st.by_jobsite = v.by_jobsite
                   AND st.type = N'workers_status'
                   AND st.deleted_at IS NULL
                LEFT JOIN hr.enums sk
                    ON sk.id = v.status_karyawan
                   AND sk.by_jobsite = v.by_jobsite
                   AND sk.type = N'workers_status_karyawan'
                   AND sk.deleted_at IS NULL
                LEFT JOIN hr.enums kj
                    ON kj.id = TRY_CAST(v.klasifikasi_jabatan AS INT)
                   AND kj.by_jobsite = v.by_jobsite
                   AND kj.type = N'job_rank_klasifikasi'
                   AND kj.deleted_at IS NULL
                LEFT JOIN hr.enums jr
                    ON jr.id = v.job_rank
                   AND jr.by_jobsite = v.by_jobsite
                   AND jr.type = N'position'
                   AND jr.deleted_at IS NULL
                LEFT JOIN hr.enums lj
                    ON lj.id = TRY_CAST(v.level_jabatan AS INT)
                   AND lj.by_jobsite = v.by_jobsite
                   AND lj.type = N'workers_position_level'
                   AND lj.deleted_at IS NULL
                LEFT JOIN hr.enums rm
                    ON rm.id = v.remark
                   AND rm.by_jobsite = v.by_jobsite
                   AND rm.type = N'workers_remark'
                   AND rm.deleted_at IS NULL
                LEFT JOIN hr.enums ms
                    ON ms.id = TRY_CAST(v.status_keluarga AS INT)
                   AND ms.by_jobsite = v.by_jobsite
                   AND ms.type = N'worker_married_status'
                   AND ms.deleted_at IS NULL
                LEFT JOIN hr.enums vn
                    ON vn.code = v.vendor
                   AND vn.by_jobsite = v.by_jobsite
                   AND vn.type = N'list_vendor'
                   AND vn.deleted_at IS NULL
                WHERE v.deleted_at IS NULL
                  AND v.by_jobsite = @Jobsite
                  AND v.id = @ID;
            END
        END
        ELSE
        BEGIN
            SELECT CAST(0 AS BIT) AS success,
                   N'Unknown ACTION_SP. Use SELECT or GET.' AS message;
        END
    END TRY
    BEGIN CATCH
        SELECT CAST(0 AS BIT) AS success,
               ERROR_MESSAGE() AS message;
    END CATCH
END
GO
