# Pola modul Sakit

Acuan untuk modul HR berikutnya (cuti, izin, dan sejenisnya). Tiru **bentuk** modul ini. Aturan bisnis tiap modul tetap sendiri: siapa yang menyetujui, field apa yang disimpan, dan kapan sebuah baris boleh diubah.

Sakit adalah modul berjenjang. Satu pengajuan masuk, lalu bergerak melewati atasan sampai Personalia. Modul lain boleh punya lebih sedikit jenjang, atau tidak punya jenjang sama sekali.

## Yang ditiru

1. **Satu tabel induk, satu stored procedure.** Semua aksi lewat `@ACTION_SP` (`SELECT`, `GET`, `INSERT`, `UPDATE`, plus aksi khusus antrean). Controller tetap tipis: `executeHrSp`, `BY_USER`, `BY_JOBSITE`.
2. **URL mengikuti folder sidebar.** Bukan semuanya di `/master`.
3. **Satu halaman tabel, banyak antrean.** `MasterTablePage` + komponen tabel yang sama. Bedanya hanya `pathname`: siapa yang login, tombol apa yang muncul, dan filter apa yang dikirim.
4. **Izin tetap satu model.** `hr.menus.menu_code` + `hr.level_permissions`. Jangan buat RBAC kedua. Superadmin / `sa` melewati matriks menu.
5. **Cakupan data terpisah dari izin menu.** Menu mengatur boleh buka halaman. `worker_scope`, section, dan level mengatur baris mana yang terlihat.
6. **Lonceng menyusul aksi, bukan polling.** WebSocket saat user sedang online, ditambah inbox untuk yang baru masuk.
7. **Export = daftar yang sedang dilihat.** Filter aktif ikut terkirim. Hasilnya dua lembar: ringkasan jumlah, lalu detail.

## Yang khas Sakit (jangan disalin mentah)

- Jenjangnya: pemohon → atasan (Section Head, atau Group Leader untuk LS, atau Department Head) → Personalia HR.
- Status akhir HR memakai baris anak (`ref_id` = id induk). Penolakan HR tidak menghapus nama atasan yang sudah menyetujui.
- Label jabatan di status masih memakai angka legacy (`job_rank`). Singkatan di kolom persetujuan (SH / GL / UH / DH) diambil dari nama jabatan atasan.
- SIS = `worker_source` bukan `vendor`. LS = `vendor`.
- Script aktif terakhir untuk SP adalah `68_sakit_hr_approval.sql`. Jangan menjalankan ulang script sakit yang lebih lama sesudahnya.

## Peta peran

| Peran | Menu | URL | Melihat | Aksi |
| --- | --- | --- | --- | --- |
| Input / rekonsiliasi | `hr_sakit` | `/reconciliation/sakit` | Pengajuan pada cakupan section user | Tambah, ubah, batal selama masih menunggu atasan dan masih di jendela `hr.edit_policy` |
| Section Head (atau Unit Head bila tidak ada Section Head) | `hr_sakit_section` | `/section/sakit` | Antrean section-nya | Setujui / tolak |
| Group Leader (LS) | `hr_sakit_group` | `/group/sakit` | Antrean LS di group-nya | Setujui / tolak |
| Department Head | `hr_sakit_department` | `/department/sakit` | Jabatan tinggi, plus pengecualian section | Setujui / tolak |
| HR Admin SIS | `hr_sakit_hr` | `/personalia/sakit` | Semua status bulan itu, karyawan SIS saja | Setujui / tolak hanya yang `Waiting approve by HR` |
| HR Admin LS | `hr_sakit_hr` | `/personalia/sakit` | Semua status bulan itu, karyawan LS saja | Sama, hanya LS |
| HR Administrator (`worker_scope = all`) dan superadmin | `hr_sakit_hr` | `/personalia/sakit` | SIS dan LS | Boleh menyaring tipe karyawan. Superadmin tidak menerima lonceng setiap pengajuan |

Filter **Tipe Karyawan** hanya untuk akun yang sudah boleh melihat kedua kelompok. Akun yang terkunci SIS atau LS tidak melihat filter itu, dan API mengabaikan `status_worker` dari akun tersebut.

## Alur status

Induk (`ref_id` kosong, biasanya `verify = user`) adalah pengajuan. Anak terakhir menimpa status yang tampil.

1. Baru dibuat: menunggu atasan. Lonceng ke atasan section / group / department yang berhak.
2. Atasan setuju: anak `verify = section`, induk `approve = true`, `by_verified` = atasan. Status menjadi `Waiting approve by HR`. Lonceng ke HR yang kelompoknya cocok (LS ke `ls`+`all`, SIS ke `sis`+`all`).
3. Atasan tolak: induk saja yang ditolak. Tidak ada anak HR.
4. HR setuju: anak `verify = administrator`. Status `Approve by HR`.
5. HR tolak: anak section diubah `reject = true`, `by_user` anak ditimpa id HR. Nama atasan tetap dibaca dari `by_verified` induk. Status `Rejected by HR`.

**Rekonsiliasi (sementara):** bila yang input adalah `superadmin` / `sa` / `hr_administrator`, setelah `INSERT` langsung dipromosikan ke `Approve by HR` lewat `hr.RECON_AUTO_APPROVE_SP` (script `84`). Bentuknya tetap 3 baris (induk + section + administrator); semua `by_user` / `by_verified` diisi pemohon. Tidak ada lonceng atasan/HR. Berlaku juga untuk ijin dan fingerprint.

Urutan daftar Personalia: yang menunggu HR di atas, lalu `created_at`, lalu `id`.

## Tampilan yang dipakai bersama

- Kolom persetujuan: baris atasan (peran · nama · waktu), lalu baris HR.
- `Rejected by HR` tidak menampilkan `HR · —`. Baris HR memakai nama penolak. Catatan tolak di kolom sebelahnya hanya isi catatan, tanpa mengulang nama HR.
- Penolakan atasan tetap menulis nama dan waktu di kolom catatan, karena kolom HR tidak menyimpan penolak itu.
- Baris ditolak memakai isi merah muda lembut, untuk semua jenis penolakan.
- Detail memakai modal yang sama. Diinput, atasan, dan HR masing-masing punya nama dan waktu.

## File yang menjadi cetakan

| Lapisan | Sakit | Untuk modul baru |
| --- | --- | --- |
| Database | `scripts/hr/52`–`69_sakit_*.sql`, live SP `hr.SICKNESS_SP`, inbox `hr.SICKNESS_INBOX_SP` (script 75) | `NN_<modul>.sql` + menu + `level_permissions` |
| API | `controllers/hrMaster.js`, `routes/hrMaster.js` | Aksi list / putuskan / export di controller yang sama atau controller baru |
| Export | `services/sakitExport.js`, `GET /api/hr/sakit/hr/export` | Lembar Ringkasan + Detail, filter sama dengan layar |
| Lonceng | `services/sakitNotify.js`, `services/notifyHub.js`, `GET /api/notifications` | Tambah baris modul di inbox yang sudah ada, jangan buat soket kedua |
| UI | `MasterTablePage.tsx`, `SakitTable.tsx`, `SakitSectionDetailModal.tsx`, `services/hrMaster.ts`, `App.tsx`, `navMenus.ts` | Satu tabel, mode antrean dari pathname, fallback sidebar selaras dengan `menu_url` |

## Tanggal tidak boleh bertumpuk antar pengajuan

Sakit dan ijin memakai satu daftar, `hr.v_active_submissions` (script `76_active_submissions.sql`). Induk yang belum dihapus masuk daftar itu. Saat simpan atau ubah, tanggal yang saling potong dengan baris modul lain ditolak. Form tambah menampilkan 5 pengajuan terbaru; bila masih ada yang lain, tulis `contact administrator for more info`. Daftar lengkap ada di Master Data → Submissions (`/master/submissions`) untuk `hr_administrator` dan superadmin. Kunci simpan bersamaan memakai nama `absence:{jobsite}:{nrp}`, satu antrean untuk semua modul pengajuan.

Modul pengajuan berikutnya wajib:

1. Menambah satu `UNION ALL` di view itu, dengan `module_code` baru, lalu menjalankan ulang script 76.
2. Menolak overlap lewat view yang sama (`module_code` bukan modul ini) pada `INSERT` dan `UPDATE`.
3. Memakai kunci `absence:{jobsite}:{nrp}` sebelum cek itu.
4. Mengembalikan baris modul lain pada `LOOKUP`, supaya form menampilkan peringatan yang sama.

## Urutan kerja modul berikutnya

1. Tentukan jenjang dan siapa yang melihat baris mana. Tuliskan perbedaannya terhadap tabel peran di atas.
2. Tabel `hr` + SP dengan `@ACTION_SP`. Satu script menu menyalakan folder induk dan mengisi `can_read` / `can_approve` hanya untuk level yang bertugas.
3. Endpoint di `/api/hr/<modul>/...`. Antrean khusus didaftarkan sebelum route `/:id`.
4. Halaman memakai tabel yang sudah ada bila kolomnya dekat. Route React didaftarkan sebelum menu diaktifkan.
5. Lonceng: penerima dihitung di SP inbox, dikirim setelah aksi berhasil.
6. Export menyusul bila laporannya dibutuhkan, dengan filter yang sama dengan daftar.
