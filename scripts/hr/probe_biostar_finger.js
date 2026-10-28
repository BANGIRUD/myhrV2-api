/**
 * Sample Biostar linked-server SP column shapes (ops / debugging).
 * Usage: node scripts/hr/probe_biostar_finger.js [YYYY-MM-DD]
 */
import dotenv from 'dotenv';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';
import { getConnection, sql } from '../../config/database.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
dotenv.config({ path: join(__dirname, '..', '..', '.env') });

const day = process.argv[2] || new Date().toISOString().slice(0, 10);

const pool = await getConnection();
pool.request().timeout = 600000;

async function probe(label, query) {
  console.log(`\n=== ${label} ===`);
  try {
    const result = await pool.request().query(query);
    const rows = result.recordset || [];
    console.log('count', rows.length);
    if (rows[0]) {
      console.log('cols', Object.keys(rows[0]));
      console.log('sample', JSON.stringify(rows.slice(0, 2), null, 2));
    } else {
      console.log('(empty)');
    }
  } catch (err) {
    console.log('ERROR', err.message);
  }
}

await probe(
  'linked servers',
  `SELECT name, data_source, provider, is_linked FROM sys.servers WHERE is_linked = 1 ORDER BY name`,
);

await probe(
  'SP_GET_DATA_FINGER',
  `EXEC [BIOSTAR_131_100].[biostar2ac].dbo.SP_GET_DATA_FINGER N'${day}', N'${day}'`,
);

await probe(
  'SP_GET_DATA_FINGER_OAMS (may be slow)',
  `EXEC [BIOSTAR_131_100].[biostar2ac].dbo.SP_GET_DATA_FINGER_OAMS N'${day}', N'${day}'`,
);

await sql.close();
process.exit(0);
