import * as XLSX from 'xlsx';

const MAX_ROWS = 2000;

/** Excel serial date → YYYY-MM-DD (UTC-safe for date-only values). */
function excelSerialToIso(serial) {
  const n = Number(serial);
  if (!Number.isFinite(n)) return null;
  const parsed = XLSX.SSF.parse_date_code(n);
  if (!parsed) return null;
  const y = parsed.y;
  const m = String(parsed.m).padStart(2, '0');
  const d = String(parsed.d).padStart(2, '0');
  return `${y}-${m}-${d}`;
}

function cellToString(value) {
  if (value == null) return '';
  if (value instanceof Date) {
    const y = value.getFullYear();
    const m = String(value.getMonth() + 1).padStart(2, '0');
    const d = String(value.getDate()).padStart(2, '0');
    return `${y}-${m}-${d}`;
  }
  // Avoid scientific notation / trailing .0 from numeric cells
  if (typeof value === 'number' && Number.isFinite(value)) {
    return Number.isInteger(value) ? String(value) : String(value);
  }
  return String(value).trim().replace(/\.0+$/, '');
}

function parseDateCell(value) {
  if (value == null || value === '') return null;
  if (value instanceof Date && !Number.isNaN(value.getTime())) {
    const y = value.getFullYear();
    const m = String(value.getMonth() + 1).padStart(2, '0');
    const d = String(value.getDate()).padStart(2, '0');
    return `${y}-${m}-${d}`;
  }
  if (typeof value === 'number') {
    return excelSerialToIso(value);
  }
  const raw = String(value).trim();
  if (!raw) return null;
  if (/^\d{4}-\d{2}-\d{2}/.test(raw)) return raw.slice(0, 10);
  const ts = Date.parse(raw);
  if (!Number.isNaN(ts)) {
    const d = new Date(ts);
    const y = d.getFullYear();
    const m = String(d.getMonth() + 1).padStart(2, '0');
    const day = String(d.getDate()).padStart(2, '0');
    return `${y}-${m}-${day}`;
  }
  // numeric string excel serial
  if (/^\d+(\.\d+)?$/.test(raw)) return excelSerialToIso(raw);
  return null;
}

/**
 * Parse uploaded buffer into legacy-shaped rows.
 * Columns: date, nrp, full_name, pola_kerja, pola_cuti, hari_ke, remark
 */
export function parseWorkPatternSpreadsheet(buffer, originalName = '') {
  const name = String(originalName || '').toLowerCase();
  const workbook = XLSX.read(buffer, {
    type: 'buffer',
    cellDates: true,
    raw: false,
  });
  const sheetName = workbook.SheetNames[0];
  if (!sheetName) {
    return { rows: [], error: 'Spreadsheet has no sheets.' };
  }
  const sheet = workbook.Sheets[sheetName];
  // raw:false keeps CSV/text cells as displayed strings (preserves NRP leading zeros).
  // Dates may arrive as Date objects (cellDates) or formatted strings.
  const matrix = XLSX.utils.sheet_to_json(sheet, {
    header: 1,
    defval: '',
    raw: false,
  });

  if (!Array.isArray(matrix) || matrix.length < 2) {
    return { rows: [], error: 'No data rows found. Include a header row and at least one data row.' };
  }

  const dataRows = matrix.slice(1);
  if (dataRows.length > MAX_ROWS) {
    return {
      rows: [],
      error: `Too many rows (${dataRows.length}). Max is ${MAX_ROWS}.`,
    };
  }

  const rows = [];
  for (let i = 0; i < dataRows.length; i += 1) {
    const row = dataRows[i] || [];
    const excelRow = i + 2; // 1-based + header
    const allEmpty = row.every((cell) => cellToString(cell) === '');
    if (allEmpty) continue;

    const date = parseDateCell(row[0]);
    const nrp = cellToString(row[1]).toUpperCase();
    const fullName = cellToString(row[2]).toUpperCase();
    const polaKerja = cellToString(row[3]).toUpperCase();
    const polaCuti = cellToString(row[4]).toUpperCase();
    const hariKeRaw = cellToString(row[5]);
    const remark = cellToString(row[6]).toUpperCase() || null;
    const hariKe = hariKeRaw === '' ? null : Number(hariKeRaw);

    rows.push({
      excelRow,
      date,
      nrp,
      full_name: fullName,
      pola_kerja: polaKerja,
      pola_cuti: polaCuti,
      hari_ke: Number.isFinite(hariKe) ? hariKe : null,
      remark,
      source: name,
    });
  }

  return { rows, error: null };
}

export function buildWorkPatternExampleCsv() {
  const header = [
    'date',
    'nrp',
    'full_name',
    'pola_kerja',
    'pola_cuti',
    'hari_ke',
    'remark',
  ];
  // Quote NRP so spreadsheets keep the leading zero.
  const sample = [
    '2026-07-01',
    '"0216691"',
    'EXAMPLE NAME',
    '6:1',
    '70:14',
    '1',
    'D',
  ];
  return `${header.join(',')}\n${sample.join(',')}\n`;
}

function toExportDate(value) {
  if (!value) return '';
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

/** Build .xlsx buffer from WORK_PATTERN_SP SELECT rows (legacy export columns). */
export function buildWorkPatternExportXlsx(rows = []) {
  const sheetRows = (Array.isArray(rows) ? rows : []).map((row) => ({
    TANGGAL: toExportDate(row.date),
    NAMA: row.full_name ?? '',
    NRP: row.nrp != null ? String(row.nrp) : '',
    JABATAN: row.jabatan ?? '',
    'POLA CUTI': row.pola_cuti ?? '',
    'POLA KERJA': row.pola_kerja ?? '',
    'HARI KE': row.hari_ke ?? '',
    REMARK: row.remark ?? '',
  }));

  const worksheet = XLSX.utils.json_to_sheet(
    sheetRows.length > 0
      ? sheetRows
      : [
          {
            TANGGAL: '',
            NAMA: '',
            NRP: '',
            JABATAN: '',
            'POLA CUTI': '',
            'POLA KERJA': '',
            'HARI KE': '',
            REMARK: '',
          },
        ],
  );
  worksheet['!cols'] = [
    { wch: 12 },
    { wch: 28 },
    { wch: 12 },
    { wch: 28 },
    { wch: 12 },
    { wch: 12 },
    { wch: 10 },
    { wch: 10 },
  ];

  const workbook = XLSX.utils.book_new();
  XLSX.utils.book_append_sheet(workbook, worksheet, 'Pola Kerja');
  return XLSX.write(workbook, { type: 'buffer', bookType: 'xlsx' });
}

/** Build .xlsx buffer from ROSTER_SP SELECT rows. */
export function buildRosterExportXlsx(rows = []) {
  const sheetRows = (Array.isArray(rows) ? rows : []).map((row) => ({
    TANGGAL: toExportDate(row.date),
    NRP: row.nrp != null ? String(row.nrp) : '',
    NAMA: row.full_name ?? '',
    JABATAN: row.jabatan ?? '',
    DEPARTMENT: row.department_name ?? '',
    SECTION: row.section_name ?? '',
    'POLA KERJA': row.pola_kerja ?? '',
    'POLA CUTI': row.pola_cuti ?? '',
    'HARI KE': row.hari_ke ?? '',
    'STATUS ABSEN': row.remark ?? '',
  }));

  const worksheet = XLSX.utils.json_to_sheet(
    sheetRows.length > 0
      ? sheetRows
      : [
          {
            TANGGAL: '',
            NRP: '',
            NAMA: '',
            JABATAN: '',
            DEPARTMENT: '',
            SECTION: '',
            'POLA KERJA': '',
            'POLA CUTI': '',
            'HARI KE': '',
            'STATUS ABSEN': '',
          },
        ],
  );
  worksheet['!cols'] = [
    { wch: 12 },
    { wch: 12 },
    { wch: 28 },
    { wch: 28 },
    { wch: 20 },
    { wch: 20 },
    { wch: 12 },
    { wch: 12 },
    { wch: 10 },
    { wch: 12 },
  ];

  const workbook = XLSX.utils.book_new();
  XLSX.utils.book_append_sheet(workbook, worksheet, 'Roster Kerja');
  return XLSX.write(workbook, { type: 'buffer', bookType: 'xlsx' });
}

export const POLA_KERJA_IMPORT_MAX_ROWS = MAX_ROWS;
