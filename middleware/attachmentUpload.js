import { randomUUID } from 'crypto';
import { extname, resolve } from 'path';
import { mkdirSync } from 'fs';
import multer from 'multer';

const uploadDirectory = resolve(process.env.UPLOAD_DIR || './uploads');
const maxFileSize = Number(process.env.MAX_FILE_SIZE) || 5 * 1024 * 1024;

const allowedMimeTypes = new Set([
  'application/pdf',
  'image/jpeg',
  'image/png',
  'image/webp',
  'text/plain',
  'application/msword',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'application/vnd.ms-excel',
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'application/zip',
]);

mkdirSync(uploadDirectory, { recursive: true });

const storage = multer.diskStorage({
  destination: (_req, _file, callback) => callback(null, uploadDirectory),
  filename: (_req, file, callback) => {
    const extension = extname(file.originalname).toLowerCase().slice(0, 10);
    callback(null, `${randomUUID()}${extension}`);
  },
});

const upload = multer({
  storage,
  limits: {
    fileSize: maxFileSize,
    files: 1,
  },
  fileFilter: (_req, file, callback) => {
    if (!allowedMimeTypes.has(file.mimetype)) {
      return callback(new multer.MulterError('LIMIT_UNEXPECTED_FILE', 'file'));
    }

    return callback(null, true);
  },
});

export const uploadDirectoryPath = uploadDirectory;

export const uploadSingleAttachment = (req, res, next) => {
  upload.single('file')(req, res, (error) => {
    if (!error) {
      return next();
    }

    const message =
      error.code === 'LIMIT_FILE_SIZE'
        ? `File exceeds the ${maxFileSize} byte limit.`
        : 'Invalid attachment file.';

    return res.status(400).json({ success: false, message });
  });
};

/** Sickness evidence: multi-file, jpg/jpeg/png/gif/pdf, 1MB each, max 5 (legacy). */
const sakitEvidenceMimes = new Set([
  'image/jpeg',
  'image/png',
  'image/gif',
  'application/pdf',
]);
const sakitMaxBytes = 1 * 1024 * 1024;
const sakitMaxFiles = 5;

const sakitStorage = multer.diskStorage({
  destination: (req, _file, callback) => {
    const now = new Date();
    const yyyy = String(now.getFullYear());
    const mm = String(now.getMonth() + 1).padStart(2, '0');
    const dest = resolve(uploadDirectory, 'sakit', yyyy, mm);
    mkdirSync(dest, { recursive: true });
    req.sakitUploadRelDir = `sakit/${yyyy}/${mm}`;
    callback(null, dest);
  },
  filename: (req, file, callback) => {
    const extension = extname(file.originalname).toLowerCase().slice(0, 10);
    req.sakitFileSeq = (req.sakitFileSeq || 0) + 1;
    const now = new Date();
    const pad = (value) => String(value).padStart(2, '0');
    const stamp = `${now.getFullYear()}${pad(now.getMonth() + 1)}${pad(now.getDate())}-${pad(now.getHours())}${pad(now.getMinutes())}${pad(now.getSeconds())}`;
    const nrp = String(req.body?.nrp || '')
      .replace(/[^\w.-]+/g, '')
      .slice(0, 24);
    const parts = ['sakit', nrp, stamp, String(req.sakitFileSeq)].filter(Boolean);
    callback(null, `${parts.join('_')}${extension}`);
  },
});

const sakitUpload = multer({
  storage: sakitStorage,
  limits: {
    fileSize: sakitMaxBytes,
    files: sakitMaxFiles,
  },
  fileFilter: (_req, file, callback) => {
    if (!sakitEvidenceMimes.has(file.mimetype)) {
      return callback(new multer.MulterError('LIMIT_UNEXPECTED_FILE', 'files'));
    }
    return callback(null, true);
  },
});

export const uploadSicknessEvidence = (req, res, next) => {
  sakitUpload.array('files', sakitMaxFiles)(req, res, (error) => {
    if (!error) {
      return next();
    }

    let message = 'Invalid evidence file.';
    if (error.code === 'LIMIT_FILE_SIZE') {
      message = 'Each evidence file must be at most 1MB.';
    } else if (error.code === 'LIMIT_FILE_COUNT' || error.code === 'LIMIT_UNEXPECTED_FILE') {
      message = 'Evidence must be jpg/jpeg/png/gif/pdf, max 5 files.';
    }

    return res.status(400).json({ success: false, message });
  });
};

/** Permit evidence: same limits as sickness, stored under uploads/ijin. */
const ijinStorage = multer.diskStorage({
  destination: (req, _file, callback) => {
    const now = new Date();
    const yyyy = String(now.getFullYear());
    const mm = String(now.getMonth() + 1).padStart(2, '0');
    const dest = resolve(uploadDirectory, 'ijin', yyyy, mm);
    mkdirSync(dest, { recursive: true });
    req.ijinUploadRelDir = `ijin/${yyyy}/${mm}`;
    callback(null, dest);
  },
  filename: (req, file, callback) => {
    const extension = extname(file.originalname).toLowerCase().slice(0, 10);
    req.ijinFileSeq = (req.ijinFileSeq || 0) + 1;
    const now = new Date();
    const pad = (value) => String(value).padStart(2, '0');
    const stamp = `${now.getFullYear()}${pad(now.getMonth() + 1)}${pad(now.getDate())}-${pad(now.getHours())}${pad(now.getMinutes())}${pad(now.getSeconds())}`;
    const nrp = String(req.body?.nrp || '')
      .replace(/[^\w.-]+/g, '')
      .slice(0, 24);
    const parts = ['ijin', nrp, stamp, String(req.ijinFileSeq)].filter(Boolean);
    callback(null, `${parts.join('_')}${extension}`);
  },
});

const ijinUpload = multer({
  storage: ijinStorage,
  limits: {
    fileSize: sakitMaxBytes,
    files: sakitMaxFiles,
  },
  fileFilter: (_req, file, callback) => {
    if (!sakitEvidenceMimes.has(file.mimetype)) {
      return callback(new multer.MulterError('LIMIT_UNEXPECTED_FILE', 'files'));
    }
    return callback(null, true);
  },
});

export const uploadPermitEvidence = (req, res, next) => {
  ijinUpload.array('files', sakitMaxFiles)(req, res, (error) => {
    if (!error) {
      return next();
    }

    let message = 'Invalid evidence file.';
    if (error.code === 'LIMIT_FILE_SIZE') {
      message = 'Each evidence file must be at most 1MB.';
    } else if (error.code === 'LIMIT_FILE_COUNT' || error.code === 'LIMIT_UNEXPECTED_FILE') {
      message = 'Evidence must be jpg/jpeg/png/gif/pdf, max 5 files.';
    }

    return res.status(400).json({ success: false, message });
  });
};

/** Fingerprint evidence: same limits as sickness, stored under uploads/finger-error. */
const fingerErrorStorage = multer.diskStorage({
  destination: (req, _file, callback) => {
    const now = new Date();
    const yyyy = String(now.getFullYear());
    const mm = String(now.getMonth() + 1).padStart(2, '0');
    const dest = resolve(uploadDirectory, 'finger-error', yyyy, mm);
    mkdirSync(dest, { recursive: true });
    req.fingerErrorUploadRelDir = `finger-error/${yyyy}/${mm}`;
    callback(null, dest);
  },
  filename: (req, file, callback) => {
    const extension = extname(file.originalname).toLowerCase().slice(0, 10);
    req.fingerErrorFileSeq = (req.fingerErrorFileSeq || 0) + 1;
    const now = new Date();
    const pad = (value) => String(value).padStart(2, '0');
    const stamp = `${now.getFullYear()}${pad(now.getMonth() + 1)}${pad(now.getDate())}-${pad(now.getHours())}${pad(now.getMinutes())}${pad(now.getSeconds())}`;
    const nrp = String(req.body?.nrp || '')
      .replace(/[^\w.-]+/g, '')
      .slice(0, 24);
    const parts = ['finger-error', nrp, stamp, String(req.fingerErrorFileSeq)].filter(Boolean);
    callback(null, `${parts.join('_')}${extension}`);
  },
});

const fingerErrorUpload = multer({
  storage: fingerErrorStorage,
  limits: {
    fileSize: sakitMaxBytes,
    files: sakitMaxFiles,
  },
  fileFilter: (_req, file, callback) => {
    if (!sakitEvidenceMimes.has(file.mimetype)) {
      return callback(new multer.MulterError('LIMIT_UNEXPECTED_FILE', 'files'));
    }
    return callback(null, true);
  },
});

export const uploadFingerErrorEvidence = (req, res, next) => {
  fingerErrorUpload.array('files', sakitMaxFiles)(req, res, (error) => {
    if (!error) {
      return next();
    }

    let message = 'Invalid evidence file.';
    if (error.code === 'LIMIT_FILE_SIZE') {
      message = 'Each evidence file must be at most 1MB.';
    } else if (error.code === 'LIMIT_FILE_COUNT' || error.code === 'LIMIT_UNEXPECTED_FILE') {
      message = 'Evidence must be jpg/jpeg/png/gif/pdf, max 5 files.';
    }

    return res.status(400).json({ success: false, message });
  });
};
