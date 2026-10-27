-- =============================================
-- hr.WORKERS_SP — employees SIS / LS
-- Actions: SELECT | GET | SELECT_EXPORT | INSERT
--   @SOURCE = N'sis'     → hr.workers
--   @SOURCE = N'vendor'  → hr.workers_vendor (UI label: LS)
-- INSERT: new NRP only (PKWT = new row); active NRP → fail
-- SELECT_EXPORT: round-trip columns (names); Grade included (API strips)
-- Also grants can_insert / can_export on hr_employees_sis / hr_employees_ls
-- Run AFTER 88_workers_sp.sql + 89_employees_menus.sql
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
    @LOKASI_KERJA NVARCHAR(255) = NULL,
    @PAGE INT = 1,
    @PAGE_SIZE INT = 0,
    @SEARCH NVARCHAR(150) = NULL,
    @BY_USER INT = NULL,
    @BY_JOBSITE INT = NULL,
    -- INSERT fields (text accepts name or id for structure/enums)
    @NRP NVARCHAR(255) = NULL,
    @FULL_NAME NVARCHAR(255) = NULL,
    @JABATAN NVARCHAR(255) = NULL,
    @DEPARTMENT_TEXT NVARCHAR(255) = NULL,
    @SECTION_TEXT NVARCHAR(255) = NULL,
    @STATUS_TEXT NVARCHAR(255) = NULL,
    @LEVEL_JABATAN NVARCHAR(255) = NULL,
    @KLASIFIKASI_JABATAN NVARCHAR(255) = NULL,
    @JOB_RANK_TEXT NVARCHAR(255) = NULL,
    @GRADE NVARCHAR(255) = NULL,
    @AREA_KERJA NVARCHAR(255) = NULL,
    @STATUS_KARYAWAN_TEXT NVARCHAR(255) = NULL,
    @STAFF_NONSTAFF NVARCHAR(255) = NULL,
    @POH NVARCHAR(255) = NULL,
    @TANGGAL_MASUK DATE = NULL,
    @TANGGAL_AKHIRKONTRAK DATE = NULL,
    @TANGGAL_EFEKTIF_DIADARO DATE = NULL,
    @TEMPAT_LAHIR NVARCHAR(255) = NULL,
    @KABUPATEN_LAHIR NVARCHAR(255) = NULL,
    @PROVINSI_LAHIR NVARCHAR(255) = NULL,
    @TANGGAL_LAHIR DATE = NULL,
    @PENDIDIKAN NVARCHAR(255) = NULL,
    @NAMA_SEKOLAH NVARCHAR(255) = NULL,
    @JURUSAN NVARCHAR(255) = NULL,
    @NO_IJASAH NVARCHAR(255) = NULL,
    @TANGGAL_MASUK_SEKOLAH DATE = NULL,
    @TANGGAL_LULUS_SEKOLAH DATE = NULL,
    @AGAMA NVARCHAR(255) = NULL,
    @SUKU NVARCHAR(255) = NULL,
    @GOLONGAN_DARAH NVARCHAR(255) = NULL,
    @DIRECT_INDIRECT NVARCHAR(255) = NULL,
    @REMARK_TEXT NVARCHAR(255) = NULL,
    @GENDER NVARCHAR(255) = NULL,
    @STATUS_KELUARGA NVARCHAR(255) = NULL,
    @ALAMAT NVARCHAR(MAX) = NULL,
    @ID_FINGER NVARCHAR(30) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Jobsite INT = ISNULL(@BY_JOBSITE, 1);
    DECLARE @Src NVARCHAR(20) = LOWER(LTRIM(RTRIM(ISNULL(@SOURCE, N''))));
    DECLARE @SearchTerm NVARCHAR(150) = NULLIF(LTRIM(RTRIM(@SEARCH)), N'');
    DECLARE @Lokasi NVARCHAR(255) = UPPER(LTRIM(RTRIM(ISNULL(@LOKASI_KERJA, N''))));
    DECLARE @VendorCode NVARCHAR(255) = NULLIF(LTRIM(RTRIM(@VENDOR)), N'');
    DECLARE @Mode NVARCHAR(20) = LOWER(LTRIM(RTRIM(ISNULL(@STATUS_MODE, N'active'))));

    -- INSERT resolvers
    DECLARE @NrpClean NVARCHAR(255) = UPPER(LTRIM(RTRIM(ISNULL(@NRP, N''))));
    DECLARE @NameClean NVARCHAR(255) = UPPER(LTRIM(RTRIM(ISNULL(@FULL_NAME, N''))));
    DECLARE @DeptId INT = NULL;
    DECLARE @SecId INT = NULL;
    DECLARE @StatusId INT = NULL;
    DECLARE @JobRankId INT = NULL;
    DECLARE @StatusKarId INT = NULL;
    DECLARE @LevelJabId INT = NULL;
    DECLARE @KlasId INT = NULL;
    DECLARE @RemarkId INT = NULL;
    DECLARE @NrpInt INT = NULL;
    DECLARE @KeyId NVARCHAR(255) = NULL;
    DECLARE @VendorClean NVARCHAR(255) = NULLIF(UPPER(LTRIM(RTRIM(@VENDOR))), N'');
    DECLARE @FingerClean NVARCHAR(30) = NULLIF(LTRIM(RTRIM(@ID_FINGER)), N'');
    DECLARE @NewId INT = NULL;

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
        ELSE IF @ACTION_SP = N'SELECT_EXPORT'
        BEGIN
            IF @Src NOT IN (N'sis', N'vendor')
            BEGIN
                SELECT CAST(0 AS BIT) AS success,
                       N'SOURCE must be sis or vendor.' AS message;
                RETURN;
            END

            IF @Src = N'sis'
            BEGIN
                SELECT
                    w.nrp,
                    w.full_name,
                    w.jabatan,
                    d.name AS department,
                    s.name AS section,
                    st.name AS status,
                    ISNULL(lj.name, w.level_jabatan) AS level_jabatan,
                    kj.name AS klasifikasi_jabatan,
                    jr.name AS job_rank,
                    w.grade,
                    w.area_kerja,
                    sk.name AS status_karyawan,
                    w.lokasi_kerja,
                    UPPER(w.staff_nonstaff) AS staff_nonstaff,
                    w.poh,
                    CONVERT(char(10), w.tanggal_masuk, 23) AS tanggal_masuk,
                    CONVERT(char(10), w.tanggal_akhirkontrak, 23) AS tanggal_akhirkontrak,
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
                    w.golongan_darah,
                    w.direct_indirect,
                    rm.name AS remark
                FROM hr.workers w
                LEFT JOIN hr.structure d
                    ON d.id = w.department AND d.by_jobsite = w.by_jobsite
                   AND d.type = N'department' AND d.deleted_at IS NULL
                LEFT JOIN hr.structure s
                    ON s.id = w.section AND s.by_jobsite = w.by_jobsite
                   AND s.type = N'section' AND s.deleted_at IS NULL
                LEFT JOIN hr.enums st
                    ON st.id = w.status AND st.by_jobsite = w.by_jobsite
                   AND st.type = N'workers_status' AND st.deleted_at IS NULL
                LEFT JOIN hr.enums sk
                    ON sk.id = w.status_karyawan AND sk.by_jobsite = w.by_jobsite
                   AND sk.type = N'workers_status_karyawan' AND sk.deleted_at IS NULL
                LEFT JOIN hr.enums kj
                    ON kj.id = w.klasifikasi_jabatan AND kj.by_jobsite = w.by_jobsite
                   AND kj.type = N'job_rank_klasifikasi' AND kj.deleted_at IS NULL
                LEFT JOIN hr.enums jr
                    ON jr.id = w.job_rank AND jr.by_jobsite = w.by_jobsite
                   AND jr.type = N'position' AND jr.deleted_at IS NULL
                LEFT JOIN hr.enums lj
                    ON lj.id = TRY_CAST(w.level_jabatan AS INT) AND lj.by_jobsite = w.by_jobsite
                   AND lj.type = N'workers_position_level' AND lj.deleted_at IS NULL
                LEFT JOIN hr.enums rm
                    ON rm.id = w.remark AND rm.by_jobsite = w.by_jobsite
                   AND rm.type = N'workers_remark' AND rm.deleted_at IS NULL
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
                  AND (
                        @Lokasi = N''
                     OR (@Lokasi = N'HAULING' AND w.lokasi_kerja IN (
                            N'KM_35', N'KELANIS', N'KM 64', N'KM. 35', N'KM.35', N'HAULING'
                        ))
                     OR (@Lokasi = N'MINING' AND (
                            w.lokasi_kerja IS NULL
                         OR w.lokasi_kerja NOT IN (
                                N'KM_35', N'KELANIS', N'KM 64', N'KM. 35', N'KM.35', N'HAULING'
                            )
                        ))
                     OR (@Lokasi NOT IN (N'HAULING', N'MINING') AND UPPER(w.lokasi_kerja) = @Lokasi)
                  )
                ORDER BY d.name, s.name, w.full_name, w.nrp;
            END
            ELSE
            BEGIN
                SELECT
                    v.nrp,
                    v.full_name,
                    v.jabatan,
                    jr.name AS job_rank,
                    s.name AS section,
                    d.name AS department,
                    v.area_kerja,
                    sk.name AS status_karyawan,
                    st.name AS status,
                    v.lokasi_kerja,
                    CONVERT(char(10), v.tanggal_masuk, 23) AS tanggal_masuk,
                    v.tempat_lahir,
                    CONVERT(char(10), v.tanggal_lahir, 23) AS tanggal_lahir,
                    v.pendidikan,
                    v.agama,
                    v.gender,
                    ISNULL(ms.name, v.status_keluarga) AS status_keluarga,
                    v.alamat,
                    v.id_finger,
                    v.vendor,
                    v.grade
                FROM hr.workers_vendor v
                LEFT JOIN hr.structure d
                    ON d.id = v.department AND d.by_jobsite = v.by_jobsite
                   AND d.type = N'department' AND d.deleted_at IS NULL
                LEFT JOIN hr.structure s
                    ON s.id = v.section AND s.by_jobsite = v.by_jobsite
                   AND s.type = N'section' AND s.deleted_at IS NULL
                LEFT JOIN hr.enums st
                    ON st.id = v.status AND st.by_jobsite = v.by_jobsite
                   AND st.type = N'workers_status' AND st.deleted_at IS NULL
                LEFT JOIN hr.enums sk
                    ON sk.id = v.status_karyawan AND sk.by_jobsite = v.by_jobsite
                   AND sk.type = N'workers_status_karyawan' AND sk.deleted_at IS NULL
                LEFT JOIN hr.enums jr
                    ON jr.id = v.job_rank AND jr.by_jobsite = v.by_jobsite
                   AND jr.type = N'position' AND jr.deleted_at IS NULL
                LEFT JOIN hr.enums ms
                    ON ms.id = TRY_CAST(v.status_keluarga AS INT) AND ms.by_jobsite = v.by_jobsite
                   AND ms.type = N'worker_married_status' AND ms.deleted_at IS NULL
                WHERE v.deleted_at IS NULL
                  AND v.by_jobsite = @Jobsite
                  AND (@DEPARTMENT IS NULL OR v.department = @DEPARTMENT)
                  AND (@SECTION IS NULL OR v.section = @SECTION)
                  AND (@JOB_RANK IS NULL OR v.job_rank = @JOB_RANK)
                  AND (@VendorCode IS NULL OR v.vendor = @VendorCode)
                  AND (
                        @STATUS IS NOT NULL AND v.status = @STATUS
                     OR @STATUS IS NULL AND @Mode = N'all'
                     OR @STATUS IS NULL AND @Mode = N'active'
                         AND v.status IN (235, 236, 237, 238, 242)
                     OR @STATUS IS NULL AND @Mode = N'inactive'
                         AND (v.status IS NULL OR v.status NOT IN (235, 236, 237, 238, 242))
                  )
                  AND (
                        @SearchTerm IS NULL
                     OR v.nrp LIKE @SearchTerm + N'%'
                     OR v.full_name LIKE N'%' + @SearchTerm + N'%'
                     OR v.jabatan LIKE N'%' + @SearchTerm + N'%'
                  )
                  AND (
                        @Lokasi = N''
                     OR (@Lokasi = N'HAULING' AND v.lokasi_kerja IN (
                            N'KM_35', N'KELANIS', N'KM 64', N'KM. 35', N'KM.35', N'HAULING'
                        ))
                     OR (@Lokasi = N'MINING' AND (
                            v.lokasi_kerja IS NULL
                         OR v.lokasi_kerja NOT IN (
                                N'KM_35', N'KELANIS', N'KM 64', N'KM. 35', N'KM.35', N'HAULING'
                            )
                        ))
                     OR (@Lokasi NOT IN (N'HAULING', N'MINING') AND UPPER(v.lokasi_kerja) = @Lokasi)
                  )
                ORDER BY d.name, s.name, v.full_name, v.nrp;
            END
        END
        ELSE IF @ACTION_SP = N'INSERT'
        BEGIN
            IF @Src NOT IN (N'sis', N'vendor')
            BEGIN
                SELECT CAST(0 AS BIT) AS success,
                       N'SOURCE must be sis or vendor.' AS message;
                RETURN;
            END

            IF @NrpClean = N'' OR @NameClean = N''
            BEGIN
                SELECT CAST(0 AS BIT) AS success,
                       N'nrp and full_name are required.' AS message;
                RETURN;
            END

            IF @Src = N'sis'
            BEGIN
                IF EXISTS (
                    SELECT 1 FROM hr.workers
                    WHERE by_jobsite = @Jobsite
                      AND deleted_at IS NULL
                      AND nrp = @NrpClean
                )
                BEGIN
                    SELECT CAST(0 AS BIT) AS success,
                           N'NRP already exists.' AS message;
                    RETURN;
                END
            END
            ELSE
            BEGIN
                IF @VendorClean IS NULL OR @FingerClean IS NULL
                BEGIN
                    SELECT CAST(0 AS BIT) AS success,
                           N'vendor and id_finger are required for LS.' AS message;
                    RETURN;
                END
                IF EXISTS (
                    SELECT 1 FROM hr.workers_vendor
                    WHERE by_jobsite = @Jobsite
                      AND deleted_at IS NULL
                      AND nrp = @NrpClean
                )
                BEGIN
                    SELECT CAST(0 AS BIT) AS success,
                           N'NRP already exists.' AS message;
                    RETURN;
                END
            END

            -- Resolve department (name or id)
            IF NULLIF(LTRIM(RTRIM(@DEPARTMENT_TEXT)), N'') IS NOT NULL
            BEGIN
                SELECT TOP 1 @DeptId = d.id
                FROM hr.structure d
                WHERE d.by_jobsite = @Jobsite
                  AND d.deleted_at IS NULL
                  AND d.type = N'department'
                  AND (
                        d.id = TRY_CAST(@DEPARTMENT_TEXT AS INT)
                     OR UPPER(d.name) = UPPER(LTRIM(RTRIM(@DEPARTMENT_TEXT)))
                     OR UPPER(ISNULL(d.code, N'')) = UPPER(LTRIM(RTRIM(@DEPARTMENT_TEXT)))
                  )
                ORDER BY CASE WHEN d.id = TRY_CAST(@DEPARTMENT_TEXT AS INT) THEN 0 ELSE 1 END;
            END
            ELSE IF @DEPARTMENT IS NOT NULL
                SET @DeptId = @DEPARTMENT;

            IF NULLIF(LTRIM(RTRIM(@SECTION_TEXT)), N'') IS NOT NULL
            BEGIN
                SELECT TOP 1 @SecId = s.id
                FROM hr.structure s
                WHERE s.by_jobsite = @Jobsite
                  AND s.deleted_at IS NULL
                  AND s.type = N'section'
                  AND (
                        s.id = TRY_CAST(@SECTION_TEXT AS INT)
                     OR UPPER(s.name) = UPPER(LTRIM(RTRIM(@SECTION_TEXT)))
                     OR UPPER(ISNULL(s.code, N'')) = UPPER(LTRIM(RTRIM(@SECTION_TEXT)))
                  )
                ORDER BY CASE WHEN s.id = TRY_CAST(@SECTION_TEXT AS INT) THEN 0 ELSE 1 END;
            END
            ELSE IF @SECTION IS NOT NULL
                SET @SecId = @SECTION;

            IF NULLIF(LTRIM(RTRIM(@STATUS_TEXT)), N'') IS NOT NULL
            BEGIN
                SELECT TOP 1 @StatusId = e.id
                FROM hr.enums e
                WHERE e.by_jobsite = @Jobsite
                  AND e.deleted_at IS NULL
                  AND e.type = N'workers_status'
                  AND (
                        e.id = TRY_CAST(@STATUS_TEXT AS INT)
                     OR UPPER(e.name) = UPPER(LTRIM(RTRIM(@STATUS_TEXT)))
                     OR UPPER(ISNULL(e.code, N'')) = UPPER(LTRIM(RTRIM(@STATUS_TEXT)))
                  );
            END
            ELSE IF @STATUS IS NOT NULL
                SET @StatusId = @STATUS;

            IF NULLIF(LTRIM(RTRIM(@JOB_RANK_TEXT)), N'') IS NOT NULL
            BEGIN
                SELECT TOP 1 @JobRankId = e.id
                FROM hr.enums e
                WHERE e.by_jobsite = @Jobsite
                  AND e.deleted_at IS NULL
                  AND e.type = N'position'
                  AND (
                        e.id = TRY_CAST(@JOB_RANK_TEXT AS INT)
                     OR UPPER(e.name) = UPPER(LTRIM(RTRIM(@JOB_RANK_TEXT)))
                     OR UPPER(ISNULL(e.code, N'')) = UPPER(LTRIM(RTRIM(@JOB_RANK_TEXT)))
                  );
            END
            ELSE IF @JOB_RANK IS NOT NULL
                SET @JobRankId = @JOB_RANK;

            IF NULLIF(LTRIM(RTRIM(@STATUS_KARYAWAN_TEXT)), N'') IS NOT NULL
            BEGIN
                SELECT TOP 1 @StatusKarId = e.id
                FROM hr.enums e
                WHERE e.by_jobsite = @Jobsite
                  AND e.deleted_at IS NULL
                  AND e.type = N'workers_status_karyawan'
                  AND (
                        e.id = TRY_CAST(@STATUS_KARYAWAN_TEXT AS INT)
                     OR UPPER(e.name) = UPPER(LTRIM(RTRIM(@STATUS_KARYAWAN_TEXT)))
                     OR UPPER(ISNULL(e.code, N'')) = UPPER(LTRIM(RTRIM(@STATUS_KARYAWAN_TEXT)))
                  );
            END

            IF NULLIF(LTRIM(RTRIM(@LEVEL_JABATAN)), N'') IS NOT NULL
            BEGIN
                SELECT TOP 1 @LevelJabId = e.id
                FROM hr.enums e
                WHERE e.by_jobsite = @Jobsite
                  AND e.deleted_at IS NULL
                  AND e.type = N'workers_position_level'
                  AND (
                        e.id = TRY_CAST(@LEVEL_JABATAN AS INT)
                     OR UPPER(e.name) = UPPER(LTRIM(RTRIM(@LEVEL_JABATAN)))
                     OR UPPER(ISNULL(e.code, N'')) = UPPER(LTRIM(RTRIM(@LEVEL_JABATAN)))
                  );
            END

            IF NULLIF(LTRIM(RTRIM(@KLASIFIKASI_JABATAN)), N'') IS NOT NULL
            BEGIN
                SELECT TOP 1 @KlasId = e.id
                FROM hr.enums e
                WHERE e.by_jobsite = @Jobsite
                  AND e.deleted_at IS NULL
                  AND e.type = N'job_rank_klasifikasi'
                  AND (
                        e.id = TRY_CAST(@KLASIFIKASI_JABATAN AS INT)
                     OR UPPER(e.name) = UPPER(LTRIM(RTRIM(@KLASIFIKASI_JABATAN)))
                     OR UPPER(ISNULL(e.code, N'')) = UPPER(LTRIM(RTRIM(@KLASIFIKASI_JABATAN)))
                  );
            END

            IF NULLIF(LTRIM(RTRIM(@REMARK_TEXT)), N'') IS NOT NULL
            BEGIN
                SELECT TOP 1 @RemarkId = e.id
                FROM hr.enums e
                WHERE e.by_jobsite = @Jobsite
                  AND e.deleted_at IS NULL
                  AND e.type = N'workers_remark'
                  AND (
                        e.id = TRY_CAST(@REMARK_TEXT AS INT)
                     OR UPPER(e.name) = UPPER(LTRIM(RTRIM(@REMARK_TEXT)))
                     OR UPPER(ISNULL(e.code, N'')) = UPPER(LTRIM(RTRIM(@REMARK_TEXT)))
                  );
            END

            IF @Src = N'sis' AND (@DeptId IS NULL OR @SecId IS NULL OR @JobRankId IS NULL)
            BEGIN
                SELECT CAST(0 AS BIT) AS success,
                       N'department, section, and job_rank are required and must match master data.' AS message;
                RETURN;
            END

            SET @NrpInt = TRY_CAST(@NrpClean AS INT);
            IF @NrpInt IS NULL
                SET @NrpInt = 0;

            SET @KeyId = UPPER(CONVERT(VARCHAR(40), HASHBYTES(
                'SHA1',
                CONCAT(@NrpClean, N'_', CONVERT(VARCHAR(19), GETDATE(), 120), N'_', @Src)
            ), 2));

            IF @Src = N'sis'
            BEGIN
                INSERT INTO hr.workers (
                    by_jobsite, key_id, nrp, nrp_int, full_name, jabatan,
                    level_jabatan, klasifikasi_jabatan, job_rank, section, department,
                    grade, area_kerja, status_karyawan, status, lokasi_kerja,
                    staff_nonstaff, poh,
                    tanggal_masuk, tanggal_akhirkontrak, tanggal_efektif_diadaro,
                    tempat_lahir, kabupaten_lahir, provinsi_lahir, tanggal_lahir,
                    pendidikan, nama_sekolah, jurusan, no_ijasah,
                    tanggal_masuk_sekolah, tanggal_lulus_sekolah,
                    agama, suku, golongan_darah, direct_indirect, remark,
                    created_by, updated_at, updated_by
                )
                VALUES (
                    @Jobsite, @KeyId, @NrpClean, @NrpInt, @NameClean,
                    NULLIF(UPPER(LTRIM(RTRIM(@JABATAN))), N''),
                    CASE WHEN @LevelJabId IS NOT NULL THEN CAST(@LevelJabId AS NVARCHAR(255))
                         ELSE NULLIF(UPPER(LTRIM(RTRIM(@LEVEL_JABATAN))), N'') END,
                    @KlasId,
                    @JobRankId,
                    @SecId,
                    @DeptId,
                    NULLIF(UPPER(LTRIM(RTRIM(@GRADE))), N''),
                    NULLIF(UPPER(LTRIM(RTRIM(@AREA_KERJA))), N''),
                    @StatusKarId,
                    @StatusId,
                    NULLIF(UPPER(LTRIM(RTRIM(@LOKASI_KERJA))), N''),
                    NULLIF(UPPER(LTRIM(RTRIM(@STAFF_NONSTAFF))), N''),
                    NULLIF(UPPER(LTRIM(RTRIM(@POH))), N''),
                    @TANGGAL_MASUK,
                    @TANGGAL_AKHIRKONTRAK,
                    @TANGGAL_EFEKTIF_DIADARO,
                    NULLIF(UPPER(LTRIM(RTRIM(@TEMPAT_LAHIR))), N''),
                    NULLIF(UPPER(LTRIM(RTRIM(@KABUPATEN_LAHIR))), N''),
                    NULLIF(UPPER(LTRIM(RTRIM(@PROVINSI_LAHIR))), N''),
                    @TANGGAL_LAHIR,
                    NULLIF(UPPER(LTRIM(RTRIM(@PENDIDIKAN))), N''),
                    NULLIF(UPPER(LTRIM(RTRIM(@NAMA_SEKOLAH))), N''),
                    NULLIF(UPPER(LTRIM(RTRIM(@JURUSAN))), N''),
                    NULLIF(UPPER(LTRIM(RTRIM(@NO_IJASAH))), N''),
                    @TANGGAL_MASUK_SEKOLAH,
                    @TANGGAL_LULUS_SEKOLAH,
                    NULLIF(UPPER(LTRIM(RTRIM(@AGAMA))), N''),
                    NULLIF(UPPER(LTRIM(RTRIM(@SUKU))), N''),
                    NULLIF(UPPER(LTRIM(RTRIM(@GOLONGAN_DARAH))), N''),
                    NULLIF(UPPER(LTRIM(RTRIM(@DIRECT_INDIRECT))), N''),
                    @RemarkId,
                    @BY_USER,
                    SYSUTCDATETIME(),
                    @BY_USER
                );
                SET @NewId = CAST(SCOPE_IDENTITY() AS INT);
            END
            ELSE
            BEGIN
                INSERT INTO hr.workers_vendor (
                    by_jobsite, key_id, nrp, nrp_int, id_finger, full_name, vendor,
                    jabatan, job_rank, section, department,
                    grade, area_kerja, status_karyawan, status, lokasi_kerja,
                    tanggal_masuk, tempat_lahir, tanggal_lahir,
                    pendidikan, agama, gender, status_keluarga, alamat,
                    created_by, updated_at, updated_by
                )
                VALUES (
                    @Jobsite, @KeyId, @NrpClean, @NrpClean, @FingerClean, @NameClean, @VendorClean,
                    NULLIF(UPPER(LTRIM(RTRIM(@JABATAN))), N''),
                    @JobRankId,
                    @SecId,
                    @DeptId,
                    NULLIF(UPPER(LTRIM(RTRIM(@GRADE))), N''),
                    NULLIF(UPPER(LTRIM(RTRIM(@AREA_KERJA))), N''),
                    @StatusKarId,
                    @StatusId,
                    NULLIF(UPPER(LTRIM(RTRIM(@LOKASI_KERJA))), N''),
                    @TANGGAL_MASUK,
                    NULLIF(UPPER(LTRIM(RTRIM(@TEMPAT_LAHIR))), N''),
                    @TANGGAL_LAHIR,
                    NULLIF(UPPER(LTRIM(RTRIM(@PENDIDIKAN))), N''),
                    NULLIF(UPPER(LTRIM(RTRIM(@AGAMA))), N''),
                    NULLIF(UPPER(LTRIM(RTRIM(@GENDER))), N''),
                    NULLIF(UPPER(LTRIM(RTRIM(@STATUS_KELUARGA))), N''),
                    NULLIF(LTRIM(RTRIM(@ALAMAT)), N''),
                    @BY_USER,
                    SYSUTCDATETIME(),
                    @BY_USER
                );
                SET @NewId = CAST(SCOPE_IDENTITY() AS INT);
            END

            SELECT CAST(1 AS BIT) AS success,
                   N'Worker saved successfully.' AS message,
                   @NewId AS id;
        END
        ELSE
        BEGIN
            SELECT CAST(0 AS BIT) AS success,
                   N'Unknown ACTION_SP. Use SELECT, GET, SELECT_EXPORT, or INSERT.' AS message;
        END
    END TRY
    BEGIN CATCH
        SELECT CAST(0 AS BIT) AS success,
               ERROR_MESSAGE() AS message;
    END CATCH
END
GO

-- Grant insert + export on Employees SIS / LS (same levels that already have read)
DECLARE @JobsiteId INT = 1;

UPDATE lp
SET can_insert = 1,
    can_export = 1,
    updated_at = SYSUTCDATETIME()
FROM hr.level_permissions lp
INNER JOIN hr.levels l ON l.id = lp.level_id AND l.deleted_at IS NULL
INNER JOIN hr.menus m ON m.id = lp.menu_id AND m.deleted_at IS NULL
WHERE lp.by_jobsite = @JobsiteId
  AND lp.deleted_at IS NULL
  AND l.code IN (N'superadmin', N'sa', N'management', N'hr_admin', N'hr_administrator')
  AND m.menu_code IN (N'hr_employees_sis', N'hr_employees_ls');
GO
