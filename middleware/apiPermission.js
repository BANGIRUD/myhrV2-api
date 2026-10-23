import { resolveApiPermissionRule } from '../config/apiPermissions.js';
import { checkMenuPermission, isSuperadminUser } from '../services/menuPermission.js';

export const enforceApiPermission = async (req, res, next) => {
  const rule = resolveApiPermissionRule(req.method, req.originalUrl);

  if (!rule) {
    return next();
  }

  if (!req.user) {
    return res.status(401).json({
      success: false,
      message: 'Unauthorized.',
    });
  }

  if (rule.denied) {
    return res.status(403).json({
      success: false,
      message: 'API permission rule is not configured.',
    });
  }

  if (rule.authOnly || isSuperadminUser(req.user)) {
    return next();
  }

  try {
    const { level_id: levelId, by_jobsite: byJobsite } = req.user;

    const result = rule.anyRead
      ? await checkMenuPermission({
          levelId,
          byJobsite,
          permissionType: 'any_read',
        })
      : await checkMenuPermission({
          levelId,
          byJobsite,
          permissionType: rule.permission,
          menuCode: rule.menuCode ?? null,
          menuCodes: rule.menuCodes ?? null,
          any: Boolean(rule.any),
        });

    if (!result.allowed) {
      return res.status(403).json({
        success: false,
        message: result.message || 'Access denied.',
      });
    }

    return next();
  } catch (error) {
    return res.status(500).json({
      success: false,
      message: 'Server error',
      error: error.message,
    });
  }
};
