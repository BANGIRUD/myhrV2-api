import * as XLSX from 'xlsx';

const MAX_ROWS = 500;

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
  if (/^\d+(\.\d+)?$/.test(raw)) return excelSerialToIso(raw);
  return null;
}

function addDaysYmd(ymd, days) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(ymd)) return null;
  const [y, m, d] = ymd.split('-').map(Number);
  const dt = new Date(y, m - 1, d);
  dt.setDate(dt.getDate() + days);
  const yy = dt.getFullYear();
  const mm = String(dt.getMonth() + 1).padStart(2, '0');
  const dd = String(dt.getDate()).padStart(2, '0');
  return `${yy}-${mm}-${dd}`;
}

/**
 * Normalize shift cell → { shift: 'I'|'II', remark: 'D'|'N' } or null.
 * Bulk import is strict: only I or II (case-insensitive). No D/N/1/2 aliases.
 */
export function normalizeShift(raw) {
  const text = String(raw || '')
    .trim()
    .toUpperCase();
  if (!text) return null;
  if (text === 'I') return { shift: 'I', remark: 'D' };
  if (text === 'II') return { shift: 'II', remark: 'N' };
  return null;
}

export function normalizeImportMode(raw) {
  const text = String(raw || '')
    .trim()
    .toLowerCase();
  if (text === 'in' || text === 'out' || text === 'both') return text;
  if (text === 'in+out' || text === 'inout' || text === 'in_out') return 'both';
  return null;
}

/**
 * Default finger times for Tanggal Hadir + shift.
 * Day: IN 06:30 / OUT 17:30 same day.
 * Night: IN 17:30 same day / OUT 06:30 next day.
 */
export function defaultFingerTimes(dateYmd, shift) {
  const night = String(shift || '').trim().toUpperCase() === 'II';
  if (!dateYmd || !/^\d{4}-\d{2}-\d{2}$/.test(dateYmd)) {
    return { finger_in: null, finger_out: null };
  }
  if (night) {
    const next = addDaysYmd(dateYmd, 1);
    return {
      finger_in: `${dateYmd} 17:30:00`,
      finger_out: next ? `${next} 06:30:00` : null,
    };
  }
  return {
    finger_in: `${dateYmd} 06:30:00`,
    finger_out: `${dateYmd} 17:30:00`,
  };
}

/**
 * Apply modal mode: fill missing times from defaults; drop fields outside mode.
 * @param {'in'|'out'|'both'} mode
 */
export function applyModeDefaults(row, mode) {
  const defaults = defaultFingerTimes(row.date, row.shift);
  let fingerIn = row.finger_in || null;
  let fingerOut = row.finger_out || null;

  if (mode === 'in') {
    fingerOut = null;
    if (!fingerIn) fingerIn = defaults.finger_in;
  } else if (mode === 'out') {
    fingerIn = null;
    if (!fingerOut) fingerOut = defaults.finger_out;
  } else {
    if (!fingerIn) fingerIn = defaults.finger_in;
    if (!fingerOut) fingerOut = defaults.finger_out;
  }

  return {
    ...row,
    finger_in: fingerIn,
    finger_out: fingerOut,
  };
}

/**
 * Parse spreadsheet. Columns (after header):
 * date, nrp, shift, location, description
 * full_name resolved from hr.v_workers_active by NRP on INSERT.
 * Category, mode, and finger times come from the import modal / defaults.
 */
export function parseFingerErrorSpreadsheet(buffer, originalName = '') {
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
  const matrix = XLSX.utils.sheet_to_json(sheet, {
    header: 1,
    defval: '',
    raw: false,
  });

  if (!Array.isArray(matrix) || matrix.length < 2) {
    return {
      rows: [],
      error: 'No data rows found. Include a header row and at least one data row.',
    };
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
    const excelRow = i + 2;
    const allEmpty = row.every((cell) => cellToString(cell) === '');
    if (allEmpty) continue;

    const date = parseDateCell(row[0]);
    const nrp = cellToString(row[1]).toUpperCase();
    const shiftRaw = cellToString(row[2]);
    const shiftNorm = normalizeShift(shiftRaw);
    const location = cellToString(row[3]) || null;
    const description = cellToString(row[4]) || null;

    rows.push({
      excelRow,
      date,
      nrp,
      full_name: null,
      shift_raw: shiftRaw || null,
      shift: shiftNorm?.shift || null,
      remark: shiftNorm?.remark || null,
      finger_in: null,
      finger_out: null,
      location,
      description,
      source: name,
    });
  }

  return { rows, error: null };
}

/**
 * .xlsx template for admin section.
 * Sheet 1 = data; sheet 2 = petunjuk (shift I/II wajib benar).
 */
export function buildFingerErrorExampleXlsx() {
  const dataRows = [
    ['date', 'nrp', 'shift', 'location', 'description'],
    ['2026-10-20', '0216691', 'I', '', 'Contoh siang — shift wajib huruf I'],
    ['2026-10-20', '0216692', 'II', '', 'Contoh malam — shift wajib huruf II'],
  ];
  const dataSheet = XLSX.utils.aoa_to_sheet(dataRows);
  for (let r = 2; r <= dataRows.length; r += 1) {
    const cell = dataSheet[`B${r}`];
    if (cell) {
      cell.t = 's';
      cell.v = String(cell.v ?? '');
      cell.z = '@';
    }
    const shiftCell = dataSheet[`C${r}`];
    if (shiftCell) {
      shiftCell.t = 's';
      shiftCell.v = String(shiftCell.v ?? '');
      shiftCell.z = '@';
    }
  }
  dataSheet['!cols'] = [
    { wch: 12 },
    { wch: 12 },
    { wch: 10 },
    { wch: 16 },
    { wch: 40 },
  ];

  const guideRows = [
    ['PETUNJUK IMPORT FINGERPRINT'],
    [''],
    ['Kolom wajib'],
    ['date', 'Tanggal hadir YYYY-MM-DD (contoh 2026-10-20)'],
    ['nrp', 'NRP karyawan aktif (nama diisi otomatis dari sistem)'],
    ['shift', 'HANYA boleh: I  atau  II'],
    [''],
    ['Kolom opsional'],
    ['location', 'Lokasi (boleh kosong)'],
    ['description', 'Keterangan (boleh kosong)'],
    [''],
    ['PENTING — kolom shift'],
    ['I', 'Shift siang (Day). Jam default IN 06:30 / OUT 17:30 hari yang sama.'],
    ['II', 'Shift malam (Night). Jam default IN 17:30 / OUT 06:30 keesokan hari.'],
    [''],
    ['Dilarang di kolom shift'],
    [
      'Jangan tulis',
      'D, N, Siang, Malam, 1, 2, day, night, atau teks lain. Baris akan ditolak.',
    ],
    [''],
    ['Kategori & mode finger'],
    [
      'Dipilih di aplikasi',
      'Saat upload: pilih kategori + mode IN / OUT / IN+OUT di modal (bukan di Excel).',
    ],
  ];
  const guideSheet = XLSX.utils.aoa_to_sheet(guideRows);
  guideSheet['!cols'] = [{ wch: 22 }, { wch: 72 }];

  const workbook = XLSX.utils.book_new();
  XLSX.utils.book_append_sheet(workbook, dataSheet, 'Fingerprint');
  XLSX.utils.book_append_sheet(workbook, guideSheet, 'Petunjuk');
  return XLSX.write(workbook, { type: 'buffer', bookType: 'xlsx' });
}

export const FINGER_ERROR_IMPORT_MAX_ROWS = MAX_ROWS;
