import * as XLSX from 'xlsx';
import { WORKERS_LS_HEADERS, WORKERS_SIS_HEADERS } from './workersImport.js';

function cell(value) {
  if (value == null) return '';
  if (value instanceof Date && !Number.isNaN(value.getTime())) {
    const y = value.getFullYear();
    const m = String(value.getMonth() + 1).padStart(2, '0');
    const d = String(value.getDate()).padStart(2, '0');
    return `${y}-${m}-${d}`;
  }
  const raw = String(value);
  if (/^\d{4}-\d{2}-\d{2}/.test(raw)) return raw.slice(0, 10);
  return raw;
}

/**
 * Build export XLSX from SELECT_EXPORT rows.
 * @param {'sis'|'vendor'} source
 * @param {boolean} includeGrade — omit grade column entirely when false
 */
export function buildWorkersExportXlsx(rows = [], source = 'sis', includeGrade = false) {
  const src = source === 'vendor' ? 'vendor' : 'sis';
  const headers = (src === 'sis' ? WORKERS_SIS_HEADERS : WORKERS_LS_HEADERS).filter(
    (h) => includeGrade || h !== 'grade',
  );

  const list = Array.isArray(rows) ? rows : [];
  const sheetRows = list.map((row) => {
    const out = {};
    for (const h of headers) {
      out[h] = cell(row[h]);
    }
    return out;
  });

  const empty = Object.fromEntries(headers.map((h) => [h, '']));
  const worksheet = XLSX.utils.json_to_sheet(
    sheetRows.length > 0 ? sheetRows : [empty],
    { header: headers },
  );
  worksheet['!cols'] = headers.map(() => ({ wch: 14 }));

  const workbook = XLSX.utils.book_new();
  XLSX.utils.book_append_sheet(
    workbook,
    worksheet,
    src === 'sis' ? 'Employees SIS' : 'Employees LS',
  );
  return XLSX.write(workbook, { type: 'buffer', bookType: 'xlsx' });
}
