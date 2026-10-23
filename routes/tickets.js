import express from 'express';
import { verifyToken } from '../middleware/auth.js';
import { enforceApiPermission } from '../middleware/apiPermission.js';
import {
  executeTicketAttachmentsSP,
  executeTicketRepliesSP,
  executeTicketsSP,
} from '../controllers/tickets.js';
import { uploadSingleAttachment } from '../middleware/attachmentUpload.js';
import {
  removeAttachmentFile,
  resolveAttachmentPath,
} from '../utils/attachments.js';
import { executeUsersSP } from '../controllers/users.js';

const router = express.Router();
const protect = [verifyToken, enforceApiPermission];
const isValidId = (value) => /^\d+$/.test(String(value));
const context = (req) => ({
  BY_USER: req.user.id,
  BY_JOBSITE: req.user.by_jobsite,
});

const serverError = (res, error) =>
  res.status(500).json({
    success: false,
    message: 'Server error',
    ...(process.env.NODE_ENV === 'development' && { error: error.message }),
  });

const ensureStaffTicket = async (req, res, next) => {
  if (!isValidId(req.params.id)) {
    return res.status(400).json({ success: false, message: 'Invalid ticket id.' });
  }

  try {
    const result = await executeTicketsSP('GET', {
      ID: Number(req.params.id),
      ...context(req),
    });
    const ticket = result.recordset?.[0];

    if (!ticket) {
      return res.status(404).json({ success: false, message: 'Ticket not found.' });
    }

    req.ticket = ticket;
    return next();
  } catch (error) {
    return serverError(res, error);
  }
};

router.get('/', ...protect, async (req, res) => {
  try {
    const result = await executeTicketsSP('SELECT', {
      STATUS_ID: req.query.status_id || null,
      PRIORITY_ID: req.query.priority_id || null,
      CATEGORY_ID: req.query.category_id || null,
      OWNER_USER_ID: req.query.owner_user_id || null,
      SEARCH: req.query.q?.trim() || null,
      PAGE: Number(req.query.page) || 1,
      PAGE_SIZE: Number(req.query.page_size) || 20,
      ...context(req),
    });

    return res.json({
      success: true,
      message: 'Fetched tickets successfully.',
      data: result.recordsets?.[0] ?? [],
      meta: { total: result.recordsets?.[1]?.[0]?.total_count ?? 0 },
    });
  } catch (error) {
    return serverError(res, error);
  }
});

router.get('/assignees', ...protect, async (req, res) => {
  try {
    const result = await executeUsersSP('SELECT', {
      IS_ACTIVE: true,
      PAGE: 1,
      PAGE_SIZE: 0,
      ...context(req),
    });

    return res.json({
      success: true,
      message: 'Fetched ticket assignees successfully.',
      data: result.recordsets?.[0] ?? result.recordset ?? [],
    });
  } catch (error) {
    return serverError(res, error);
  }
});

router.get('/:id', ...protect, async (req, res) => {
  if (!isValidId(req.params.id)) {
    return res.status(400).json({ success: false, message: 'Invalid ticket id.' });
  }

  try {
    const parameters = { ID: Number(req.params.id), ...context(req) };
    const ticketResult = await executeTicketsSP('GET', parameters);
    const ticket = ticketResult.recordset?.[0];

    if (!ticket) {
      return res.status(404).json({ success: false, message: 'Ticket not found.' });
    }

    const [repliesResult, attachmentsResult] = await Promise.all([
      executeTicketRepliesSP('SELECT', {
        TICKET_ID: ticket.id,
        ...context(req),
      }),
      executeTicketAttachmentsSP('SELECT', {
        TICKET_ID: ticket.id,
        ...context(req),
      }),
    ]);

    return res.json({
      success: true,
      message: 'Fetched ticket successfully.',
      data: {
        ...ticket,
        replies: repliesResult.recordset ?? [],
        attachments: attachmentsResult.recordset ?? [],
      },
    });
  } catch (error) {
    return serverError(res, error);
  }
});

router.post('/', ...protect, async (req, res) => {
  const {
    email,
    customer_name,
    customer_phone,
    category_id,
    priority_id,
    status_id,
    subject,
    message,
    owner_user_id,
    due_date,
  } = req.body || {};

  if (!email || !customer_name || !category_id || !subject || !message) {
    return res.status(400).json({
      success: false,
      message: 'Email, customer name, category, subject, and message are required.',
    });
  }

  try {
    const result = await executeTicketsSP('INSERT', {
      EMAIL: email.trim().toLowerCase(),
      CUSTOMER_NAME: customer_name.trim(),
      CUSTOMER_PHONE: customer_phone || null,
      CATEGORY_ID: category_id,
      PRIORITY_ID: priority_id || null,
      STATUS_ID: status_id || null,
      SUBJECT: subject.trim(),
      MESSAGE: message.trim(),
      OWNER_USER_ID: owner_user_id || null,
      DUE_DATE: due_date || null,
      ...context(req),
    });
    const response = result.recordset?.[0];

    return res.status(response?.success ? 201 : 400).json({
      success: Boolean(response?.success),
      message: response?.message || 'Failed to create ticket.',
      ...(response?.success && {
        data: { id: response.id, tracking_id: response.tracking_id },
      }),
    });
  } catch (error) {
    return serverError(res, error);
  }
});

router.put('/:id', ...protect, async (req, res) => {
  if (!isValidId(req.params.id)) {
    return res.status(400).json({ success: false, message: 'Invalid ticket id.' });
  }

  const {
    category_id,
    priority_id,
    status_id,
    subject,
    owner_user_id,
    due_date,
  } = req.body || {};

  try {
    const result = await executeTicketsSP('UPDATE', {
      ID: Number(req.params.id),
      CATEGORY_ID: category_id || null,
      PRIORITY_ID: priority_id || null,
      STATUS_ID: status_id || null,
      SUBJECT: subject || null,
      OWNER_USER_ID: owner_user_id || null,
      DUE_DATE: due_date || null,
      ...context(req),
    });
    const response = result.recordset?.[0];

    return res.status(response?.success ? 200 : 400).json({
      success: Boolean(response?.success),
      message: response?.message || 'Failed to update ticket.',
    });
  } catch (error) {
    return serverError(res, error);
  }
});

router.delete('/:id', ...protect, async (req, res) => {
  if (!isValidId(req.params.id)) {
    return res.status(400).json({ success: false, message: 'Invalid ticket id.' });
  }

  try {
    const result = await executeTicketsSP('DELETE', {
      ID: Number(req.params.id),
      ...context(req),
    });
    const response = result.recordset?.[0];

    return res.status(response?.success ? 200 : 400).json({
      success: Boolean(response?.success),
      message: response?.message || 'Failed to delete ticket.',
    });
  } catch (error) {
    return serverError(res, error);
  }
});

router.post('/:id/replies', ...protect, async (req, res) => {
  if (!isValidId(req.params.id) || !req.body?.message?.trim()) {
    return res.status(400).json({
      success: false,
      message: 'Valid ticket id and message are required.',
    });
  }

  try {
    // GET enforces staff jobsite ownership before inserting the reply.
    const ticketResult = await executeTicketsSP('GET', {
      ID: Number(req.params.id),
      ...context(req),
    });
    if (!ticketResult.recordset?.[0]) {
      return res.status(404).json({ success: false, message: 'Ticket not found.' });
    }

    const result = await executeTicketRepliesSP('INSERT', {
      TICKET_ID: Number(req.params.id),
      SENDER_TYPE: 'staff',
      USER_ID: req.user.id,
      MESSAGE: req.body.message.trim(),
      ...context(req),
    });
    const response = result.recordset?.[0];

    return res.status(response?.success ? 201 : 400).json({
      success: Boolean(response?.success),
      message: response?.message || 'Failed to save reply.',
      ...(response?.success && { data: { id: response.id } }),
    });
  } catch (error) {
    return serverError(res, error);
  }
});

router.post(
  '/:id/attachments',
  ...protect,
  ensureStaffTicket,
  uploadSingleAttachment,
  async (req, res) => {
    if (!req.file) {
      return res.status(400).json({
        success: false,
        message: 'Attachment file is required.',
      });
    }

    try {
      const result = await executeTicketAttachmentsSP('INSERT', {
        TICKET_ID: req.ticket.id,
        REPLY_ID: req.body?.reply_id || null,
        FILE_NAME: req.file.originalname,
        STORED_NAME: req.file.filename,
        MIME_TYPE: req.file.mimetype,
        FILE_SIZE: req.file.size,
        UPLOADED_BY_TYPE: 'staff',
        ...context(req),
      });
      const response = result.recordset?.[0];

      if (!response?.success) {
        await removeAttachmentFile(req.file.filename);
        return res.status(400).json({
          success: false,
          message: response?.message || 'Failed to save attachment.',
        });
      }

      return res.status(201).json({
        success: true,
        message: response.message,
        data: {
          id: response.id,
          file_name: req.file.originalname,
          mime_type: req.file.mimetype,
          file_size: req.file.size,
        },
      });
    } catch (error) {
      await removeAttachmentFile(req.file.filename);
      return serverError(res, error);
    }
  },
);

router.get('/attachments/:id/download', ...protect, async (req, res) => {
  if (!isValidId(req.params.id)) {
    return res.status(400).json({
      success: false,
      message: 'Invalid attachment id.',
    });
  }

  try {
    const result = await executeTicketAttachmentsSP('GET', {
      ID: Number(req.params.id),
      ...context(req),
    });
    const attachment = result.recordset?.[0];
    const filePath = resolveAttachmentPath(attachment?.stored_name);

    if (!attachment || !filePath) {
      return res.status(404).json({
        success: false,
        message: 'Attachment not found.',
      });
    }

    return res.download(filePath, attachment.file_name, (error) => {
      if (error && !res.headersSent) {
        serverError(res, error);
      }
    });
  } catch (error) {
    return serverError(res, error);
  }
});

router.delete('/attachments/:id', ...protect, async (req, res) => {
  if (!isValidId(req.params.id)) {
    return res.status(400).json({
      success: false,
      message: 'Invalid attachment id.',
    });
  }

  try {
    const parameters = {
      ID: Number(req.params.id),
      ...context(req),
    };
    const getResult = await executeTicketAttachmentsSP('GET', parameters);
    const attachment = getResult.recordset?.[0];
    if (!attachment) {
      return res.status(404).json({
        success: false,
        message: 'Attachment not found.',
      });
    }

    const result = await executeTicketAttachmentsSP('DELETE', parameters);
    const response = result.recordset?.[0];

    if (response?.success) {
      await removeAttachmentFile(attachment.stored_name);
    }

    return res.status(response?.success ? 200 : 400).json({
      success: Boolean(response?.success),
      message: response?.message || 'Failed to delete attachment.',
    });
  } catch (error) {
    return serverError(res, error);
  }
});

export default router;
