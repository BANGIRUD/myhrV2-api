import { getConnection } from '../config/database.js';
import { qualifyProcedureName } from '../config/databaseSchema.js';

export const executeUsersSP = async (action_sp, params) => {
  let connection;
  try {
    connection = await getConnection();
    const request = connection.request().input('ACTION_SP', action_sp);

    for (const [key, value] of Object.entries(params)) {
      request.input(key, value);
    }

    const result = await request.execute(qualifyProcedureName('USERS_SP'));
    return result;
  } catch (error) {
    console.error(`Error executing users action ${action_sp}:`, error.message);
    throw error;
  }
};
