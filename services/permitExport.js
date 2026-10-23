import * as XLSX from 'xlsx';

const PROGRESS_LABEL = {
  '1': 'Waiting for approval Section',
  '2': 'Waiting for approval HR',
  '3': 'Rejected By Section Head',
  '4': 'Rejected By HR',
};

function text(value) {
  if (value == null) return '';
  return String(value).trim();
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

function toExportDateTime(value) {
  if (!value) return '';
  if (value instanceof Date && !Number.isNaN(value.getTime())) {
    const date = toExportDate(value);
    const hh = String(value.getHours()).padStart(2, '0');
    const mm = String(value.getMinutes()).padStart(2, '0');
    return `${date} ${hh}:${mm}`;
  }
  const raw = String(value).replace('T', ' ');
  const match = raw.match(/^(\d{4}-\d{2}-\d{2})[ T](\d{2}:\d{2})/);
  return match ? `${match[1]} ${match[2]}` : toExportDate(value);
}

function kelompokOf(workerSource) {
  return text(workerSource).toLowerCase() === 'vendor' ? 'LS' : 'SIS';
}

function scopeLabel(workerScope) {
  const scope = text(workerScope).toLowerCase();
  if (scope === 'ls') return 'Karyawan LS';
  if (scope === 'sis') return 'Karyawan SIS';
  if (scope === 'all') return 'SIS dan LS';
  return scope || '—';
}

function progressFilterLabel(progress) {
  const code = text(progress);
  if (!code || code === '0') return 'Semua status';
  return PROGRESS_LABEL[code] || code;
}

function typeFilterLabel(statusWorker) {
  const raw = text(statusWorker).toLowerCase();
  if (raw === 'vendor') return 'Karyawan LS';
  if (raw === 'sis') return 'Karyawan SIS';
  return 'Semua';
}

const DETAIL_HEADERS = [
  'NRP',
  'NAMA',
  'JABATAN',
  'DEPARTMENT',
  'SECTION',
  'KELOMPOK',
  'KATEGORI',
  'MULAI',
  'SELESAI',
  'HARI',
  'STATUS',
  'DIINPUT',
  'TGL INPUT',
  'ATASAN',
  'TGL ATASAN',
  'HR',
  'TGL HR',
  'CATATAN',
];

function detailRow(row) {
  const progress = text(row.progress);
  const hrApproved = text(row.by_approved_name);
  const rejectedByHr = progress === 'Rejected by HR';
  const atasanRole = text(row.by_checked_role);
  const atasanName = text(row.by_checked_name);
  const hrName = hrApproved || (rejectedByHr ? text(row.reject_by) : '');
  const hrWhen = hrApproved
    ? toExportDateTime(row.approved_at)
    : rejectedByHr
      ? toExportDateTime(row.reject_date)
      : '';
  const rejected = progress.startsWith('Rejected');
  const note = text(row.note) || (rejected ? text(row.description) : '');
  const atasanReject =
    progress.startsWith('Rejected by ') && !rejectedByHr
      ? [text(row.reject_by), toExportDateTime(row.reject_date)].filter(Boolean).join(' · ')
      : '';
  const catatan = [note, atasanReject].filter(Boolean).join(' — ');

  return [
    text(row.nrp),
    text(row.full_name),
    text(row.jabatan),
    text(row.department_name),
    text(row.section_name),
    kelompokOf(row.status_worker),
    text(row.category_name),
    toExportDate(row.start_date),
    toExportDate(row.end_date),
    row.day == null || row.day === '' ? '' : Number(row.day),
    progress,
    text(row.name_input),
    toExportDateTime(row.created_at),
    atasanName ? [atasanRole, atasanName].filter(Boolean).join(' · ') : '',
    toExportDateTime(row.by_date_verified_section),
    hrName ? (rejectedByHr && !hrApproved ? `${hrName} (menolak)` : hrName) : '',
    hrWhen,
    catatan,
  ];
}

function summarySheet(rows, meta) {
  const counts = new Map();
  for (const row of rows) {
    const label = text(row.progress) || 'Tanpa status';
    counts.set(label, (counts.get(label) || 0) + 1);
  }
  const preferred = [
    'Waiting approve by HR',
    'Approve by HR',
    'Rejected by HR',
  ];
  const labels = [
    ...preferred.filter((label) => counts.has(label)),
    ...[...counts.keys()]
      .filter((label) => !preferred.includes(label))
      .sort((a, b) => a.localeCompare(b)),
  ];

  const aoa = [
    ['Laporan Permit Personalia'],
    ['Bulan', meta.month || ''],
    ['Kelompok', scopeLabel(meta.workerScope)],
    ['Filter tipe karyawan', typeFilterLabel(meta.statusWorker)],
    ['Filter status', progressFilterLabel(meta.progress)],
    ['Jumlah baris', rows.length],
    [],
    ['STATUS', 'JUMLAH'],
  ];
  if (labels.length === 0) {
    aoa.push(['—', 0]);
  } else {
    for (const label of labels) {
      aoa.push([label, counts.get(label) || 0]);
    }
  }
  aoa.push(['TOTAL', rows.length]);

  const sheet = XLSX.utils.aoa_to_sheet(aoa);
  sheet['!cols'] = [{ wch: 42 }, { wch: 18 }];
  return sheet;
}

function detailSheet(rows) {
  const aoa = [DETAIL_HEADERS, ...rows.map(detailRow)];
  const sheet = XLSX.utils.aoa_to_sheet(aoa);
  sheet['!cols'] = [
    { wch: 12 },
    { wch: 28 },
    { wch: 22 },
    { wch: 22 },
    { wch: 24 },
    { wch: 10 },
    { wch: 18 },
    { wch: 22 },
    { wch: 22 },
    { wch: 36 },
    { wch: 12 },
    { wch: 12 },
    { wch: 12 },
    { wch: 8 },
    { wch: 28 },
    { wch: 24 },
    { wch: 18 },
    { wch: 32 },
    { wch: 18 },
    { wch: 32 },
    { wch: 18 },
    { wch: 40 },
  ];
  sheet['!autofilter'] = {
    ref: `A1:V${Math.max(aoa.length, 1)}`,
  };
  return sheet;
}

/** Two sheets: status summary, then one row per pengajuan. */
export function buildPermitHrExportXlsx(rows = [], meta = {}) {
  const list = Array.isArray(rows) ? rows : [];
  const workbook = XLSX.utils.book_new();
  XLSX.utils.book_append_sheet(workbook, summarySheet(list, meta), 'Ringkasan');
  XLSX.utils.book_append_sheet(workbook, detailSheet(list), 'Detail');
  return XLSX.write(workbook, { type: 'buffer', bookType: 'xlsx' });
}
