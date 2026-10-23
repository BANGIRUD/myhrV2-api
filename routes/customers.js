import express from 'express';
import { executeCustomersSP } from '../controllers/customers.js';
import { verifyToken } from '../middleware/auth.js';
import { enforceApiPermission } from '../middleware/apiPermission.js';

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

router.get('/', ...protect, async (req, res) => {
  try {
    const result = await executeCustomersSP('SELECT', {
      SEARCH: req.query.q?.trim() || null,
      PAGE: Number(req.query.page) || 1,
      PAGE_SIZE: Number(req.query.page_size) || 20,
      ...context(req),
    });

    return res.json({
      success: true,
      message: 'Fetched customers successfully.',
      data: result.recordsets?.[0] ?? [],
      meta: { total: result.recordsets?.[1]?.[0]?.total_count ?? 0 },
    });
  } catch (error) {
    return serverError(res, error);
  }
});

router.get('/:id', ...protect, async (req, res) => {
  if (!isValidId(req.params.id)) {
    return res.status(400).json({ success: false, message: 'Invalid customer id.' });
  }

  try {
    const result = await executeCustomersSP('GET', {
      ID: Number(req.params.id),
      ...context(req),
    });
    const customer = result.recordset?.[0];

    if (!customer) {
      return res.status(404).json({ success: false, message: 'Customer not found.' });
    }

    return res.json({
      success: true,
      message: 'Fetched customer successfully.',
      data: customer,
    });
  } catch (error) {
    return serverError(res, error);
  }
});

router.post('/', ...protect, async (req, res) => {
  const { email, name, phone, is_verified } = req.body || {};
  if (!email || !name) {
    return res.status(400).json({
      success: false,
      message: 'Email and name are required.',
    });
  }

  try {
    const result = await executeCustomersSP('INSERT', {
      EMAIL: email.trim().toLowerCase(),
      NAME: name.trim(),
      PHONE: phone || null,
      IS_VERIFIED: is_verified ?? false,
      ...context(req),
    });
    const response = result.recordset?.[0];

    return res.status(response?.success ? 201 : 400).json({
      success: Boolean(response?.success),
      message: response?.message || 'Failed to save customer.',
      ...(response?.success && { data: { id: response.id } }),
    });
  } catch (error) {
    return serverError(res, error);
  }
});

router.put('/:id', ...protect, async (req, res) => {
  if (!isValidId(req.params.id)) {
    return res.status(400).json({ success: false, message: 'Invalid customer id.' });
  }

  const { email, name, phone, is_verified } = req.body || {};

  try {
    const result = await executeCustomersSP('UPDATE', {
      ID: Number(req.params.id),
      EMAIL: email?.trim().toLowerCase() || null,
      NAME: name?.trim() || null,
      PHONE: phone ?? null,
      IS_VERIFIED: is_verified ?? null,
      ...context(req),
    });
    const response = result.recordset?.[0];

    return res.status(response?.success ? 200 : 400).json({
      success: Boolean(response?.success),
      message: response?.message || 'Failed to update customer.',
    });
  } catch (error) {
    return serverError(res, error);
  }
});

router.delete('/:id', ...protect, async (req, res) => {
  if (!isValidId(req.params.id)) {
    return res.status(400).json({ success: false, message: 'Invalid customer id.' });
  }

  try {
    const result = await executeCustomersSP('DELETE', {
      ID: Number(req.params.id),
      ...context(req),
    });
    const response = result.recordset?.[0];

    return res.status(response?.success ? 200 : 400).json({
      success: Boolean(response?.success),
      message: response?.message || 'Failed to delete customer.',
    });
  } catch (error) {
    return serverError(res, error);
  }
});

export default router;
