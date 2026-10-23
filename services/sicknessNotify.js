import sql from 'mssql';
import { getConnection } from '../config/database.js';
import { qualifyProcedureName } from '../config/databaseSchema.js';
import { publishToUsers } from './notifyHub.js';

const procedure = () => qualifyProcedureName('SICKNESS_INBOX_SP', 'hr');

function rowsOf(result) {
  return result?.recordset || [];
}

function publicUrl(url) {
  return String(url || '').replaceAll('/sakit', '/sickness');
}

/** Waiting sakit rows for the signed-in atasan, or for HR in their SIS/LS group. */
export async function listSicknessInbox({
  scopeSections,
  levelCode,
  workerScope,
  byUser,
  byJobsite,
}) {
  const pool = await getConnection();
  const result = await pool
    .request()
    .input('ACTION_SP', sql.NVarChar(30), 'LIST')
    .input('SCOPE_SECTIONS', sql.NVarChar(sql.MAX), scopeSections || '')
    .input('LEVEL_CODE', sql.NVarChar(50), levelCode || null)
    .input('WORKER_SCOPE', sql.NVarChar(20), workerScope || null)
    .input('BY_USER', sql.Int, byUser ?? null)
    .input('BY_JOBSITE', sql.Int, byJobsite)
    .execute(procedure());

  return rowsOf(result).map((row) => ({
    module: 'sickness',
    id: Number(row.id),
    nrp: row.nrp || '',
    full_name: row.full_name || '',
    jabatan: row.jabatan || '',
    queue: row.queue || '',
    url: publicUrl(row.url),
    created_at: row.created_at || null,
  }));
}

function publishRows(rows, id) {
  if (!rows.length) return;
  const first = rows[0];
  publishToUsers(
    rows.map((row) => row.user_id),
    {
      module: 'sickness',
      id: Number(id),
      nrp: first.nrp || '',
      full_name: first.full_name || '',
      jabatan: first.jabatan || '',
      queue: first.queue || '',
      url: publicUrl(first.url),
    },
  );
}

/** After a sakit row is saved, ping the online atasan. Offline users catch up on reconnect. */
export async function notifySicknessCreated(id, byJobsite) {
  const pool = await getConnection();
  const result = await pool
    .request()
    .input('ACTION_SP', sql.NVarChar(30), 'RECIPIENTS')
    .input('ID', sql.Int, id)
    .input('BY_JOBSITE', sql.Int, byJobsite)
    .execute(procedure());

  publishRows(rowsOf(result), id);
}

/** After an atasan approves, ping the online HR admin for that SIS/LS group. */
export async function notifySicknessHr(id, byJobsite) {
  const pool = await getConnection();
  const result = await pool
    .request()
    .input('ACTION_SP', sql.NVarChar(30), 'HR_RECIPIENTS')
    .input('ID', sql.Int, id)
    .input('BY_JOBSITE', sql.Int, byJobsite)
    .execute(procedure());

  publishRows(rowsOf(result), id);
}
