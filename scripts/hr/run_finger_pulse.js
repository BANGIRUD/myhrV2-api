/**
 * Finger Pulse CLI — thin wrapper around services/fingerPulseRunner.js
 *
 * Usage:
 *   node scripts/hr/run_finger_pulse.js status
 *   node scripts/hr/run_finger_pulse.js pulse
 *   node scripts/hr/run_finger_pulse.js reconcile
 *   node scripts/hr/run_finger_pulse.js backfill 2026-10-20 2026-10-25
 *   node scripts/hr/run_finger_pulse.js purge
 *
 * Schedule (Task Scheduler / SQL Agent CmdExec): pulse every 15m; reconcile ~23:00.
 * See docs/FINGER_PULSE.md
 */
import dotenv from 'dotenv';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';
import { sql } from '../../config/database.js';
import {
  FINGER_PULSE_MODES,
  runFingerPulseIngest,
  runFingerPulseSpAction,
} from '../../services/fingerPulseRunner.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
dotenv.config({ path: join(__dirname, '..', '..', '.env') });

const mode = String(process.argv[2] || '').toLowerCase();
const argFrom = process.argv[3] || null;
const argTo = process.argv[4] || null;

if (!FINGER_PULSE_MODES.includes(mode)) {
  console.error(
    'Usage: node scripts/hr/run_finger_pulse.js <status|pulse|reconcile|backfill|purge> [date_from date_to]',
  );
  process.exit(1);
}

/** Dedicated pool: Biostar OAMS pulls routinely exceed the default 15s requestTimeout. */
async function getPulsePool() {
  const port = Number.parseInt(process.env.DB_PORT || '1433', 10);
  return sql.connect({
    user: process.env.DB_USER,
    password: process.env.DB_PASSWORD,
    server: process.env.DB_SERVER,
    port,
    database: process.env.DB_NAME,
    requestTimeout: 900000,
    connectionTimeout: 60000,
    options: {
      encrypt: true,
      trustServerCertificate: true,
      enableArithAbort: true,
    },
    pool: { max: 5, min: 0, idleTimeoutMillis: 30000 },
  });
}

const pool = await getPulsePool();
console.log('Database connected (Finger Pulse pool, requestTimeout=900000)');

try {
  if (mode === 'status' || mode === 'purge') {
    console.log(`→ ${mode.toUpperCase()}`);
    const result = await runFingerPulseSpAction(pool, mode);
    if (mode === 'status') {
      console.log('watermarks', result.watermarks);
      console.log('recent_runs', result.recent_runs);
      console.log('config', result.config);
    } else {
      console.log('result', result.result);
      if (!result.success) process.exitCode = 2;
    }
  } else {
    const outcome = await runFingerPulseIngest(pool, {
      mode,
      dateFrom: argFrom,
      dateTo: argTo,
      log: (msg, extra) => {
        if (extra !== undefined) console.log(`→ ${msg}`, extra);
        else console.log(`→ ${msg}`);
      },
    });
    console.log('result', outcome);
    if (!outcome.success) process.exitCode = 2;
  }
} catch (err) {
  console.error('FAILED', err.message);
  process.exitCode = err.code === 'BUSY' || err.code === 'DISABLED' ? 2 : 1;
} finally {
  await sql.close();
}
