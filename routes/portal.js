import express from 'express';
import { rateLimit } from 'express-rate-limit';
import { executeEnumsSP } from '../controllers/enums.js';
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

const router = express.Router();
const emailPattern = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const publicJobsiteId = process.env.PUBLIC_JOBSITE_ID
  ? Number(process.env.PUBLIC_JOBSITE_ID)
  : null;

router.use(
  rateLimit({
    windowMs: 15 * 60 * 1000,
    limit: 60,
    standardHeaders: 'draft-8',
    legacyHeaders: false,
    message: {
      success: false,
      message: 'Too many requests. Please try again later.',
    },
  }),
);

const submitLimiter = rateLimit({
  windowMs: 60 * 60 * 1000,
  limit: 10,
  standardHeaders: 'draft-8',
  legacyHeaders: false,
  message: {
    success: false,
    message: 'Too many tickets submitted. Please try again later.',
  },
});

const serverError = (res, error) =>
  res.status(500).json({
    success: false,
    message: 'Server error',
    ...(process.env.NODE_ENV === 'development' && { error: error.message }),
  });

async function findOwnedTicket(trackingId, email) {
  if (!trackingId || !email || !emailPattern.test(email)) {
    return null;
  }

  const result = await executeTicketsSP('GET_BY_TRACKING', {
    TRACKING_ID: trackingId.trim().toUpperCase(),
    EMAIL: email.trim().toLowerCase(),
    BY_JOBSITE: publicJobsiteId,
  });

  const first = result.recordset?.[0];
  return first?.success === false ? null : first;
}

router.get('/options', async (_req, res) => {
  try {
    const [categoryResult, priorityResult] = await Promise.all([
      executeEnumsSP('SELECT', {
        TYPE: 'ticket_category',
        PAGE: 1,
        PAGE_SIZE: 0,
        BY_JOBSITE: publicJobsiteId,
      }),
      executeEnumsSP('SELECT', {
        TYPE: 'ticket_priority',
        PAGE: 1,
        PAGE_SIZE: 0,
        BY_JOBSITE: publicJobsiteId,
      }),
    ]);

    return res.json({
      success: true,
      message: 'Fetched ticket options successfully.',
      data: {
        categories: categoryResult.recordsets?.[0] ?? [],
        priorities: priorityResult.recordsets?.[0] ?? [],
      },
    });
  } catch (error) {
    return serverError(res, error);
  }
});

router.post('/tickets', submitLimiter, async (req, res) => {
  const {
    email,
    name,
    phone,
    category_id,
    priority_id,
    subject,
    message,
  } = req.body || {};

  if (
    !emailPattern.test(email || '') ||
    !name?.trim() ||
    !category_id ||
    !subject?.trim() ||
    !message?.trim()
  ) {
    return res.status(400).json({
      success: false,
      message: 'Valid email, name, category, subject, and message are required.',
    });
  }

  if (name.length > 150 || subject.length > 255 || message.length > 10000) {
    return res.status(400).json({
      success: false,
      message: 'One or more fields exceed the allowed length.',
    });
  }

  try {
    const result = await executeTicketsSP('INSERT', {
      EMAIL: email.trim().toLowerCase(),
      CUSTOMER_NAME: name.trim(),
      CUSTOMER_PHONE: phone?.trim() || null,
      CATEGORY_ID: category_id,
      PRIORITY_ID: priority_id || null,
      SUBJECT: subject.trim(),
      MESSAGE: message.trim(),
      BY_USER: null,
      BY_JOBSITE: publicJobsiteId,
    });
    const response = result.recordset?.[0];

    return res.status(response?.success ? 201 : 400).json({
      success: Boolean(response?.success),
      message: response?.message || 'Failed to create ticket.',
      ...(response?.success && {
        data: { tracking_id: response.tracking_id },
      }),
    });
  } catch (error) {
    return serverError(res, error);
  }
});

// POST avoids exposing customer email in URL/query logs.
router.post('/tickets/lookup', async (req, res) => {
  try {
    const ticket = await findOwnedTicket(req.body?.tracking_id, req.body?.email);
    if (!ticket) {
      return res.status(404).json({
        success: false,
        message: 'Ticket not found.',
      });
    }

    const [repliesResult, attachmentsResult] = await Promise.all([
      executeTicketRepliesSP('SELECT', { TICKET_ID: ticket.id }),
      executeTicketAttachmentsSP('SELECT', { TICKET_ID: ticket.id }),
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

router.post('/tickets/:trackingId/replies', async (req, res) => {
  const { email, message } = req.body || {};
  if (!message?.trim() || message.length > 10000) {
    return res.status(400).json({
      success: false,
      message: 'A valid message is required.',
    });
  }

  try {
    const ticket = await findOwnedTicket(req.params.trackingId, email);
    if (!ticket) {
      return res.status(404).json({
        success: false,
        message: 'Ticket not found.',
      });
    }

    const result = await executeTicketRepliesSP('INSERT', {
      TICKET_ID: ticket.id,
      SENDER_TYPE: 'customer',
      CUSTOMER_ID: ticket.customer_id,
      MESSAGE: message.trim(),
      BY_USER: null,
      BY_JOBSITE: ticket.by_jobsite,
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
  '/tickets/:trackingId/attachments',
  submitLimiter,
  uploadSingleAttachment,
  async (req, res) => {
    if (!req.file) {
      return res.status(400).json({
        success: false,
        message: 'Attachment file is required.',
      });
    }

    try {
      const ticket = await findOwnedTicket(req.params.trackingId, req.body?.email);
      if (!ticket) {
        await removeAttachmentFile(req.file.filename);
        return res.status(404).json({
          success: false,
          message: 'Ticket not found.',
        });
      }

      const result = await executeTicketAttachmentsSP('INSERT', {
        TICKET_ID: ticket.id,
        REPLY_ID: req.body?.reply_id || null,
        FILE_NAME: req.file.originalname,
        STORED_NAME: req.file.filename,
        MIME_TYPE: req.file.mimetype,
        FILE_SIZE: req.file.size,
        UPLOADED_BY_TYPE: 'customer',
        BY_USER: null,
        BY_JOBSITE: ticket.by_jobsite,
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

router.post(
  '/tickets/:trackingId/attachments/:attachmentId/download',
  async (req, res) => {
    if (!/^\d+$/.test(String(req.params.attachmentId))) {
      return res.status(400).json({
        success: false,
        message: 'Invalid attachment id.',
      });
    }

    try {
      const ticket = await findOwnedTicket(req.params.trackingId, req.body?.email);
      if (!ticket) {
        return res.status(404).json({
          success: false,
          message: 'Attachment not found.',
        });
      }

      const result = await executeTicketAttachmentsSP('GET', {
        ID: Number(req.params.attachmentId),
        BY_JOBSITE: ticket.by_jobsite,
      });
      const attachment = result.recordset?.[0];
      const filePath = resolveAttachmentPath(attachment?.stored_name);

      if (!attachment || attachment.ticket_id !== ticket.id || !filePath) {
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
  },
);

export default router;
