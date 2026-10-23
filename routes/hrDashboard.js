import express from 'express';
import { verifyToken } from '../middleware/auth.js';
import {
  getAttendance,
  getWorkPattern,
  getEmployeeUnfit,
} from '../controllers/hrDashboard.js';

const router = express.Router();

router.use(verifyToken);

router.get('/attendance', getAttendance);
router.get('/work-pattern', getWorkPattern);
router.get('/employee-unfit', getEmployeeUnfit);

export default router;
