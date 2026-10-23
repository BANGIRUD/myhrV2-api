import { getConnection, sql } from '../config/database.js';
import { qualifyProcedureName } from '../config/databaseSchema.js';

/** Levels that may insert recon rows already approved through HR. */
export function isReconAutoApproveLevel(levelCode) {
  const level = String(levelCode || '')
    .trim()
    .toLowerCase();
  return level === 'superadmin' || level === 'sa' || level === 'hr_administrator';
}

/**
 * Promote a freshly inserted parent to Approve by HR (3-row chain, all verifiers = inputter).
 * @param {'sickness'|'permit'|'finger_error'} module
 * @returns {Promise<boolean>} true when the chain was applied
 */
export async function applyReconAutoApprove(module, id, byUser, byJobsite) {
  const parentId = Number(id);
  const actorId = Number(byUser);
  if (!Number.isInteger(parentId) || parentId <= 0) return false;
  if (!Number.isInteger(actorId) || actorId <= 0) return false;

  const pool = await getConnection();
  const result = await pool
    .request()
    .input('ACTION_SP', sql.NVarChar, 'APPLY')
    .input('MODULE', sql.NVarChar, module)
    .input('ID', sql.Int, parentId)
    .input('BY_USER', sql.Int, actorId)
    .input('BY_JOBSITE', sql.Int, byJobsite ?? 1)
    .execute(qualifyProcedureName('RECON_AUTO_APPROVE_SP', 'hr'));

  const row = result?.recordset?.[0];
  if (!row?.success) {
    const msg = row?.message || 'RECON_AUTO_APPROVE_SP failed';
    throw new Error(msg);
  }
  return Boolean(row.applied);
}
