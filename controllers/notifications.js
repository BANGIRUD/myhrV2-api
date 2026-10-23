import { resolveSectionScope, scopeToCsv } from '../services/hrDashboardScope.js';
import { isFullMenuAccessUser } from '../services/hrMenuPermission.js';
import { listFingerErrorInbox } from '../services/fingerErrorNotify.js';
import { listPermitInbox } from '../services/permitNotify.js';
import { listSicknessInbox } from '../services/sicknessNotify.js';

function actorOf(req) {
  const id = Number(req.user?.id);
  return Number.isInteger(id) && id > 0 ? id : null;
}

function jobsiteOf(req) {
  const id = Number(req.user?.by_jobsite);
  return Number.isInteger(id) && id > 0 ? id : 1;
}

/**
 * Catch-up for the bell. The live path is the WebSocket; this runs once on connect.
 * Later modules append their own waiting rows to the same array.
 */
export async function listNotifications(req, res) {
  try {
    if (isFullMenuAccessUser(req.user)) {
      return res.json({ success: true, message: 'Notifications', data: [] });
    }

    const scope = scopeToCsv(await resolveSectionScope(req.user));
    const level = String(req.user?.level_code || '').trim().toLowerCase();
    const workerScope = String(req.user?.worker_scope || '').trim().toLowerCase();
    const sakit = await listSicknessInbox({
      scopeSections: scope,
      levelCode: level,
      workerScope,
      byUser: actorOf(req),
      byJobsite: jobsiteOf(req),
    });
    const ijin = await listPermitInbox({
      scopeSections: scope,
      levelCode: level,
      workerScope,
      byUser: actorOf(req),
      byJobsite: jobsiteOf(req),
    });
    const finger = await listFingerErrorInbox({
      scopeSections: scope,
      levelCode: level,
      workerScope,
      byUser: actorOf(req),
      byJobsite: jobsiteOf(req),
    });

    return res.json({
      success: true,
      message: 'Notifications',
      data: [...sakit, ...ijin, ...finger],
    });
  } catch (error) {
    return res.status(500).json({
      success: false,
      message: 'Server error',
      error: error.message,
    });
  }
}
