import multer from 'multer';

const maxFileSize = Number(process.env.MAX_EXCEL_SIZE) || 10 * 1024 * 1024;

const allowedMimeTypes = new Set([
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'application/vnd.ms-excel',
  'text/csv',
  'application/csv',
  'text/plain',
  'application/octet-stream',
]);

const allowedExt = new Set(['.xlsx', '.xls', '.csv']);

const upload = multer({
  storage: multer.memoryStorage(),
  limits: {
    fileSize: maxFileSize,
    files: 1,
  },
  fileFilter: (_req, file, callback) => {
    const name = String(file.originalname || '').toLowerCase();
    const ext = name.includes('.') ? `.${name.split('.').pop()}` : '';
    if (!allowedExt.has(ext) && !allowedMimeTypes.has(file.mimetype)) {
      return callback(new multer.MulterError('LIMIT_UNEXPECTED_FILE', 'file'));
    }
    return callback(null, true);
  },
});

/** Multipart field name: `file` (xlsx / xls / csv). */
export const uploadExcelFile = (req, res, next) => {
  upload.single('file')(req, res, (error) => {
    if (!error) return next();

    const message =
      error.code === 'LIMIT_FILE_SIZE'
        ? `File exceeds the ${maxFileSize} byte limit.`
        : 'Invalid spreadsheet file. Use .xlsx, .xls, or .csv.';

    return res.status(400).json({ success: false, message });
  });
};
