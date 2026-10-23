import { getConnection, sql } from '../config/database.js';
import { qualifyProcedureName } from '../config/databaseSchema.js';

/**
 * Persist one activity_log row (hot table; SP may ROTATE when full).
 * Failures are soft — callers should fire-and-forget via logActivity().
 */
export async function writeActivityLog({
  byJobsite = 1,
  module,
  action,
  recordId = null,
  recordKey = null,
  message = null,
  actorUserId = null,
}) {
  if (!module || !action) return null;

  const pool = await getConnection();
  const request = pool
    .request()
    .input('ACTION_SP', sql.NVarChar, 'INSERT')
    .input('MODULE', sql.NVarChar(50), String(module).slice(0, 50))
    .input('ACTION', sql.NVarChar(30), String(action).slice(0, 30))
    .input(
      'RECORD_ID',
      sql.BigInt,
      recordId == null || recordId === '' ? null : Number(recordId),
    )
    .input(
      'RECORD_KEY',
      sql.NVarChar(100),
      recordKey == null || recordKey === ''
        ? null
        : String(recordKey).slice(0, 100),
    )
    .input(
      'MESSAGE',
      sql.NVarChar(300),
      message == null || message === '' ? null : String(message).slice(0, 300),
    )
    .input('BY_USER', sql.Int, actorUserId)
    .input('BY_JOBSITE', sql.Int, byJobsite || 1);

  return request.execute(qualifyProcedureName('ACTIVITY_LOG_SP', 'hr'));
}

/**
 * Best-effort activity log from an Express request. Never throws to the caller.
 */
export function logActivity(req, { module, action, recordId, recordKey, message }) {
  const byJobsite = Number(req?.user?.by_jobsite) || 1;
  const id = Number(req?.user?.id);
  const actorUserId = Number.isFinite(id) && id > 0 ? id : null;

  writeActivityLog({
    byJobsite,
    module,
    action,
    recordId,
    recordKey,
    message,
    actorUserId,
  }).catch((err) => {
    console.error('activity_log write failed:', err.message);
  });
}
