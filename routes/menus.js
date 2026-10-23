import express from 'express';
import { verifyToken } from '../middleware/auth.js';
import {
  getHrNavigationByUser,
  getHrPermissionsByUser,
  isAllAccessUser,
  isFullMenuAccessUser,
} from '../services/hrMenuPermission.js';

const router = express.Router();

const accessMeta = (user) => ({
  all_access: isAllAccessUser(user),
  full_menu_access: isFullMenuAccessUser(user),
});

router.get('/permissions', verifyToken, async (req, res) => {
  try {
    const data = await getHrPermissionsByUser(req.user);
    res.json({
      success: true,
      message: 'Fetched menu permissions successfully',
      data,
      meta: accessMeta(req.user),
    });
  } catch (error) {
    res.status(500).json({
      success: false,
      message: 'Server error',
      error: error.message,
    });
  }
});

router.get('/navigation', verifyToken, async (req, res) => {
  try {
    const data = await getHrNavigationByUser(req.user);
    res.json({
      success: true,
      message: 'Fetched navigation successfully',
      data,
      meta: accessMeta(req.user),
    });
  } catch (error) {
    res.status(500).json({
      success: false,
      message: 'Server error',
      error: error.message,
    });
  }
});

export default router;
