import http from 'http';
import express from 'express';
import cors from 'cors';
import dotenv from 'dotenv';
import routes from './routes/index.js';
import { attachNotifyServer } from './services/notifyHub.js';

dotenv.config();

const app = express();
const PORT = Number(process.env.PORT) || 9520;
const HOST = process.env.HOST || '0.0.0.0';
const corsOrigins = (process.env.CORS_ORIGIN || '')
  .split(',')
  .map((origin) => origin.trim())
  .filter(Boolean);

// Middleware
app.use(
  corsOrigins.length > 0
    ? cors({ origin: corsOrigins, credentials: true })
    : cors(),
);
// Parse JSON requests (must be before routes)
app.use(express.json({ limit: '20mb' }));
// Serve static files from public
app.use('/public', express.static('public'));
// Mount API routes
app.use('/api', routes);

app.get('/', (req, res) => {
  res.json({
    status: true,
    message: 'Welcome to the FLEET API',
    version: '1.0.0',
  });
});

app.get('/health', (req, res) => {
  res.json({ status: 'OK' });
});

const server = http.createServer(app);
attachNotifyServer(server);

server.listen(PORT, HOST, () => {
  console.log(`🚀 Server running on http://${HOST}:${PORT}`);
});
