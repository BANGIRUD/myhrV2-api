import express from 'express';
import { verifyToken } from '../middleware/auth.js';
import { enforceApiPermission } from '../middleware/apiPermission.js';
import { executeEnumsSP } from '../controllers/enums.js';

const router = express.Router();
const protect = [verifyToken, enforceApiPermission];

const getUserContext = (req) => {
  const { id: by_user, by_jobsite } = req.user;
  return { BY_USER: by_user, BY_JOBSITE: by_jobsite };
};

router.get('/', ...protect, (req, res) => {
  const { type, category, q } = req.query;
  const search =
    typeof q === 'string' && q.trim() !== '' ? q.trim() : null;

  const parameters = {
    TYPE: type || null,
    CATEGORY: category || null,
    SEARCH: search,
    PAGE: 1,
    PAGE_SIZE: 0,
    ...getUserContext(req),
  };

  executeEnumsSP('SELECT', parameters)
    .then((result) => {
      res.json({
        success: true,
        message: 'Fetched enums successfully',
        data: result.recordsets?.[0] ?? result.recordset ?? [],
      });
    })
    .catch((error) => {
      res.status(500).json({
        success: false,
        message: 'Server error',
        error: error.message,
      });
    });
});

router.get('/:id', ...protect, (req, res) => {
  const { id } = req.params;

  if (!/^\d+$/.test(String(id))) {
    return res.status(400).json({
      success: false,
      message: 'Invalid enum id',
    });
  }

  const parameters = {
    ID: Number(id),
    ...getUserContext(req),
  };

  executeEnumsSP('GET', parameters)
    .then((result) => {
      res.json({
        success: true,
        message: 'Fetched enum successfully',
        data: result.recordset[0] ?? null,
      });
    })
    .catch((error) => {
      res.status(500).json({
        success: false,
        message: 'Server error',
        error: error.message,
      });
    });
});

router.post('/', ...protect, (req, res) => {
  const {
    code,
    name,
    category,
    category_description,
    type,
    include,
    ref_id,
  } = req.body || {};

  const parameters = {
    CODE: code,
    NAME: name,
    CATEGORY: category ?? type ?? null,
    CATEGORY_DESCRIPTION: category_description ?? null,
    TYPE: type,
    INCLUDE: include ?? true,
    REF_ID: ref_id ?? null,
    ...getUserContext(req),
  };

  executeEnumsSP('INSERT', parameters)
    .then((result) => {
      const response = result.recordset[0];
      if (response?.success) {
        res.json({
          success: true,
          message: response.message,
          data: req.body,
        });
      } else {
        res.status(400).json({
          success: false,
          message: response?.message || 'Failed to save enum',
        });
      }
    })
    .catch((error) => {
      res.status(500).json({
        success: false,
        message: 'Server error',
        error: error.message,
      });
    });
});

router.put('/', ...protect, (req, res) => {
  const {
    id,
    code,
    name,
    category,
    category_description,
    type,
    include,
    ref_id,
  } = req.body || {};

  const parameters = {
    ID: id,
    CODE: code,
    NAME: name,
    CATEGORY: category ?? type ?? null,
    CATEGORY_DESCRIPTION: category_description ?? null,
    TYPE: type,
    INCLUDE: include ?? true,
    REF_ID: ref_id ?? null,
    ...getUserContext(req),
  };

  executeEnumsSP('UPDATE', parameters)
    .then((result) => {
      const response = result.recordset[0];
      if (response?.success) {
        res.json({
          success: true,
          message: response.message,
          data: req.body,
        });
      } else {
        res.status(400).json({
          success: false,
          message: response?.message || 'Failed to update enum',
        });
      }
    })
    .catch((error) => {
      res.status(500).json({
        success: false,
        message: 'Server error',
        error: error.message,
      });
    });
});

router.delete('/', ...protect, (req, res) => {
  const { id } = req.query;
  const parameters = {
    ID: Number(id),
    ...getUserContext(req),
  };

  executeEnumsSP('DELETE', parameters)
    .then((result) => {
      const response = result.recordset[0];
      if (response?.success) {
        res.json({
          success: true,
          message: response.message,
          data: { id },
        });
      } else {
        res.status(400).json({
          success: false,
          message: response?.message || 'Failed to delete enum',
        });
      }
    })
    .catch((error) => {
      res.status(500).json({
        success: false,
        message: 'Server error',
        error: error.message,
      });
    });
});

export default router;
