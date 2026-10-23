# ID cutover: dbo → hr

Aturan wajib setiap kali tabel operasional di-migrate dari schema lama (`dbo`) ke `hr`. Tujuannya: **`hr.id = dbo.id`** supaya `ref_id`, FK lintas tabel, dan view tetap valid saat tabel lain menyusul.

Ringkas di [`AGENTS.md`](../AGENTS.md) (bagian *ID cutover policy*). Dokumen ini = checklist kerja.

---

## Aturan utama

1. **Preserve integer PK.** Insert dengan `SET IDENTITY_INSERT hr.<table> ON` dan `id = dbo.id`.
2. **`legacy_id = dbo.id`** pada setiap row hasil sync (mirror; setelah cutover `id = legacy_id`).
3. **Jangan regenerate id** lalu remap lewat `legacy_id` saja — itu pola `users` yang sudah diperbaiki. Kecuali katalog yang memang bukan mirror (lihat pengecualian).
4. **Copy `ref_id` / FK int apa adanya** (parent id di ruang id yang sama). Jangan translate lewat map kecuali tabel parent sengaja di-remap (menus).
5. **Row baru dari app** (INSERT SP tanpa `IDENTITY_INSERT`) boleh pakai IDENTITY baru — itu bukan row dbo.
6. **Verify lokal** setelah sync: `node scripts/hr/seed_verify_id_alignment.js` (perluas daftar tabel di script bila menambah mirror baru).

---

## Checklist saat menambah / migrate tabel baru

### DDL (`scripts/hr/NN_*.sql`)

- [ ] Kolom `id INT IDENTITY(1,1)` + `legacy_id INT NULL` (+ unique filtered index pada `legacy_id` bila berguna).
- [ ] `by_jobsite`, audit (`created_by` / `updated_by` / `deleted_by` sebagai `hr.users.id`), soft-delete.
- [ ] Index pada `ref_id` / FK bisnis bila ada parent–child.

### Sync / seed

- [ ] Sync SQL atau seed JS: **update by `id`**, **insert with `IDENTITY_INSERT`**, `legacy_id = src.id`.
- [ ] Pola acuan: [`18_seed_enums_structure_from_dbo.sql`](../scripts/hr/18_seed_enums_structure_from_dbo.sql), [`32_sync_workers_roster_kerja_from_dbo.sql`](../scripts/hr/32_sync_workers_roster_kerja_from_dbo.sql), generic `syncHrTable` di [`seed_attendance_from_azure.js`](../scripts/hr/seed_attendance_from_azure.js).
- [ ] **Jangan** insert tanpa `id` (auto-identity) untuk row dari dbo — bentrok id nanti merusak `ref_id`.
- [ ] Windowed sync (roster, finger, dll.): dokumentasikan window; `dbo_missing` di luar window = expected.

### SP / API

- [ ] List/join yang bergantung id parent–child pakai `id` / `ref_id` langsung (bukan `legacy_id`), kecuali kolom yang masih menyimpan **user id space dbo** (`by_user`, `by_verified*`) — join `hr.users.legacy_id` sampai cutover penuh.
- [ ] INSERT app: generate `key_id` bila kolom itu dipakai di legacy (pola Sakit/Ijin: SHA1 uppercase).

### Verifikasi

- [ ] Tambah nama tabel ke `ID_TABLES` (dan `REF_PAIRS` bila ada `ref_id`) di [`seed_verify_id_alignment.js`](../scripts/hr/seed_verify_id_alignment.js).
- [ ] Jalankan verify; mismatch `id <> legacy_id` = gagal.
- [ ] Sample: `SELECT TOP 5 d.id, h.id, d.ref_id, h.ref_id FROM dbo.X d INNER JOIN hr.X h ON h.id = d.id`.

### Jika lokal sudah drift (`id ≠ legacy_id`)

- [ ] Prefer re-seed dengan IDENTITY_INSERT (hapus row mirror jobsite / window, sync ulang).
- [ ] Khusus `hr.users`: `node scripts/hr/seed_realign_users_ids.js` (bulk map + remap audit `*_by`).
- [ ] Jangan diam-diam insert id baru di seed (no silent remap).

---

## Sudah mirror (preserve id)

| Area | Tabel hr |
|------|----------|
| Auth / master | `users`, `structure`, `enums`, `workers`, `workers_vendor` |
| Sakit / ijin / fingerprint | `workers_sickness`, `workers_sickness_photos`, `workers_permit`, `workers_permit_photos`, `workers_finger_error`, `workers_finger_error_photos` |
| Pola / roster | `workers_pola_kerja`, `workers_roster_kerja` |
| Attendance | `workers_standby`, `attendance_ratio`, `workers_travel`, `workers_cuti_*`, `workers_finger_log`, `workers_finger_oams`, `date_holiday` |

Note: `workers_finger_error` is a **full operational mirror** (Fingerprint module: CRUD + Section/HR approval), not attendance-stub-only. Seed via `seed_attendance_from_azure.js workers_finger_error` (IDENTITY_INSERT, `legacy_id = id`). Photos sync is optional/manual when Azure rows are needed locally.

## Pengecualian (jangan paksa id = dbo)

| Tabel | Alasan |
|-------|--------|
| `hr.menus` | Katalog produk; `menu_code` = identity; parent via `legacy_id` / `legacy_ref_id` |
| `hr.levels`, `hr.level_permissions`, `hr.edit_policy*` | Model HR baru, bukan 1:1 dbo int |
| `hr.menu_privilege` | PK string = kode privilege legacy |

---

## Urutan migrate yang aman

1. **Fondasi id space:** `structure`, `enums`, `users`, lalu `workers` (FK ke structure/enums).
2. **Transaksi yang punya `ref_id`:** sickness/permit (+ photos), cuti period/master, dll.
3. **Time-series / windowed:** roster, pola, finger, travel, standby, attendance_ratio.
4. **Katalog UI:** menus / permissions (boleh remap).

Setiap gelombang: sync → verify → baru lanjut tabel yang mereferensi id tabel itu.
