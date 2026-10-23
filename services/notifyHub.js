import jwt from 'jsonwebtoken';
import { WebSocketServer } from 'ws';

const JWT_SECRET = process.env.JWT_SECRET || 'myhr-dev-secret';

/** user id -> open sockets. Cleared when the process restarts. */
const socketsByUser = new Map();

function remember(userId, socket) {
  const current = socketsByUser.get(userId) || new Set();
  current.add(socket);
  socketsByUser.set(userId, current);
}

function forget(userId, socket) {
  const current = socketsByUser.get(userId);
  if (!current) return;
  current.delete(socket);
  if (current.size === 0) socketsByUser.delete(userId);
}

/**
 * One WebSocket on the existing HTTP server. Path `/ws?token=`.
 * Later modules publish through `publishToUsers`; they do not open another socket.
 */
export function attachNotifyServer(server) {
  const wss = new WebSocketServer({ server, path: '/ws' });

  wss.on('connection', (socket, request) => {
    let userId = 0;
    try {
      const url = new URL(request.url || '', 'http://localhost');
      const token = url.searchParams.get('token') || '';
      const user = jwt.verify(token, JWT_SECRET);
      userId = Number(user.id);
      if (!userId) throw new Error('missing user');
    } catch {
      socket.close(4001, 'unauthorized');
      return;
    }

    remember(userId, socket);
    socket.on('close', () => forget(userId, socket));
    socket.on('error', () => forget(userId, socket));
  });
}

/** Push one event to every open tab of the given users. */
export function publishToUsers(userIds, event) {
  const payload = JSON.stringify(event);
  const seen = new Set();
  for (const raw of userIds || []) {
    const userId = Number(raw);
    if (!userId || seen.has(userId)) continue;
    seen.add(userId);
    for (const socket of socketsByUser.get(userId) || []) {
      if (socket.readyState === 1) socket.send(payload);
    }
  }
}
