import { getConnection } from '../config/database.js';
import { qualifyProcedureName } from '../config/databaseSchema.js';

export const executeSamplesSP = async (action_sp, params) => {
  let connection;
  try {
    // Dapatkan koneksi database
    connection = await getConnection();
    const request = connection.request().input('ACTION_SP', action_sp);

    // Tambahkan input parameters dari objek params
    for (const [key, value] of Object.entries(params)) {
      request.input(key, value);
    }
    const result = await request.execute(qualifyProcedureName('SAMPLES_SP'));
    return result;
  } catch (error) {
    console.error(`Error executing action ${action_sp}:`, error.message);
    throw error;
  }
};
