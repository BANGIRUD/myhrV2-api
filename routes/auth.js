import express from 'express';
import {
  loginUser,
  getUserProfile,
  changePassword,
} from '../controllers/auth.js';
import { requireAuth } from '../middleware/auth.js';

const router = express.Router();

router.post('/login', async (req, res) => {
  try {
    const { username, password, remember_me } = req.body || {};

    if (!username || !password) {
      return res.status(400).json({
        success: false,
        message: 'Username and password are required.',
      });
    }

    const result = await loginUser(username, password, { remember_me });
    if (!result.success) {
      return res.status(401).json(result);
    }

    return res.json(result);
  } catch (error) {
    return res.status(500).json({
      success: false,
      message: 'Server error',
      error: error.message,
    });
  }
});

router.get('/me', requireAuth, async (req, res) => {
  try {
    const result = await getUserProfile(req.user);

    if (!result.success) {
      return res.status(404).json(result);
    }

    return res.json(result);
  } catch (error) {
    return res.status(500).json({
      success: false,
      message: 'Server error',
      error: error.message,
    });
  }
});

router.post('/logout', requireAuth, (_req, res) => {
  res.json({
    success: true,
    message: 'Logged out successfully.',
  });
});

router.post('/change-password', requireAuth, async (req, res) => {
  try {
    const { old_password, new_password, renew_password } = req.body || {};
    const result = await changePassword(req.user, {
      old_password,
      new_password,
      renew_password,
    });

    if (!result.success) {
      const status =
        result.code === 'VALIDATION'
          ? 400
          : result.code === 'UNSUPPORTED'
            ? 403
            : result.code === 'INVALID_PASSWORD'
              ? 401
              : 400;
      const { code: _code, ...body } = result;
      return res.status(status).json(body);
    }

    return res.json(result);
  } catch (error) {
    return res.status(500).json({
      success: false,
      message: 'Server error',
      error: error.message,
    });
  }
});

export default router;
