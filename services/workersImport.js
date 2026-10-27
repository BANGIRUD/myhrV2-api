import * as XLSX from 'xlsx';

const MAX_ROWS = 2000;

/** Excel serial date → YYYY-MM-DD */
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
  if (typeof value === 'number') return excelSerialToIso(value);
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

function upperOrNull(value) {
  const s = cellToString(value);
  return s ? s.toUpperCase() : null;
}

/** SIS columns (legacy import order). */
export const WORKERS_SIS_HEADERS = [
  'nrp',
  'full_name',
  'jabatan',
  'department',
  'section',
  'status',
  'level_jabatan',
  'klasifikasi_jabatan',
  'job_rank',
  'grade',
  'area_kerja',
  'status_karyawan',
  'lokasi_kerja',
  'staff_nonstaff',
  'poh',
  'tanggal_masuk',
  'tanggal_akhirkontrak',
  'tanggal_efektif_diadaro',
  'tempat_lahir',
  'kabupaten_lahir',
  'provinsi_lahir',
  'tanggal_lahir',
  'pendidikan',
  'nama_sekolah',
  'jurusan',
  'no_ijasah',
  'tanggal_masuk_sekolah',
  'tanggal_lulus_sekolah',
  'agama',
  'suku',
  'golongan_darah',
  'direct_indirect',
  'remark',
];

/** LS columns (legacy import order + grade at end for export parity). */
export const WORKERS_LS_HEADERS = [
  'nrp',
  'full_name',
  'jabatan',
  'job_rank',
  'section',
  'department',
  'area_kerja',
  'status_karyawan',
  'status',
  'lokasi_kerja',
  'tanggal_masuk',
  'tempat_lahir',
  'tanggal_lahir',
  'pendidikan',
  'agama',
  'gender',
  'status_keluarga',
  'alamat',
  'id_finger',
  'vendor',
  'grade',
];

/**
 * Parse uploaded buffer into worker import rows.
 * @param {'sis'|'vendor'} source
 */
export function parseWorkersSpreadsheet(buffer, originalName = '', source = 'sis') {
  const src = source === 'vendor' ? 'vendor' : 'sis';
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

    if (src === 'sis') {
      rows.push({
        excelRow,
        source: src,
        nrp: upperOrNull(row[0]) || '',
        full_name: upperOrNull(row[1]) || '',
        jabatan: upperOrNull(row[2]),
        department: upperOrNull(row[3]),
        section: upperOrNull(row[4]),
        status: upperOrNull(row[5]),
        level_jabatan: upperOrNull(row[6]),
        klasifikasi_jabatan: upperOrNull(row[7]),
        job_rank: upperOrNull(row[8]),
        grade: upperOrNull(row[9]),
        area_kerja: upperOrNull(row[10]),
        status_karyawan: upperOrNull(row[11]),
        lokasi_kerja: upperOrNull(row[12]),
        staff_nonstaff: upperOrNull(row[13]),
        poh: upperOrNull(row[14]),
        tanggal_masuk: parseDateCell(row[15]),
        tanggal_akhirkontrak: parseDateCell(row[16]),
        tanggal_efektif_diadaro: parseDateCell(row[17]),
        tempat_lahir: upperOrNull(row[18]),
        kabupaten_lahir: upperOrNull(row[19]),
        provinsi_lahir: upperOrNull(row[20]),
        tanggal_lahir: parseDateCell(row[21]),
        pendidikan: upperOrNull(row[22]),
        nama_sekolah: upperOrNull(row[23]),
        jurusan: upperOrNull(row[24]),
        no_ijasah: upperOrNull(row[25]),
        tanggal_masuk_sekolah: parseDateCell(row[26]),
        tanggal_lulus_sekolah: parseDateCell(row[27]),
        agama: upperOrNull(row[28]),
        suku: upperOrNull(row[29]),
        golongan_darah: upperOrNull(row[30]),
        direct_indirect: upperOrNull(row[31]),
        remark: upperOrNull(row[32]),
        file: originalName,
      });
    } else {
      rows.push({
        excelRow,
        source: src,
        nrp: upperOrNull(row[0]) || '',
        full_name: upperOrNull(row[1]) || '',
        jabatan: upperOrNull(row[2]),
        job_rank: upperOrNull(row[3]),
        section: upperOrNull(row[4]),
        department: upperOrNull(row[5]),
        area_kerja: upperOrNull(row[6]),
        status_karyawan: upperOrNull(row[7]),
        status: upperOrNull(row[8]),
        lokasi_kerja: upperOrNull(row[9]),
        tanggal_masuk: parseDateCell(row[10]),
        tempat_lahir: upperOrNull(row[11]),
        tanggal_lahir: parseDateCell(row[12]),
        pendidikan: upperOrNull(row[13]),
        agama: upperOrNull(row[14]),
        gender: upperOrNull(row[15]),
        status_keluarga: upperOrNull(row[16]),
        alamat: cellToString(row[17]) || null,
        id_finger: cellToString(row[18]) || null,
        vendor: upperOrNull(row[19]),
        grade: upperOrNull(row[20]),
        file: originalName,
      });
    }
  }

  return { rows, error: null };
}

export function buildWorkersExampleXlsx(source = 'sis') {
  const src = source === 'vendor' ? 'vendor' : 'sis';
  const headers = src === 'sis' ? WORKERS_SIS_HEADERS : WORKERS_LS_HEADERS;
  const sample =
    src === 'sis'
      ? [
          '0216999',
          'EXAMPLE NAME',
          'OPERATOR',
          'OPERATION',
          'HAULING',
          'ACTIVE',
          '',
          '',
          'OPERATOR',
          '',
          'AREA 1',
          'PKWT',
          'HAULING',
          'NONSTAFF',
          'BANJARMASIN',
          '2026-01-01',
          '',
          '',
          'BANJARMASIN',
          '',
          '',
          '1990-01-01',
          'SMA',
          '',
          '',
          '',
          '',
          '',
          'ISLAM',
          '',
          '',
          'DIRECT',
          '',
        ]
      : [
          'LS99901',
          'EXAMPLE VENDOR',
          'HELPER',
          'HELPER',
          'HAULING',
          'OPERATION',
          'AREA 1',
          'PKWT',
          'ACTIVE',
          'HAULING',
          '2026-01-01',
          'BANJARMASIN',
          '1990-01-01',
          'SMA',
          'ISLAM',
          'L',
          'TK',
          'JL EXAMPLE',
          'FINGER001',
          'VENDOR01',
          '',
        ];

  const sheet = XLSX.utils.aoa_to_sheet([headers, sample]);
  sheet['!cols'] = headers.map(() => ({ wch: 16 }));
  const workbook = XLSX.utils.book_new();
  XLSX.utils.book_append_sheet(
    workbook,
    sheet,
    src === 'sis' ? 'Employees SIS' : 'Employees LS',
  );
  return XLSX.write(workbook, { type: 'buffer', bookType: 'xlsx' });
}

export const WORKERS_IMPORT_MAX_ROWS = MAX_ROWS;
