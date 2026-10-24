/**
 * Production alias: verify dbo↔hr id alignment on PROD_DB_* + runtime smoke.
 *
 * Requires CONFIRM_PROD_MIGRATE=YES and PROD_DB_SERVER_ALLOWLIST
 * (see config/prodDatabase.js and docs/AZURE_HR_DEPLOY.md).
 *
 * Usage: node scripts/hr/verify_id_alignment_prod.js
 */
process.env.VERIFY_USE_PROD = '1';
process.env.VERIFY_SMOKE = '1';
await import('./seed_verify_id_alignment.js');
