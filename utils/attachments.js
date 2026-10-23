import { basename, resolve, sep } from 'path';
import { unlink } from 'fs/promises';
import { uploadDirectoryPath } from '../middleware/attachmentUpload.js';

export function resolveAttachmentPath(storedName) {
  if (!storedName || basename(storedName) !== storedName) {
    return null;
  }

  const filePath = resolve(uploadDirectoryPath, storedName);
  const directoryPrefix = `${resolve(uploadDirectoryPath)}${sep}`;
  return filePath.startsWith(directoryPrefix) ? filePath : null;
}

export async function removeAttachmentFile(storedName) {
  const filePath = resolveAttachmentPath(storedName);
  if (!filePath) return;

  try {
    await unlink(filePath);
  } catch (error) {
    if (error.code !== 'ENOENT') {
      console.error('Failed to remove attachment file:', error.message);
    }
  }
}
