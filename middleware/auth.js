import jwt from 'jsonwebtoken';
import { verifyAuthToken } from '../controllers/auth.js';
import { isFullMenuAccessUser } from '../services/hrMenuPermission.js';

const JWT_SECRET = process.env.JWT_SECRET || 'myhr-dev-secret';

const isDevAuthBypassEnabled = () =>
  process.env.NODE_ENV === 'development' &&
  process.env.AUTH_DEV_BYPASS !== 'false';

function attachBearerOrFail(req, res) {
  const authHeader = req.headers.authorization;

  if (!authHeader?.startsWith('Bearer ')) {
    res.status(401).json({
      success: false,
      message: 'Unauthorized.',
    });
    return false;
  }

  try {
    const token = authHeader.slice(7);
    req.user = jwt.verify(token, JWT_SECRET);
    return true;
  } catch {
    res.status(401).json({
      success: false,
      message: 'Invalid or expired token.',
    });
    return false;
  }
}

/**
 * Strict JWT gate — used by /auth/me and /auth/logout.
 * Never applies FLEET DEV bypass (missing Bearer must be 401).
 */
export const requireAuth = (req, res, next) => {
  if (!attachBearerOrFail(req, res)) return;
  return next();
};

export const verifyToken = (req, res, next) => {
  const authHeader = req.headers.authorization;

  if (authHeader?.startsWith('Bearer ')) {
    if (!attachBearerOrFail(req, res)) return;
    return next();
  }

  // FLEET local tooling only — do not use on MyHR auth session routes.
  if (isDevAuthBypassEnabled()) {
    req.user = {
      id: Number(req.headers['x-user-id']) || 1,
      username: req.headers['x-username'] || 'system',
      nrp: req.headers['x-nrp'] || '0216691',
      level_id: Number(req.headers['x-level-id']) || 1,
      level_code: req.headers['x-level-code'] || 'admin',
      level_name: req.headers['x-level-name'] || 'Admin',
      by_jobsite: Number(req.headers['x-jobsite-id']) || 1,
    };
    return next();
  }

  return res.status(401).json({
    success: false,
    message: 'Unauthorized.',
  });
};

/** Only superadmin / sa may mutate the level-permission matrix. */
export const requireFullMenuAccess = (req, res, next) => {
  if (!isFullMenuAccessUser(req.user)) {
    return res.status(403).json({
      success: false,
      message: 'Only superadmin can change level permissions.',
    });
  }
  return next();
};

export const optionalVerifyToken = (req, res, next) => {
  const authHeader = req.headers.authorization;

  if (authHeader?.startsWith('Bearer ')) {
    try {
      req.user = verifyAuthToken(authHeader.slice(7));
    } catch {
      req.user = null;
    }
  }

  next();
};
