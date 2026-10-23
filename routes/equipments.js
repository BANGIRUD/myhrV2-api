import express from 'express';
import { verifyToken } from '../middleware/auth.js';
import { enforceApiPermission } from '../middleware/apiPermission.js';
import { executeEquipmentsSP } from '../controllers/equipments.js';

const router = express.Router();

const protect = [verifyToken, enforceApiPermission];

router.get('/', ...protect, (req, res) => {
  const { id: by_user, by_jobsite } = req.user;
  const parameters = {
    BY_USER: by_user,
    BY_JOBSITE: by_jobsite,
  };

  try {
    executeEquipmentsSP('SELECT', parameters)
      .then((result) => {
        res.json({
          success: true,
          message: 'Fetched all equipments successfully',
          data: result.recordset,
        });
      })
      .catch((error) => {
        res.status(500).json({
          success: false,
          message: 'Server error',
          error: error.message,
        });
      });
  } catch (error) {
    res
      .status(500)
      .json({ success: false, message: 'Server error', error: error.message });
  }
});

router.post('/import', ...protect, async (req, res) => {
  const items = Array.isArray(req.body?.items) ? req.body.items : [];
  const { id: by_user, by_jobsite } = req.user;

  if (!items.length) {
    return res.status(400).json({
      success: false,
      message: 'No items to import.',
    });
  }

  const results = {
    total: items.length,
    success: 0,
    failed: 0,
    errors: [],
  };

  try {
    for (let index = 0; index < items.length; index += 1) {
      const item = items[index] || {};
      const parameters = {
        JIGSAW_ID: item.jigsaw_id,
        ELLIPSE: item.ellipse ?? null,
        OLD_ELLIPSE: item.old_ellipse ?? null,
        EQUIPMENT_TYPE_ID: item.equipment_type_id ?? null,
        TYPE: item.type ?? null,
        LOADER_FLEET: item.loader_fleet ?? null,
        PIT_ID: item.pit_id ?? null,
        STATUS: item.status ?? 1,
        BY_USER: by_user,
        BY_JOBSITE: by_jobsite,
      };

      try {
        const result = await executeEquipmentsSP('INSERT', parameters);
        const response = result.recordset?.[0];
        if (response?.success) {
          results.success += 1;
        } else {
          results.failed += 1;
          results.errors.push({
            row: index + 1,
            jigsaw_id: item.jigsaw_id,
            message: response?.message || 'Failed to import row',
          });
        }
      } catch (error) {
        results.failed += 1;
        results.errors.push({
          row: index + 1,
          jigsaw_id: item.jigsaw_id,
          message: error.message,
        });
      }
    }

    return res.json({
      success: results.failed === 0,
      message:
        results.failed === 0
          ? `Imported ${results.success} equipment(s) successfully`
          : `Imported ${results.success} of ${results.total} equipment(s)`,
      data: results,
    });
  } catch (error) {
    return res.status(500).json({
      success: false,
      message: 'Server error',
      error: error.message,
    });
  }
});

router.get('/:id', ...protect, (req, res) => {
  const { id } = req.params;
  const { id: by_user, by_jobsite } = req.user;
  const parameters = {
    ID: id,
    BY_USER: by_user,
    BY_JOBSITE: by_jobsite,
  };

  try {
    executeEquipmentsSP('GET', parameters)
      .then((result) => {
        const response = result.recordset;
        if (!response?.length) {
          return res.status(404).json({
            success: false,
            message: 'Equipment not found',
          });
        }

        res.json({
          success: true,
          message: 'Fetched equipment successfully',
          data: response[0],
        });
      })
      .catch((error) => {
        res.status(500).json({
          success: false,
          message: 'Server error',
          error: error.message,
        });
      });
  } catch (error) {
    res
      .status(500)
      .json({ success: false, message: 'Server error', error: error.message });
  }
});

router.post('/', ...protect, (req, res) => {
  const {
    jigsaw_id,
    ellipse,
    old_ellipse,
    equipment_type_id,
    type,
    loader_fleet,
    pit_id,
    status,
  } = req.body;
  const { id: by_user, by_jobsite } = req.user;

  const parameters = {
    JIGSAW_ID: jigsaw_id,
    ELLIPSE: ellipse,
    OLD_ELLIPSE: old_ellipse ?? null,
    EQUIPMENT_TYPE_ID: equipment_type_id,
    TYPE: type,
    LOADER_FLEET: loader_fleet ?? null,
    PIT_ID: pit_id,
    STATUS: status ?? 1,
    BY_USER: by_user,
    BY_JOBSITE: by_jobsite,
  };

  try {
    executeEquipmentsSP('INSERT', parameters)
      .then((result) => {
        const response = result.recordset[0];
        if (response.success) {
          res.json({
            success: true,
            message: 'Equipment saved successfully',
            data: req.body,
          });
        } else {
          res.status(400).json({
            success: false,
            message: response.message || 'Failed to save equipment',
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
  } catch (error) {
    res
      .status(500)
      .json({ success: false, message: 'Server error', error: error.message });
  }
});

router.put('/', ...protect, (req, res) => {
  const {
    id,
    jigsaw_id,
    ellipse,
    old_ellipse,
    equipment_type_id,
    type,
    loader_fleet,
    pit_id,
    status,
  } = req.body;
  const { id: by_user, by_jobsite } = req.user;

  const parameters = {
    ID: id,
    JIGSAW_ID: jigsaw_id,
    ELLIPSE: ellipse,
    OLD_ELLIPSE: old_ellipse ?? null,
    EQUIPMENT_TYPE_ID: equipment_type_id,
    TYPE: type,
    LOADER_FLEET: loader_fleet ?? null,
    PIT_ID: pit_id,
    STATUS: status,
    BY_USER: by_user,
    BY_JOBSITE: by_jobsite,
  };

  try {
    executeEquipmentsSP('UPDATE', parameters)
      .then((result) => {
        const response = result.recordset[0];
        if (response.success) {
          res.json({
            success: true,
            message: 'Equipment updated successfully',
            data: req.body,
          });
        } else {
          res.status(400).json({
            success: false,
            message: response.message || 'Failed to update equipment',
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
  } catch (error) {
    res
      .status(500)
      .json({ success: false, message: 'Server error', error: error.message });
  }
});

router.delete('/', ...protect, (req, res) => {
  const { id } = req.query;
  const { id: by_user, by_jobsite } = req.user;
  const parameters = {
    ID: id,
    BY_USER: by_user,
    BY_JOBSITE: by_jobsite,
  };

  try {
    executeEquipmentsSP('DELETE', parameters)
      .then((result) => {
        const response = result.recordset[0];
        if (response.success) {
          res.json({
            success: true,
            message: 'Equipment deleted successfully',
            data: { id },
          });
        } else {
          res.status(400).json({
            success: false,
            message: response.message || 'Failed to delete equipment',
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
  } catch (error) {
    res
      .status(500)
      .json({ success: false, message: 'Server error', error: error.message });
  }
});

export default router;
