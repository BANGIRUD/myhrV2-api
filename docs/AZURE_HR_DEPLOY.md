# Azure production: skema `hr` + cutover app

Runbook untuk menambah skema **`hr`** di database MyHR Azure (sejajar **`dbo`**), menyalin data mirror dengan **`hr.id = dbo.id`**, lalu mengarahkan app MyHR baru ke `hr.*`.

Keputusan terkunci:

| Topik | Aturan |
|-------|--------|
| Runtime app | Tulis hanya `hr.*` (`DB_*` production → Azure) |
| Legacy CI (`myhrs`) | Tetap tulis `dbo` sampai modul di-cutover |
| Patokan id / migrasi tabel baru | **`dbo`** — selalu `hr.id = dbo.id` |
| `legacy_id` | **Tetap** seperti lokal (jangan di-drop). Mirror: `legacy_id = id`. App INSERT: biasanya NULL |
| Seed pull lokal | `AZURE_DB_*` + `config/azureReadonly.js` tetap **SELECT-only** |
| DDL / sync prod | `PROD_DB_*` + `CONFIRM_PROD_MIGRATE=YES` + allowlist |

Lihat juga [`ID_CUTOVER.md`](./ID_CUTOVER.md).

---

## Prasyarat

1. Service account SQL untuk migrate/sync: boleh DDL + DML di skema `hr`; **jangan** beri DML/DDL di `dbo` untuk akun app runtime (akun migrate boleh baca `dbo` untuk sync).
2. Isi `.env` (jangan commit secret):

```env
PROD_DB_SERVER=sqlmisis-prod.….database.windows.net
PROD_DB_PORT=1433
PROD_DB_NAME=MYHR
PROD_DB_USER=
PROD_DB_PASSWORD=
PROD_DB_SERVER_ALLOWLIST=sqlmisis-prod.….database.windows.net
CONFIRM_PROD_MIGRATE=YES
```

3. Dev harian tetap pakai `DB_*` lokal. Jangan longgarkan `AZURE_DB_ALLOW_WRITE`.

---

## Fase A — DDL skema `hr`

```bash
# Dry safety: pastikan CONFIRM + allowlist sudah di-set
node scripts/hr/run_migrate_prod.js 01
```

### Urutan gelombang (disarankan)

Jalankan per gelombang agar gagal di tengah mudah diulang (script idempotent).

**1 — Fondasi (DDL dulu; views login setelah structure)**

```bash
# Tables + levels + menus (skip 05/12 — butuh hr.levels / hr.structure)
node scripts/hr/run_migrate_prod.js 01 02 03 04 07 08 09 10 11 13
```

`13` juga memastikan `hr_reconciliation` (remap dbo Reconciliation / insert folder) agar menu pola/roster/SIA jalan.

**2 — Users SP + enums/structure/workers + login views**

```bash
node scripts/hr/run_migrate_prod.js 14 15 16 17 19 21 23 25 26 27
node scripts/hr/run_migrate_prod.js 05 12 24
```

**3 — Dashboard / attendance / pola / roster DDL + SP**

```bash
node scripts/hr/run_migrate_prod.js 28 29 31 33 35 36 37 39 40 41 42 43 44 45 46 47 48 49 50 51
```

**4 — Sakit / ijin / finger / activity / English rename**

```bash
node scripts/hr/run_migrate_prod.js 52 53 54 55 56 57 58 59 60 61 62 63 64 65 66 67 68 69 70 71 72 73 74 75 76 77 78 79 80 81 82 83 84 85 86 87
```

Atau satu kali penuh (setelah fondasi sudah aman):

```bash
node scripts/hr/run_migrate_prod.js
```

---

## Fase B — Sync `dbo` → `hr` (same database)

```bash
# Master id space dulu
node scripts/hr/sync_dbo_to_hr_prod.js foundation

# Operasional + windowed (month-2 …)
node scripts/hr/sync_dbo_to_hr_prod.js operational

# Atau semua
node scripts/hr/sync_dbo_to_hr_prod.js

# Satu tabel
node scripts/hr/sync_dbo_to_hr_prod.js workers_sickness
```

Kontrak sync:

- `SET IDENTITY_INSERT` → `hr.id = dbo.id`
- `legacy_id = dbo.id` pada row hasil sync
- Tabel windowed: batas sama lokal (`seed_attendance_from_azure.js`) — jangan full history tanpa cek storage
- Row app-only di `hr` (`legacy_id` NULL) tidak dihapus keras; soft-delete hanya untuk mirror yang hilang dari `dbo` di dalam window

---

## Fase C — Verify + smoke

```bash
node scripts/hr/verify_id_alignment_prod.js
# setara: node scripts/hr/seed_verify_id_alignment.js --prod
```

Wajib lulus:

- `hr.users`: `id = legacy_id` (row yang punya `legacy_id`)
- Mirror operasional: tidak ada `legacy_id ≠ id` pada overlap dbo
- Smoke: `hr.v_user_login` punya baris; sample join `workers_sickness.by_user` → `hr.users.legacy_id`

---

## Fase D — App cutover runtime

### Soft-launch dari workstation (sudah dijalankan)

1. Backend `.env` (gitignored):
   - `DB_*` → Azure (sama host `PROD_DB_*`), `HR_SCHEMA=hr`
   - `AUTH_DEV_BYPASS=false`, `BYPASS_PASSWORD` unset
   - `NODE_ENV=development` OK untuk proses lokal; host publik pakai `production` + `.env.production.example`
2. Frontend `.env`: `VITE_API_BASE_URL=http://localhost:9520/api`, `VITE_APP_NAME=MyHR`
3. Start: `npm run dev` (backend) + frontend Vite — login/API baca tulis `hr.*` di Azure
4. Legacy CI tetap di `dbo`; jangan dual-write modul yang sama tanpa sync
5. Setelah sync users pertama kali (atau bila `level_code` login NULL): pastikan `09_users_level_id.sql` ikut (`sync:prod:foundation` sudah menjalankan 06+09)
6. Soft-launch password: `npm run reset:hr-passwords` → setiap `hr.users` password = username (bcrypt). **Tidak** mengubah `dbo.users`. Ulangi setelah sync users baru dari dbo.

### Sync berkala (dual-run)

```bash
npm run sync:prod:foundation
npm run sync:prod:operational
# atau: npm run sync:prod
npm run verify:prod
```

### Host production (nanti)

1. Salin `.env.production.example` → secret store / `.env` di server (`NODE_ENV=production`)
2. Frontend `VITE_API_BASE_URL` → URL API publik
3. Per modul cutover: hentikan write CI ke tabel itu; `dbo` tetap arsip + patokan id
4. Rollback workstation ke SQL Express: restore blok `DB_*` lokal yang dikomentari di `.env`

### Dual-write — yang harus dihindari

Jangan biarkan user mengisi **modul yang sama** di CI (`dbo`) dan app baru (`hr`) tanpa sync. Pilih satu pemilik write per modul, atau sync `dbo→hr` sampai CI dihentikan.

---

## Rollback

- **Sebelum traffic app ke `hr`:** drop objek di skema `hr` (atau `DROP SCHEMA hr` setelah drop objek) — `dbo` tidak tersentuh.
- **Sesudah live:** jangan drop `hr`; revert app `DB_*` ke lokal/staging dan perbaiki sync. Restore dari backup Azure bila perlu.

---

## Catatan cold-start yang sudah ditangani di skrip

- Urutan DDL: views login (`05`/`12`/`24`) **setelah** `levels` + `structure`.
- `13_wave1_sidebar_menus.sql` memastikan `hr_reconciliation` (remap dbo Reconciliation `legacy_id=20` atau insert folder).
- `hr.workers_finger_oams.shift` = `VARCHAR(10)` (match dbo; sebelumnya `VARCHAR(2)` gagal sync nilai `CUTI`/`OFF`).
- `dbo_missing_in_hr` pada tabel windowed (permit/finger/roster/pola/cuti_kerja) = expected di luar window month-2.

## Checklist cepat

- [x] `CONFIRM_PROD_MIGRATE=YES` + allowlist cocok
- [x] DDL gelombang 1–4 OK
- [x] `sync_dbo_to_hr_prod.js foundation` lalu `operational`
- [x] `verify_id_alignment_prod.js` exit 0 (+ smoke `v_user_login` / sickness `legacy_id`)
- [x] App soft-launch `DB_*` → Azure, `HR_SCHEMA=hr` (`.env` gitignored; lihat `.env.production.example` untuk host publik)
- [ ] Akun app SQL: idealnya DML `hr` saja (bukan `dbo`) — review role Azure
- [x] Sync berkala tersedia: `npm run sync:prod:*` / `verify:prod`
- [x] `legacy_id` tidak di-drop; kontrak migrasi tetap `hr.id = dbo.id`
