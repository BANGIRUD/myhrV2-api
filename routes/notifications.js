import express from 'express';
import { verifyToken } from '../middleware/auth.js';
import { listNotifications } from '../controllers/notifications.js';

const router = express.Router();

router.get('/', verifyToken, listNotifications);

export default router;
