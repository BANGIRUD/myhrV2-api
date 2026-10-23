-- =============================================
-- Seed / sync: dbo.workers → hr.workers
-- Default site: hr.jobsites id = 1 (DEFAULT)
-- Preserves source ids (IDENTITY_INSERT) so structure/enums FKs stay valid.
-- Safe to re-run while the legacy app still writes to dbo.workers:
--   1) updates hr rows whose source data differs (updated_at alone is not
--      reliable; legacy app edits fields without bumping it)
--   2) inserts source rows missing in hr
-- Run AFTER 19_workers.sql
-- =============================================
SET NOCOUNT ON;

DECLARE @JobsiteId INT = 1;

IF NOT EXISTS (SELECT 1 FROM hr.jobsites WHERE id = @JobsiteId AND deleted_at IS NULL)
BEGIN
    THROW 50030, 'hr.jobsites id=1 (DEFAULT) missing. Run 02_jobsites.sql first.', 1;
END;

IF OBJECT_ID('hr.workers', 'U') IS NULL
BEGIN
    THROW 50031, 'hr.workers missing. Run 19_workers.sql first.', 1;
END;

-- ---- update changed rows ----
UPDATE dst
SET
    key_id = src.key_id,
    nrp = src.nrp,
    nrp_int = src.nrp_int,
    full_name = src.full_name,
    jabatan = src.jabatan,
    level_jabatan = src.level_jabatan,
    klasifikasi_jabatan = src.klasifikasi_jabatan,
    job_rank = src.job_rank,
    section = src.section,
    department = src.department,
    grade = src.grade,
    area_kerja = src.area_kerja,
    status_karyawan = src.status_karyawan,
    status = src.status,
    lokasi_kerja = src.lokasi_kerja,
    staff_nonstaff = src.staff_nonstaff,
    lokal_nonlokal = src.lokal_nonlokal,
    poh = src.poh,
    tanggal_masuk = src.tanggal_masuk,
    tanggal_akhirkontrak = src.tanggal_akhirkontrak,
    tanggal_akhirkontrak2 = src.tanggal_akhirkontrak2,
    tanggal_efektif_diadaro = src.tanggal_efektif_diadaro,
    tempat_lahir = src.tempat_lahir,
    kabupaten_lahir = src.kabupaten_lahir,
    provinsi_lahir = src.provinsi_lahir,
    tanggal_lahir = src.tanggal_lahir,
    pendidikan = src.pendidikan,
    nama_sekolah = src.nama_sekolah,
    jurusan = src.jurusan,
    no_ijasah = src.no_ijasah,
    tanggal_masuk_sekolah = src.tanggal_masuk_sekolah,
    tanggal_lulus_sekolah = src.tanggal_lulus_sekolah,
    agama = src.agama,
    suku = src.suku,
    gender = src.gender,
    golongan_darah = src.golongan_darah,
    status_keluarga = src.status_keluarga,
    status_pajak = src.status_pajak,
    alamat = src.alamat,
    kabupaten_alamat = src.kabupaten_alamat,
    provinsi_alamat = src.provinsi_alamat,
    no_wa = src.no_wa,
    no_telp = src.no_telp,
    keterangan_karyawan = src.keterangan_karyawan,
    tanggal_keluar = src.tanggal_keluar,
    tanggal_final_pb = src.tanggal_final_pb,
    alasan_keluar = src.alasan_keluar,
    email_sis = src.email_sis,
    email_pribadi = src.email_pribadi,
    no_bpjs_karyawan = src.no_bpjs_karyawan,
    no_kk = src.no_kk,
    tinggal_dengan = src.tinggal_dengan,
    alamat_tinggal = src.alamat_tinggal,
    kabupaten_tinggal = src.kabupaten_tinggal,
    provinsi_tinggal = src.provinsi_tinggal,
    alamat_tinggal_pasangan = src.alamat_tinggal_pasangan,
    kab_tinggal_pasangan = src.kab_tinggal_pasangan,
    prov_tinggal_pasangan = src.prov_tinggal_pasangan,
    no_telp_darurat = src.no_telp_darurat,
    nama_telp_darurat = src.nama_telp_darurat,
    alamat_no_telp_darurat = src.alamat_no_telp_darurat,
    hub_keluarga_darurat = src.hub_keluarga_darurat,
    nama_telp_darurat2 = src.nama_telp_darurat2,
    no_telp_darurat2 = src.no_telp_darurat2,
    alamat_no_telp_darurat2 = src.alamat_no_telp_darurat2,
    hub_keluarga_darurat2 = src.hub_keluarga_darurat2,
    ukuran_baju = src.ukuran_baju,
    ukuran_celana = src.ukuran_celana,
    ukuran_sepatu = src.ukuran_sepatu,
    sim = src.sim,
    jenis_penerimaan = src.jenis_penerimaan,
    alamat_npwp = src.alamat_npwp,
    tanggal_npwp = src.tanggal_npwp,
    jarak_titik_jemput = src.jarak_titik_jemput,
    no_ktp = src.no_ktp,
    no_rekening = src.no_rekening,
    nama_rekening = src.nama_rekening,
    bank_rekening = src.bank_rekening,
    no_jamsostek = src.no_jamsostek,
    no_npwp = src.no_npwp,
    no_simponi = src.no_simponi,
    direct_indirect = src.direct_indirect,
    path_foto = src.path_foto,
    remark = src.remark,
    code_position = src.code_position,
    kunci = src.kunci,
    by_user = src.by_user,
    updated_at = src.updated_at,
    updated_by = TRY_CAST(src.by_user AS INT),
    deleted_at = src.deleted_at
FROM hr.workers AS dst
INNER JOIN dbo.workers AS src
    ON src.id = dst.id
WHERE dst.by_jobsite = @JobsiteId
  AND EXISTS (
    SELECT
        src.key_id, src.nrp, src.nrp_int, src.full_name, src.jabatan, src.level_jabatan,
        src.klasifikasi_jabatan, src.job_rank, src.section, src.department, src.grade, src.area_kerja,
        src.status_karyawan, src.status, src.lokasi_kerja, src.staff_nonstaff, src.lokal_nonlokal, src.poh,
        src.tanggal_masuk, src.tanggal_akhirkontrak, src.tanggal_akhirkontrak2, src.tanggal_efektif_diadaro,
        src.tempat_lahir, src.kabupaten_lahir, src.provinsi_lahir, src.tanggal_lahir,
        src.pendidikan, src.nama_sekolah, src.jurusan, src.no_ijasah, src.tanggal_masuk_sekolah, src.tanggal_lulus_sekolah,
        src.agama, src.suku, src.gender, src.golongan_darah, src.status_keluarga, src.status_pajak,
        src.alamat, src.kabupaten_alamat, src.provinsi_alamat, src.no_wa, src.no_telp, src.keterangan_karyawan,
        src.tanggal_keluar, src.tanggal_final_pb, src.alasan_keluar, src.email_sis, src.email_pribadi,
        src.no_bpjs_karyawan, src.no_kk, src.tinggal_dengan, src.alamat_tinggal, src.kabupaten_tinggal, src.provinsi_tinggal,
        src.alamat_tinggal_pasangan, src.kab_tinggal_pasangan, src.prov_tinggal_pasangan,
        src.no_telp_darurat, src.nama_telp_darurat, src.alamat_no_telp_darurat, src.hub_keluarga_darurat,
        src.nama_telp_darurat2, src.no_telp_darurat2, src.alamat_no_telp_darurat2, src.hub_keluarga_darurat2,
        src.ukuran_baju, src.ukuran_celana, src.ukuran_sepatu, src.sim, src.jenis_penerimaan,
        src.alamat_npwp, src.tanggal_npwp, src.jarak_titik_jemput, src.no_ktp,
        src.no_rekening, src.nama_rekening, src.bank_rekening, src.no_jamsostek, src.no_npwp, src.no_simponi,
        src.direct_indirect, src.path_foto, src.remark, src.code_position, src.kunci,
        src.by_user, src.updated_at, src.deleted_at
    EXCEPT
    SELECT
        dst.key_id, dst.nrp, dst.nrp_int, dst.full_name, dst.jabatan, dst.level_jabatan,
        dst.klasifikasi_jabatan, dst.job_rank, dst.section, dst.department, dst.grade, dst.area_kerja,
        dst.status_karyawan, dst.status, dst.lokasi_kerja, dst.staff_nonstaff, dst.lokal_nonlokal, dst.poh,
        dst.tanggal_masuk, dst.tanggal_akhirkontrak, dst.tanggal_akhirkontrak2, dst.tanggal_efektif_diadaro,
        dst.tempat_lahir, dst.kabupaten_lahir, dst.provinsi_lahir, dst.tanggal_lahir,
        dst.pendidikan, dst.nama_sekolah, dst.jurusan, dst.no_ijasah, dst.tanggal_masuk_sekolah, dst.tanggal_lulus_sekolah,
        dst.agama, dst.suku, dst.gender, dst.golongan_darah, dst.status_keluarga, dst.status_pajak,
        dst.alamat, dst.kabupaten_alamat, dst.provinsi_alamat, dst.no_wa, dst.no_telp, dst.keterangan_karyawan,
        dst.tanggal_keluar, dst.tanggal_final_pb, dst.alasan_keluar, dst.email_sis, dst.email_pribadi,
        dst.no_bpjs_karyawan, dst.no_kk, dst.tinggal_dengan, dst.alamat_tinggal, dst.kabupaten_tinggal, dst.provinsi_tinggal,
        dst.alamat_tinggal_pasangan, dst.kab_tinggal_pasangan, dst.prov_tinggal_pasangan,
        dst.no_telp_darurat, dst.nama_telp_darurat, dst.alamat_no_telp_darurat, dst.hub_keluarga_darurat,
        dst.nama_telp_darurat2, dst.no_telp_darurat2, dst.alamat_no_telp_darurat2, dst.hub_keluarga_darurat2,
        dst.ukuran_baju, dst.ukuran_celana, dst.ukuran_sepatu, dst.sim, dst.jenis_penerimaan,
        dst.alamat_npwp, dst.tanggal_npwp, dst.jarak_titik_jemput, dst.no_ktp,
        dst.no_rekening, dst.nama_rekening, dst.bank_rekening, dst.no_jamsostek, dst.no_npwp, dst.no_simponi,
        dst.direct_indirect, dst.path_foto, dst.remark, dst.code_position, dst.kunci,
        dst.by_user, dst.updated_at, dst.deleted_at
  );

PRINT CONCAT('hr.workers updated for jobsite ', @JobsiteId, ': ', @@ROWCOUNT);

-- ---- insert missing rows ----
SET IDENTITY_INSERT hr.workers ON;

INSERT INTO hr.workers (
    id, by_jobsite, key_id, nrp, nrp_int, full_name, jabatan, level_jabatan,
    klasifikasi_jabatan, job_rank, section, department, grade, area_kerja,
    status_karyawan, status, lokasi_kerja, staff_nonstaff, lokal_nonlokal, poh,
    tanggal_masuk, tanggal_akhirkontrak, tanggal_akhirkontrak2, tanggal_efektif_diadaro,
    tempat_lahir, kabupaten_lahir, provinsi_lahir, tanggal_lahir,
    pendidikan, nama_sekolah, jurusan, no_ijasah, tanggal_masuk_sekolah, tanggal_lulus_sekolah,
    agama, suku, gender, golongan_darah, status_keluarga, status_pajak,
    alamat, kabupaten_alamat, provinsi_alamat, no_wa, no_telp, keterangan_karyawan,
    tanggal_keluar, tanggal_final_pb, alasan_keluar, email_sis, email_pribadi,
    no_bpjs_karyawan, no_kk, tinggal_dengan, alamat_tinggal, kabupaten_tinggal, provinsi_tinggal,
    alamat_tinggal_pasangan, kab_tinggal_pasangan, prov_tinggal_pasangan,
    no_telp_darurat, nama_telp_darurat, alamat_no_telp_darurat, hub_keluarga_darurat,
    nama_telp_darurat2, no_telp_darurat2, alamat_no_telp_darurat2, hub_keluarga_darurat2,
    ukuran_baju, ukuran_celana, ukuran_sepatu, sim, jenis_penerimaan,
    alamat_npwp, tanggal_npwp, jarak_titik_jemput, no_ktp,
    no_rekening, nama_rekening, bank_rekening, no_jamsostek, no_npwp, no_simponi,
    direct_indirect, path_foto, remark, code_position, kunci,
    by_user, created_at, created_by, updated_at, updated_by, deleted_at, deleted_by, legacy_id
)
SELECT
    src.id, @JobsiteId, src.key_id, src.nrp, src.nrp_int, src.full_name, src.jabatan, src.level_jabatan,
    src.klasifikasi_jabatan, src.job_rank, src.section, src.department, src.grade, src.area_kerja,
    src.status_karyawan, src.status, src.lokasi_kerja, src.staff_nonstaff, src.lokal_nonlokal, src.poh,
    src.tanggal_masuk, src.tanggal_akhirkontrak, src.tanggal_akhirkontrak2, src.tanggal_efektif_diadaro,
    src.tempat_lahir, src.kabupaten_lahir, src.provinsi_lahir, src.tanggal_lahir,
    src.pendidikan, src.nama_sekolah, src.jurusan, src.no_ijasah, src.tanggal_masuk_sekolah, src.tanggal_lulus_sekolah,
    src.agama, src.suku, src.gender, src.golongan_darah, src.status_keluarga, src.status_pajak,
    src.alamat, src.kabupaten_alamat, src.provinsi_alamat, src.no_wa, src.no_telp, src.keterangan_karyawan,
    src.tanggal_keluar, src.tanggal_final_pb, src.alasan_keluar, src.email_sis, src.email_pribadi,
    src.no_bpjs_karyawan, src.no_kk, src.tinggal_dengan, src.alamat_tinggal, src.kabupaten_tinggal, src.provinsi_tinggal,
    src.alamat_tinggal_pasangan, src.kab_tinggal_pasangan, src.prov_tinggal_pasangan,
    src.no_telp_darurat, src.nama_telp_darurat, src.alamat_no_telp_darurat, src.hub_keluarga_darurat,
    src.nama_telp_darurat2, src.no_telp_darurat2, src.alamat_no_telp_darurat2, src.hub_keluarga_darurat2,
    src.ukuran_baju, src.ukuran_celana, src.ukuran_sepatu, src.sim, src.jenis_penerimaan,
    src.alamat_npwp, src.tanggal_npwp, src.jarak_titik_jemput, src.no_ktp,
    src.no_rekening, src.nama_rekening, src.bank_rekening, src.no_jamsostek, src.no_npwp, src.no_simponi,
    src.direct_indirect, src.path_foto, src.remark, src.code_position, src.kunci,
    src.by_user, src.created_at, TRY_CAST(src.by_user AS INT),
    src.updated_at, NULL, src.deleted_at, NULL, src.id
FROM dbo.workers AS src
WHERE NOT EXISTS (
    SELECT 1
    FROM hr.workers AS dst
    WHERE dst.id = src.id
);

PRINT CONCAT('hr.workers inserted for jobsite ', @JobsiteId, ': ', @@ROWCOUNT);

SET IDENTITY_INSERT hr.workers OFF;
GO
