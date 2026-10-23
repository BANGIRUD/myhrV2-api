import sql from 'mssql';
import dotenv from 'dotenv';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';
import { getHrSchema } from './databaseSchema.js';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

dotenv.config({ path: join(__dirname, '..', '.env') });

const dbPort = Number.parseInt(process.env.DB_PORT || '1433', 10);

const config = {
  user: process.env.DB_USER,
  password: process.env.DB_PASSWORD,
  server: process.env.DB_SERVER,
  port: dbPort,
  database: process.env.DB_NAME,
  options: {
    encrypt: true,
    trustServerCertificate: true,
    enableArithAbort: true,
  },
  pool: {
    max: 10,
    min: 0,
    idleTimeoutMillis: 30000,
  },
};

let pool = null;
let connecting = null;

export const getConnection = async () => {
  try {
    if (
      !config.server ||
      !config.database ||
      !config.user ||
      !config.password ||
      Number.isNaN(config.port)
    ) {
      throw new Error(
        'Database configuration is incomplete. Check your .env file (DB_SERVER, DB_PORT, DB_NAME, DB_USER, DB_PASSWORD).',
      );
    }

    if (pool) {
      return pool;
    }

    // Share one in-flight connect so concurrent callers don't connect/log twice.
    if (!connecting) {
      connecting = (async () => {
        console.log('🔌 Connecting to database...');
        const connected = await sql.connect(config);
        console.log(`Database connected successfully (schema: ${getHrSchema()})`);
        return connected;
      })();
    }

    try {
      pool = await connecting;
    } finally {
      connecting = null;
    }
    return pool;
  } catch (error) {
    console.error('Database connection error:', error.message);
    throw error;
  }
};

export { sql };
