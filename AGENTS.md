# AGENTS.md — MyHR Backend (HR-only)

Node.js API for **MyHR**: auth, menus + level permissions, users, enums, and HR master data.
All active code targets SQL Server schema **`hr`** (`HR_SCHEMA`, default `hr`), multi-site via `by_jobsite`.

> The old Ticketing/FLEET modules (schema `ticketing`) are **disabled**. Do not add new features on them.
> See [Legacy / disabled](#legacy--disabled-do-not-extend).

---

## Stack

- Node.js ESM (`"type": "module"`)
- Express 5
- SQL Server via `mssql`
- Auth: JWT (`jsonwebtoken`) + bcrypt
- Schema: `HR_SCHEMA` (default `hr`) via `config/databaseSchema.js`
- SQL applied **manually / via script** from `scripts/hr/` (`node scripts/hr/run_migrate.js` runs every file in order)

## Active project layout

| Path | Role |
| ------------------------------ | ------------------------------------------------------- |
| `index.js` | Express entry (`cors`, JSON, mount `/api`, `/health`) |
| `routes/index.js` | Mounts only `/auth`, `/menus`, `/hr`, `/dashboard` |
| `routes/auth.js` | Login, `me`, logout, change password |
| `routes/menus.js` | `/menus/permissions`, `/menus/navigation` |
| `routes/hrMaster.js` | `/hr/*` master endpoints (thin, `verifyToken`) |
| `controllers/auth.js` | Login/JWT helpers (reads `hr.v_user_login`) |
| `controllers/hrMaster.js` | HR master handlers + `executeHrSp()` |
| `services/hrMenuPermission.js` | Menu navigation/permissions from `hr.level_permissions` |
| `middleware/auth.js` | `verifyToken`, `requireAuth` |
| `config/database.js` | Single shared pool (`getConnection`) |
| `config/databaseSchema.js` | `getHrSchema()`, `quoteSchemaName()`, `qualifyProcedureName(name, 'hr')` |
| `config/azureReadonly.js` | Read-only guard for Azure seed source |
| `scripts/hr/` | DDL, SPs, seeds, views, ETL (numbered, run in order) |

## Shared patterns

1. **Always use the `hr` schema.** SP calls go through `executeHrSp(name, action, params)` which does
   `qualifyProcedureName(name, 'hr')`; ad-hoc SQL uses `quoteSchemaName(getHrSchema())`.
2. **CRUD via stored procedures** with `@ACTION_SP` (`SELECT | GET | INSERT | UPDATE | DELETE`, extra actions allowed e.g. `RESET_PASSWORD`).
3. List SPs return **two recordsets**: rows, then `{ total_count }`; support `PAGE`, `PAGE_SIZE` (0 = all), `SEARCH`.
4. Mutating SPs return `{ success, message, id? }` as first row; handlers map it to HTTP 201/200/400.
5. Response shape: `{ success, message, data?, meta?, error? }`.
6. Soft delete with `deleted_at` / `deleted_by`; audit with `created_by` / `updated_by` / `deleted_by` as `hr.users.id` (`INT NULL` — join for username/full_name).
7. Pass `BY_USER` (`hr.users.id`) and `BY_JOBSITE` (from `req.user.by_jobsite`, default `1`) on every SP call. Non-user actors (seed/sync) leave the column `NULL`.
8. Schema-qualify every table in SPs/views (`hr.users`, `hr.enums`, …). Never rely on default schema.
9. Routes stay thin; logic lives in controllers/SPs.
10. **Activity log** (transaction history, separate from row audit columns):
    - Hot table `hr.activity_log` + registry `hr.activity_log_registry`. No PURGE — when hot reaches ~500k rows, `ROTATE` renames it to `activity_log_YYYYMMDD` and recreates an empty hot table.
    - Write via `services/activityLog.js` → `hr.ACTIVITY_LOG_SP` `INSERT` (best-effort; never fail the business request). Wired on mutations for sickness, permit, users, work_pattern, roster, edit_policy, level_permissions.
    - Apply: `node scripts/hr/run_migrate.js 78 79`. Manual rotate: `EXEC hr.ACTIVITY_LOG_SP @ACTION_SP=N'ROTATE'`.

### Levels (`hr.levels`, 10 canonical)

`superadmin`, `management`, `department_head`, `section_head`, `group_leader`, `admin_section`, `hr_admin`,
`hr_administrator`, `module_admin`, `employee` (see `scripts/hr/27_levels_consolidate.sql`).

- Merged away: `administrator` → `management`; `hr_admin_ls` → `hr_admin` (`worker_scope=ls`);
  `irel|meals|safety|attendance` → `module_admin` (`module=...`). `hr.level_legacy_map` maps every legacy code.
- Per-user attributes on `hr.users`: `worker_scope` (`sis|ls|all`) and `module` (`irel|meals|safety|attendance`);
  exposed by `hr.v_user_login`, JWT claims and `USERS_SP` (`@WORKER_SCOPE`, `@MODULE`).
- `hr.level_permissions.audience` (NULL = whole level, else CSV of `sis|ls|irel|meals|safety|attendance`) narrows a
  grant to users whose `worker_scope`/`module` matches (`getAudienceTokens` in `services/hrMenuPermission.js`).
  Users with neither attribute are never narrowed. This is a filter on top of the matrix, not a second RBAC model.
- `node scripts/hr/run_migrate.js 08 09 11 24 27` applies only selected scripts (numeric prefixes).

### Permissions (RBAC)

- Permission identity is `hr.menus.menu_code`; flags live in `hr.level_permissions`
  (`can_read`, `can_insert`, `can_update`, `can_delete`, `can_export`, `can_approve`).
- Navigation/permissions: `services/hrMenuPermission.js`.
  - `isFullMenuAccessUser()` → only `superadmin` / `sa` bypass the matrix.
  - `isAllAccessUser()` (`approval_stage = all`, administrator, management…) is a **data scope** rule, not a menu bypass.
- `/api/hr/*` currently only requires `verifyToken`; the frontend hides actions via `usePermission(menuCode)`.
  When adding sensitive write endpoints, enforce the matrix server-side too — do not invent a second RBAC model.
- `PUT /api/hr/level-permissions` is an exception: `verifyToken` + `requireFullMenuAccess` (superadmin/`sa` only).
  Driven by `hr.LEVEL_PERMISSIONS_SP` (`SELECT` / `UPSERT`, script `36_level_permissions_sp.sql`). Sidebar visibility =
  `hr.menus.show_sidebar` (catalog) **and** `hr.level_permissions.can_read` for the user's level.

---

## Active API surface

| Mount | Endpoints |
| ----- | --------- |
| `/api/auth` | `POST /login`, `GET /me`, `POST /logout`, `POST /change-password` |
| `/api/menus` | `GET /permissions`, `GET /navigation` |
| `/api/dashboard` | `GET /attendance?date=&shift=all\|day\|night&department=&section=` |
| | `GET /work-pattern?month=YYYY-MM&department=&section=`, `GET /employee-unfit?department=&section=` |
| `/api/hr` | `GET /jobsites`, `GET /levels`, `GET /submissions`, `GET /structure?type=&ref_id=` |
| | `GET/POST /users`, `GET/PUT/DELETE /users/:id`, `POST /users/:id/reset-password` |
| | `GET/POST /menus`, `GET/PUT/DELETE /menus/:id` |
| | `GET/POST /enums`, `GET /enums/types`, `GET/PUT/DELETE /enums/:id` |
| | `GET/POST /work-pattern`, `GET /work-pattern/lookup?nrp=`, `GET /work-pattern/example`, `GET /work-pattern/export`, `GET /work-pattern/generate-preview`, `POST /work-pattern/generate`, `POST /work-pattern/import`, `GET/PUT/DELETE /work-pattern/:id` |
| | `GET /roster`, `GET /roster/export`, `GET /roster/edit-policy`, `GET/PUT /roster/:id` |
| | `GET /sickness`, `GET /sickness/section`, `GET /sickness/group`, `GET /sickness/lookup?nrp=`, `GET /sickness/evidence?path=`, `GET /sickness/evidence/:photoId`, `POST /sickness` (multipart + optional `files[]`), `PUT /sickness/:id`, `POST /sickness/:id/cancel`, `POST /sickness/:id/approve-section`, `POST /sickness/:id/reject-section`, `GET /sickness/department`, `GET/POST /sickness/department-exceptions`, `DELETE /sickness/department-exceptions/:id`, `POST /sickness/:id/approve-department`, `POST /sickness/:id/reject-department`, `POST /sickness/:id/approve-group`, `POST /sickness/:id/reject-group`, `GET /sickness/hr`, `GET /sickness/hr/export`, `POST /sickness/:id/approve-hr`, `POST /sickness/:id/reject-hr`, `GET /sickness/:id` |
| | `GET /permit`, `GET /permit/section`, `GET /permit/group`, `GET /permit/lookup?nrp=`, `GET /permit/evidence?path=`, `GET /permit/evidence/:photoId`, `POST /permit` (multipart + optional `files[]`), `PUT /permit/:id`, `POST /permit/:id/cancel`, `POST /permit/:id/approve-section`, `POST /permit/:id/reject-section`, `GET /permit/department`, `GET/POST /permit/department-exceptions`, `DELETE /permit/department-exceptions/:id`, `POST /permit/:id/approve-department`, `POST /permit/:id/reject-department`, `POST /permit/:id/approve-group`, `POST /permit/:id/reject-group`, `GET /permit/hr`, `GET /permit/hr/export`, `POST /permit/:id/approve-hr`, `POST /permit/:id/reject-hr`, `GET /permit/:id` |
| | `GET /finger-error`, `GET /finger-error/section`, `GET /finger-error/group`, `GET /finger-error/department`, `GET /finger-error/lookup?nrp=`, `GET /finger-error/example`, `POST /finger-error/import` (multipart `file` + `category` + `mode`), `GET/POST /finger-error/department-exceptions`, `DELETE /finger-error/department-exceptions/:id`, `GET /finger-error/evidence?path=`, `GET /finger-error/evidence/:photoId`, `POST /finger-error` (multipart + optional `files[]`), `PUT /finger-error/:id`, `POST /finger-error/:id/cancel`, `POST /finger-error/:id/approve-section|group|department|hr`, `POST /finger-error/:id/reject-section|group|department|hr`, `GET /finger-error/hr`, `GET /finger-error/hr/export`, `GET /finger-error/:id` |
| `/api/notifications` | `GET /` catch-up inbox (sickness, permit, finger-error) |
| `/ws` | WebSocket on the same HTTP port (`?token=`). In-memory presence. `POST /sickness`, `POST /permit`, and `POST /finger-error` publish to the online atasan. |
| | `GET/POST /edit-policy/modules`, `GET/POST /edit-policy`, `GET/PUT/DELETE /edit-policy/:id` |
| | `GET /menu-privilege`, `GET /level-permissions?level_id=&include_legacy=&q=`, `PUT /level-permissions` (superadmin) |

**Dashboard** (`routes/hrDashboard.js`, `controllers/hrDashboard.js`, `hr.DASHBOARD_SP`): `verifyToken` only.
- `hr.DASHBOARD_SP` (`ATTENDANCE | POLA_KERJA | UNFIT`) is being migrated from `dbo` to `hr` one action at a time.
  `@SOURCE` (`dbo | hr`, NULL = per-action default in the SP) picks the source; the API and response shape never change.
  - `UNFIT` → **hr** (`hr.workers_standby`, scripts 29/30). Jobsite-aware.
  - `POLA_KERJA` → **hr** (`hr.workers_roster_kerja`, scripts 31/32). That table only holds a rolling window
    (month-2 … month+2); months outside it automatically fall back to the `dbo` bridge when no `@SOURCE` is given.
  - `ATTENDANCE` → **hr, computed inside the SP** (script 28, block "Port of dbo.fv_achievement_attendance_ratio").
    Plan/actual per worker are derived on the fly from the hr source tables of script 35 (`workers_travel`,
    `workers_cuti_period(_master)`, `workers_sickness`, `workers_permit`, `workers_cuti_kerja`, `workers_finger_log`,
    `workers_finger_oams`, `workers_finger_error`, `date_holiday`) plus `workers_roster_kerja`, `workers_standby`,
    `v_workers_active`, `enums`. **To change attendance rules, edit that block and re-run `node scripts/hr/run_migrate.js 28`**
    – no cache table to rebuild. Same buckets as the legacy SP (`actual_cuti` keeps the `plan = 'CLL'` quirk).
    Window month-2 … month+2 (finger/OAMS up to today); other days fall back to the `dbo` bridge
    (`dbo.workers_attendance`, jobsite 1 only, ~8 s) when no `@SOURCE` is given. ~0.8 s per call.
    `@SOURCE='cache'` reads `hr.attendance_ratio` (scripts 33/34, copy of the Azure cron table; lags a few days on finger data).
  - Data chain: Azure `dbo` (READ-ONLY) → local `dbo` → local `hr`: `node --max-old-space-size=6144 scripts/hr/seed_attendance_from_azure.js [table…]`
    (`workers_standby`, `workers_roster_kerja`, the script-35 sources; `achievement_attendance_ratio` only for the cache).
    Run it manually when fresh data is needed (no automatic sync yet); the local DB is SQL Server Express (10 GB cap),
    do not widen the windows without checking free space.
    Local `dbo.workers_roster_kerja`, `dbo.achievement_attendance_ratio` (+ `_backup`) were truncated to free space, so the `dbo`
    bridge fallback (days outside the `hr` windows) returns empty plans. The `hr` tables are the source of truth locally;
    scripts 32/34 and the generic hr sync skip their soft-delete step while `dbo` has no rows for the window.
  - Verify a migrated action: `node scripts/hr/dashboard_parity.js UNFIT|POLA_KERJA [YYYY-MM]|ATTENDANCE [date] [shift]|ALL`
    (runs `@SOURCE='dbo'` vs `'hr'` and diffs the rows). All three must be identical. For ATTENDANCE the dbo side needs
    local `dbo.workers_roster_kerja` rows for that day (copy them back from `hr.workers_roster_kerja` first, delete after).
- Row scope: `services/hrDashboardScope.js` → `all` stage / `structure_scoped = false` see everything; others see their
  JWT `section` ids only for every level (driven by the `hr.users` row); a user with no section assigned gets every
  section of their `department` ids instead (no assignment → no rows). Sent as `SCOPE_SECTIONS`. Mirrored in the frontend `scopeStructureOptions`
  (dropdown options) – change both together. `loadStructureTree` (`controllers/auth.js`, `structure_tree` in login/`/auth/me`)
  follows the same rule: with assigned sections it counts only those sections (departments without any are dropped), so the
  header card matches the panel totals.
  Filters from the query are intersected with this scope, never widen it.
- `shift`: `day`/`night` zero the other shift's columns and use `actual_alpha_day|night`; `all` uses `actual_alpha`.
  Missing `date` defaults to the shift date (before 07:30 = yesterday). `pola-kerja` is per month.
- Local `hr` dashboard data is seeded from Azure (see `seed_attendance_from_azure.js`); test attendance with a date
  inside the window (month-2 … today). Dates outside it use the stale local `dbo` bridge.

**Enums** (`hr.enums`, `hr.ENUMS_SP`): typed lookups (department/section helpers, worker statuses, job ranks, …).
`GET /api/hr/enums?type=&category=&q=&page=&page_size=`; `GET /api/hr/enums/types` returns
`[{ type, total }]` — the catalog of enum types that exist in the HR system.
Define `/enums/types` **before** `/enums/:id` in the router.

**Auth/JWT claims** come from `hr.v_user_login` (includes `id`, `username`, `level_id`, `level_code`,
`level_name`, `approval_stage`, `by_jobsite`, department/section scope). Login also supports a group-leader
fallback via `hr.v_users_gl_login`. `BYPASS_PASSWORD` is for local tests only.

**Dev bypass:** with `NODE_ENV=development`, `verifyToken` may synthesize a user when Bearer is missing
(unless `AUTH_DEV_BYPASS=false`). `requireAuth` (used by `/auth/me`, `/auth/logout`) never bypasses.

---

## Database scripts (`scripts/hr/`)

Run in numeric order (`run_migrate.js` does this). Key files:

| Script | Purpose |
| ------ | ------- |
| `01_schema.sql` … `13_*` | `hr` schema, jobsites, menus, levels, level_permissions, login views, wave-1 sidebar |
| `14_users_sp.sql` | `hr.USERS_SP` |
| `15_menus_sp.sql` | `hr.MENUS_SP` |
| `16_enums.sql` | `hr.enums` table |
| `17_structure.sql` | `hr.structure` (department/section tree) |
| `19`–`24_*` | workers + vendors + active views + login views |
| `25_enums_sp.sql` | `hr.ENUMS_SP` |
| `26_enums_menu.sql` | menu `hr_enums` (`/master/enums`) + level permissions |
| `36_level_permissions_sp.sql` | `hr.LEVEL_PERMISSIONS_SP` (`SELECT` / `UPSERT`) for the matrix editor |
| `27_levels_consolidate.sql` | 15 → 10 levels, user `worker_scope`/`module`, `level_permissions.audience` (idempotent) |
| `28_dashboard_sp.sql` | `hr.DASHBOARD_SP` with `@SOURCE` (all three actions on `hr`; `dbo` bridge kept as fallback outside the synced windows) |
| `29_workers_standby.sql`, `30_sync_workers_standby_from_dbo.sql` | `hr.workers_standby` + idempotent sync from `dbo` |
| `31_workers_roster_kerja.sql`, `32_sync_workers_roster_kerja_from_dbo.sql` | `hr.workers_roster_kerja` (rolling window) + sync |
| `33_attendance_ratio.sql`, `34_sync_attendance_ratio_from_dbo.sql` | `hr.attendance_ratio` (month-2 … today) + sync |
| `35_attendance_sources.sql` | hr source tables for the computed ATTENDANCE (travel, cuti, sickness, permit, cuti kerja, finger log/OAMS/error, holiday) |
| `37_workers_pola_kerja.sql`, `38_sync_workers_pola_kerja_from_dbo.sql` | `hr.workers_pola_kerja` (sparse month seeds; sync window month-24 … month+3) + sync from `dbo` |
| `39_pola_kerja_sp.sql` | historical `hr.POLA_KERJA_SP` (live name `hr.WORK_PATTERN_SP` after script 75) |
| `40_pola_kerja_menu.sql` | menu `hr_pola_kerja` under `hr_reconciliation` (`/reconciliation/pola-kerja`) + read grants |
| `41_pola_kerja_permissions_crud.sql` | grant insert/update/delete on `hr_pola_kerja` for `approval_stage = all` |
| `42_roster_kerja_sp.sql` | historical `hr.ROSTER_KERJA_SP` (live name `hr.ROSTER_SP` after script 75) |
| `43_roster_kerja_menu.sql` | menu `hr_roster_kerja` under `hr_reconciliation` (`/reconciliation/roster-kerja`) + read for all; update/export for `approval_stage = all` |
| `52_sakit_sp.sql` | expand `hr.workers_sickness` to match dbo columns (+ HR extras) + historical `hr.SAKIT_SP` (live name `hr.SICKNESS_SP` after script 75) |
| `53_sakit_menu.sql` | menu `hr_sakit` under `hr_reconciliation` (`/reconciliation/sakit`) + read-only grants |
| `55_workers_sickness_photos.sql` | `hr.workers_sickness_photos` (+ optional dbo sync) for bukti lampiran |
| `56_sakit_sp_crud.sql` | historical `hr.SAKIT_SP` CRUD: `LOOKUP` / `INSERT` / `UPDATE` / `CANCEL` + `evidence_paths` on SELECT/GET |
| `57_sakit_permissions_crud.sql` | grant insert/update/delete on `hr_sakit` for `approval_stage = all` |
| `58_sakit_edit_policy.sql` | module `sakit` in `hr.edit_policy` — past_days window for Ubah/Batalkan |
| `59_sakit_section_approval.sql` | `SELECT_SECTION` / `APPROVE_SECTION` / `REJECT_SECTION` (Section Head, or Unit Head if no Section Head) |
| `60_sakit_section_menu.sql` | menu `hr_sakit_section` under Section → SIA Karyawan (`/section/sakit`) |
| `61_sakit_gl_approval.sql` | `SELECT_GL` / `APPROVE_GL` / `REJECT_GL` (LS only; Group Leader or Unit Head; superadmin bypass) |
| `62_sakit_group_menu.sql` | menu `hr_sakit_group` under Group Leader → SIA Karyawan (`/group/sakit`) |
| `63_sakit_department_approval.sql` | `SELECT_DEPT` / `APPROVE_DEPT` / `REJECT_DEPT` plus `hr.sakit_department_exception` |
| `64_sakit_department_menu.sql` | menu `hr_sakit_department` under Department → SIA Karyawan (`/department/sakit`) |
| `65_sakit_checker_role.sql` | `by_checked_role` (SH/GL/UH/DH); month list seeks start_date in-month plus earlier rows still open |
| `66_sakit_list_index.sql` | parent start/end indexes for the sakit month list |
| `67_sakit_inbox.sql` | historical `hr.SAKIT_INBOX_SP` (live name `hr.SICKNESS_INBOX_SP` after script 75) |
| `68_sakit_hr_approval.sql` | `SELECT_HR` / `APPROVE_HR` / `REJECT_HR`; Waiting approve by HR, split by `worker_scope` |
| `69_sakit_hr_menu.sql` | menu `hr_sakit_hr` under Personalia → SIA Karyawan (`/personalia/sakit`) |
| `74_module_english_menus.sql` | rename live menus to `hr_work_pattern`, `hr_roster`, `hr_sickness` (+ queues), `hr_permit` (+ queues) and English `menu_url` |
| `75_english_procedure_names.sql` | live procedures `hr.SICKNESS_SP`, `hr.PERMIT_SP`, `hr.SICKNESS_INBOX_SP`, `hr.PERMIT_INBOX_SP`, `hr.WORK_PATTERN_SP`, `hr.ROSTER_SP`; drops the Indonesian names. Sickness and permit `INSERT` take applock `absence:{jobsite}:{nrp}`; `LOOKUP` returns recent active rows |
| `76_active_submissions.sql` | `hr.v_active_submissions` — shared parent date ranges. A new pengajuan module adds one `UNION ALL` here so sickness and permit reject overlapping dates and show them on lookup |
| `77_submissions_menu.sql` | menu `hr_submissions` (`/master/submissions`) read for `superadmin`, `sa`, `hr_administrator` |
| `78_activity_log.sql` | `hr.activity_log` (HOT) + `hr.activity_log_registry` — append-only transaction log |
| `79_activity_log_sp.sql` | `hr.ACTIVITY_LOG_SP` (`INSERT` / `SELECT` / `ROTATE`) + `hr.activity_log_do_rotate` |
| `84_recon_auto_approve.sql` | `hr.RECON_AUTO_APPROVE_SP` — after INSERT by `superadmin`/`sa`/`hr_administrator`, promote sickness/permit/finger_error to Approve by HR (3-row chain, verifiers = inputter) |
| `85_finger_error_gl_dept.sql` | GL/DEPT on `FINGER_ERROR_SP` + `hr.finger_error_department_exception` (same rules as sakit/ijin) |
| `86_finger_error_gl_dept_menus.sql` | menus `hr_finger_error_group` / `hr_finger_error_department` |
| `87_finger_error_inbox_gl_dept.sql` | inbox routing LS→GL, high-rank/exception→DH |
| `54_audit_by_user_id.sql` | convert `created_by`/`updated_by`/`deleted_by` NVARCHAR→`INT` (`hr.users.id`). Apply alone first, then re-apply SPs: `node scripts/hr/run_migrate.js 14 15 25 28 36 39 42 46 48 49 52` |
| `50_reconciliation_menu_urls.sql` | move pola/roster menu URLs off `/master` onto `/reconciliation/…` |
| `51_sidebar_menu_icons.sql` | distinct `hr.menus.icon` keys (must match frontend `sidebarIcons.tsx`) |
| `44_roster_kerja_admin_section.sql` | grant update/export on `hr_roster_kerja` for `admin_section` |
| `45_roster_edit_policy.sql` | legacy `hr.roster_edit_policy` (superseded by 48) |
| `46_roster_edit_policy_sp.sql` | legacy SP (superseded by `EDIT_POLICY_SP` in 48) |
| `47_roster_edit_policy_menu.sql` | legacy menu (rehomed to `hr_edit_policy` by 48) |
| `48_edit_policy.sql` | `hr.edit_policy_modules` + `hr.edit_policy` + `EDIT_POLICY_SP` + menu `hr_edit_policy` (`/master/edit-policy`) |
| `49_edit_policy_module_upsert.sql` | `hr.EDIT_POLICY_MODULES_SP` (`LIST` / `UPSERT`) — add modules from Edit Policy UI |
| `seed_attendance_from_azure.js`, `dashboard_parity.js` | Azure→dbo→hr seed (read-only Azure) and dbo-vs-hr parity check |
| `seed_*_from_azure.js` | **Read-only** pulls from Azure MYHR into local `hr.*` |
| `seed_realign_users_ids.js` | One-shot local repair: `hr.users.id = legacy_id` + remap audit `*_by` |
| `seed_verify_id_alignment.js` | Check wave-1 + wave-2 id/`ref_id` alignment vs dbo (users, sickness/permit + photos, workers, structure, enums, cuti period/master/kerja) |

### ID cutover policy (dbo → hr)

**Checklist lengkap (wajib dibaca sebelum migrate tabel baru):** [`docs/ID_CUTOVER.md`](docs/ID_CUTOVER.md). Cursor rule: `.cursor/rules/id-cutover.mdc`.

Operational tables migrated from `dbo` **preserve the same integer `id`** via `SET IDENTITY_INSERT` (`legacy_id = dbo.id`, so `id = legacy_id`). This keeps `ref_id` / parent–child graphs and views valid across future table migrations.

- **Must preserve:** `users`, `structure`, `enums`, `workers*`, `workers_sickness`, `workers_permit` (+ photos), `workers_pola_kerja`, `workers_roster_kerja`, attendance sources (incl. `workers_cuti_period_master`, `workers_cuti_period`, `workers_cuti_kerja`).
- **`hr.users`:** seeds (`06_seed_from_dbo.sql`, `seed_users_from_azure.js`) always insert with `id = dbo.id`. If local rows already drifted, run `node scripts/hr/seed_realign_users_ids.js`, then `node scripts/hr/seed_verify_id_alignment.js`.
- **`workers` / `structure` / `enums`:** sync preserves ids (`20_sync_workers_from_dbo.sql`, `18_seed_enums_structure_from_dbo.sql`, `seed_enums_structure_from_azure.js`, `seed_workers_from_azure.js`). Wave-2 verify covers `id = legacy_id`, overlapping dbo↔hr ids, workers FK (`department`/`section` → structure, `job_rank` → enums), and structure/enums `ref_id`. Sentinel `0` and orphans also present in dbo are warnings only.
- **Pola / roster:** sync `38_*` / `32_*` (+ attendance seed) preserve ids; app INSERT/GENERATE may create new IDENTITY rows (not dbo mirrors).
- **Cuti:** `workers_cuti_period.periode` → `workers_cuti_period_master.id` (same id space). Refresh via `node scripts/hr/seed_attendance_from_azure.js workers_cuti_period_master workers_cuti_period workers_cuti_kerja` (`IDENTITY_INSERT`, `legacy_id = id`). `workers_cuti_kerja` is windowed (month-2 …); `dbo_missing` outside the window is expected. Verify with `seed_verify_id_alignment.js`.
- **Exception:** `hr.menus` regenerates ids and remaps `parent_id` via `legacy_id` (product key is `menu_code`).
- Sickness/permit `by_user` / `by_verified*` still store **dbo user id space** and join `hr.users.legacy_id` (works when `id = legacy_id`).

Saat menambah modul/tabel mirror baru: DDL + sync IDENTITY_INSERT → daftarkan di `seed_verify_id_alignment.js` → jalankan verify sebelum lanjut ke tabel yang mereferensi id tersebut.

## Adding an HR master/domain module

Sakit is the reference for a staged approval module (queues, SIS/LS scope, bell, export). Copy the shape from `docs/MODULE_PATTERN_SAKIT.md`; keep each new module's own approval rules.

1. `scripts/hr/NN_<resource>.sql` — table in `hr` (with `by_jobsite`, audit + soft-delete columns) and `hr.<RESOURCE>_SP`.
2. Seed `hr.menus` row (`menu_code` = `hr_<name>`) **and** `hr.level_permissions` in the same or a following script.
   - **`menu_url` follows the parent folder**, not always `/master`:
     - under `hr_master` → `/master/<slug>`
     - under `hr_reconciliation` → `/reconciliation/<slug>`
     - under future `hr_<domain>` → `/<domain>/<slug>` (parent itself stays `#`)
   - Path = domain trace for UI/API work; keep frontend `App.tsx` + `FALLBACK_NAV_MENUS` in sync.
3. Controller functions in `controllers/hrMaster.js` (or a new `controllers/hr<Name>.js`) using `executeHrSp`.
4. Routes in `routes/hrMaster.js` (`verifyToken`), mounted under `/api/hr` (API prefix `/api/hr` is unrelated to UI path).
5. Mirror on the frontend: `HrMasterResource` + `RESOURCE_META` in `MasterTablePage`, route under the parent prefix, sidebar fallback in `navMenus.ts`.
6. Apply scripts to the **local** DB only.

---

## Env checklist (`.env.example`)

| Variable | Purpose |
| -------- | ------- |
| `DB_SERVER`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD` | Local SQL Server (never production) |
| `HR_SCHEMA` | HR schema (default `hr`) |
| `JWT_SECRET`, `JWT_EXPIRES` | Token signing / lifetime |
| `BYPASS_PASSWORD` | Local auth tests only |
| `PORT`, `HOST`, `NODE_ENV` | Server |
| `CORS_ORIGIN` | Frontend origin(s), comma-separated |
| `AUTH_DEV_BYPASS` | Set `false` to disable missing-token bypass |
| `DEFAULT_JOBSITE_ID`, `PUBLIC_JOBSITE_ID` | Default jobsite (`1`) |
| `AZURE_DB_*` | **Read-only** seed source; writes blocked by `config/azureReadonly.js` |

`DB_SCHEMA` is **legacy** (ticketing/FLEET) and should stay unset. Never commit real secrets. Never point `DB_*` at Azure production.

---

## Legacy / disabled (do not extend)

These exist only for reference and are **not mounted**:

- Routes/controllers: `customers`, `tickets`, `portal`, `samples`, `equipments`, `enums` (old `/api/enums`), `users` (old)
- `config/apiPermissions.js`, `middleware/apiPermission.js`, `services/menuPermission.js` (ticketing RBAC)
- `scripts/*.sql` in the repo root of `scripts/` (ticketing/FLEET DDL + SPs)

To revive any of them you must first port the SP/table to `hr` and remount it in `routes/index.js`.

---

## Do / Don't

- Do target schema `hr` for every table, view, and SP.
- Do use `executeHrSp` / `qualifyProcedureName(name, 'hr')`.
- Do seed `hr.menus` + `hr.level_permissions` together when adding a resource.
- Do set child `menu_url` under the parent path (`/<parent-slug>/<child-slug>`); only Master Data uses `/master/…`.
- Do pass `BY_USER` and `BY_JOBSITE` on every SP call.
- Do keep handlers thin and responses in `{ success, message, data?, meta?, error? }`.
- Don't use `getDbSchema()` / `DB_SCHEMA` / `ticketing.*` in new code.
- Don't force every new menu under `/master` when it belongs to another parent folder.
- Don't write to Azure MYHR; it is a read-only seed source.
- Don't commit `.env` secrets.
- Don't invent a second RBAC model — use `hr.menus` + `hr.level_permissions`.
