import express from 'express';
import { verifyToken } from '../middleware/auth.js';
import { executeSamplesSP } from '../controllers/samples.js';

const router = express.Router();
// Protected route example - verify token
router.get('/', verifyToken, (req, res) => {
  const { id: by_user, by_jobsite } = req.user;
  const parameters = {
    BY_USER: by_user,
    BY_JOBSITE: by_jobsite,
  };
  try {
    executeSamplesSP('SELECT', parameters)
      .then((result) => {
        const response = result.recordset;
        res.json({
          success: true,
          message: 'Fetched all beds successfully',
          data: response,
        });
      })
      .catch((error) => {
        res
          .status(500)
          .json({
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

router.post('/', verifyToken, (req, res) => {
  const {
    dormitory_id,
    building_id,
    room_id,
    bed_number,
    status,
    description,
  } = req.body;
  const { id: by_user, by_jobsite } = req.user;

  const parameters = {
    DORMITORY_ID: dormitory_id,
    BUILDING_ID: building_id,
    ROOM_ID: room_id,
    BED_NUMBER: bed_number,
    STATUS: status,
    DESCRIPTION: description,
    BY_USER: by_user,
    BY_JOBSITE: by_jobsite,
  };

  try {
    executeSamplesSP('INSERT', parameters)
      .then((result) => {
        const response = result.recordset[0];
        if (response.success) {
          res.json({
            success: true,
            message: 'Bed saved successfully',
            data: req.body,
          });
        } else {
          res.status(400).json({
            success: false,
            message: response.message || 'Failed to save building',
          });
        }
      })
      .catch((error) => {
        res
          .status(500)
          .json({
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

router.put('/', verifyToken, (req, res) => {
  const {
    id,
    dormitory_id,
    building_id,
    room_id,
    bed_number,
    status,
    description,
  } = req.body;
  const { id: by_user, by_jobsite } = req.user;

  const parameters = {
    ID: id,
    DORMITORY_ID: dormitory_id,
    BUILDING_ID: building_id,
    ROOM_ID: room_id,
    BED_NUMBER: bed_number,
    STATUS: status,
    DESCRIPTION: description,
    BY_USER: by_user,
    BY_JOBSITE: by_jobsite,
  };

  try {
    executeSamplesSP('UPDATE', parameters)
      .then((result) => {
        const response = result.recordset[0];
        if (response.success) {
          res.json({
            success: true,
            message: 'Bed updated successfully',
            data: req.body,
          });
        } else {
          res.status(400).json({
            success: false,
            message: response.message || 'Failed to update bed',
          });
        }
      })
      .catch((error) => {
        res
          .status(500)
          .json({
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

router.delete('/', verifyToken, (req, res) => {
  const { id } = req.query;
  const { id: by_user, by_jobsite } = req.user;
  const parameters = {
    ID: id,
    BY_USER: by_user,
    BY_JOBSITE: by_jobsite,
  };
  try {
    executeSamplesSP('DELETE', parameters)
      .then((result) => {
        const response = result.recordset[0];

        if (response.success) {
          res.json({
            success: true,
            message: 'Bed deleted successfully',
            data: req.body,
          });
        } else {
          res.status(400).json({
            success: false,
            message: response.message || 'Failed to delete bed',
          });
        }
      })
      .catch((error) => {
        res
          .status(500)
          .json({
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

router.get('/:room_id', verifyToken, (req, res) => {
  const { room_id } = req.params;
  const { id: by_user, by_jobsite } = req.user;
  const parameters = {
    ROOM_ID: room_id,
    BY_USER: by_user,
    BY_JOBSITE: by_jobsite,
  };
  try {
    executeSamplesSP('GET', parameters)
      .then((result) => {
        const response = result.recordset;
        res.json({
          success: true,
          message: 'Fetched all beds successfully',
          data: response,
        });
      })
      .catch((error) => {
        res
          .status(500)
          .json({
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
