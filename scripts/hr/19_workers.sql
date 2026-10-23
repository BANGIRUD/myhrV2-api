-- =============================================
-- Table: hr.workers — employee master
-- Source: dbo.workers (legacy MyHR CI)
-- Adapted for multi-site: by_jobsite + hr audit columns.
-- section / department → hr.structure.id; status → hr.enums (type workers_status).
-- Run AFTER 02_jobsites.sql + 17_structure.sql
-- =============================================
IF OBJECT_ID('hr.workers', 'U') IS NULL
BEGIN
    CREATE TABLE hr.workers (
        id INT IDENTITY(1,1) NOT NULL,
        by_jobsite INT NOT NULL,
        key_id NVARCHAR(255) NOT NULL,
        nrp NVARCHAR(255) NOT NULL,
        nrp_int INT NOT NULL,
        full_name NVARCHAR(255) NOT NULL,
        jabatan NVARCHAR(255) NULL,
        level_jabatan NVARCHAR(255) NULL,
        klasifikasi_jabatan INT NULL,
        job_rank INT NOT NULL,
        section INT NOT NULL,
        department INT NOT NULL,
        grade NVARCHAR(255) NULL,
        area_kerja NVARCHAR(255) NULL,
        status_karyawan INT NULL,
        status INT NULL,
        lokasi_kerja NVARCHAR(255) NULL,
        staff_nonstaff NVARCHAR(255) NULL,
        lokal_nonlokal NVARCHAR(255) NULL,
        poh NVARCHAR(255) NULL,
        tanggal_masuk DATE NULL,
        tanggal_akhirkontrak DATE NULL,
        tanggal_akhirkontrak2 DATE NULL,
        tanggal_efektif_diadaro DATE NULL,
        tempat_lahir NVARCHAR(255) NULL,
        kabupaten_lahir NVARCHAR(255) NULL,
        provinsi_lahir NVARCHAR(255) NULL,
        tanggal_lahir DATE NULL,
        pendidikan NVARCHAR(255) NULL,
        nama_sekolah NVARCHAR(255) NULL,
        jurusan NVARCHAR(255) NULL,
        no_ijasah NVARCHAR(255) NULL,
        tanggal_masuk_sekolah DATE NULL,
        tanggal_lulus_sekolah DATE NULL,
        agama NVARCHAR(255) NULL,
        suku NVARCHAR(255) NULL,
        gender NVARCHAR(100) NULL,
        golongan_darah NVARCHAR(255) NULL,
        status_keluarga NVARCHAR(255) NULL,
        status_pajak NVARCHAR(255) NULL,
        alamat NVARCHAR(MAX) NULL,
        kabupaten_alamat NVARCHAR(255) NULL,
        provinsi_alamat NVARCHAR(255) NULL,
        no_wa NVARCHAR(255) NULL,
        no_telp NVARCHAR(255) NULL,
        keterangan_karyawan NVARCHAR(255) NULL,
        tanggal_keluar DATE NULL,
        tanggal_final_pb DATE NULL,
        alasan_keluar NVARCHAR(255) NULL,
        email_sis NVARCHAR(255) NULL,
        email_pribadi NVARCHAR(255) NULL,
        no_bpjs_karyawan NVARCHAR(255) NULL,
        no_kk NVARCHAR(255) NULL,
        tinggal_dengan NVARCHAR(255) NULL,
        alamat_tinggal NVARCHAR(MAX) NULL,
        kabupaten_tinggal NVARCHAR(255) NULL,
        provinsi_tinggal NVARCHAR(255) NULL,
        alamat_tinggal_pasangan NVARCHAR(MAX) NULL,
        kab_tinggal_pasangan NVARCHAR(255) NULL,
        prov_tinggal_pasangan NVARCHAR(255) NULL,
        no_telp_darurat NVARCHAR(255) NULL,
        nama_telp_darurat NVARCHAR(255) NULL,
        alamat_no_telp_darurat NVARCHAR(MAX) NULL,
        hub_keluarga_darurat NVARCHAR(255) NULL,
        nama_telp_darurat2 NVARCHAR(255) NULL,
        no_telp_darurat2 NVARCHAR(255) NULL,
        alamat_no_telp_darurat2 NVARCHAR(MAX) NULL,
        hub_keluarga_darurat2 NVARCHAR(255) NULL,
        ukuran_baju NVARCHAR(255) NULL,
        ukuran_celana NVARCHAR(255) NULL,
        ukuran_sepatu NVARCHAR(255) NULL,
        sim NVARCHAR(255) NULL,
        jenis_penerimaan NVARCHAR(255) NULL,
        alamat_npwp NVARCHAR(MAX) NULL,
        tanggal_npwp DATE NULL,
        jarak_titik_jemput NVARCHAR(255) NULL,
        no_ktp NVARCHAR(255) NULL,
        no_rekening NVARCHAR(255) NULL,
        nama_rekening NVARCHAR(255) NULL,
        bank_rekening NVARCHAR(255) NULL,
        no_jamsostek NVARCHAR(255) NULL,
        no_npwp NVARCHAR(255) NULL,
        no_simponi NVARCHAR(255) NULL,
        direct_indirect NVARCHAR(255) NULL,
        path_foto NVARCHAR(MAX) NULL,
        remark INT NULL,
        code_position NVARCHAR(255) NULL,
        kunci NVARCHAR(900) NULL,
        by_user BIGINT NULL,
        created_at DATETIME2 NOT NULL
            CONSTRAINT DF_hr_workers_created_at DEFAULT (SYSUTCDATETIME()),
        created_by INT NULL,
        updated_at DATETIME2 NULL,
        updated_by INT NULL,
        deleted_at DATETIME2 NULL,
        deleted_by INT NULL,
        legacy_id INT NULL,
        CONSTRAINT PK_hr_workers PRIMARY KEY CLUSTERED (id),
        CONSTRAINT FK_hr_workers_jobsite
            FOREIGN KEY (by_jobsite) REFERENCES hr.jobsites (id)
    );

    CREATE INDEX IX_hr_workers_nrp_jobsite
        ON hr.workers (by_jobsite, nrp);

    CREATE INDEX IX_hr_workers_section_jobsite
        ON hr.workers (by_jobsite, section)
        INCLUDE (status, deleted_at);

    CREATE INDEX IX_hr_workers_department_jobsite
        ON hr.workers (by_jobsite, department)
        INCLUDE (status, deleted_at);

    CREATE UNIQUE INDEX UQ_hr_workers_legacy_id
        ON hr.workers (legacy_id)
        WHERE legacy_id IS NOT NULL;
END
GO
