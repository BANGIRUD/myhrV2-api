import { getConnection } from '../config/database.js';
import { qualifyProcedureName } from '../config/databaseSchema.js';

export const executeCustomersSP = async (action, params = {}) => {
  const connection = await getConnection();
  const request = connection.request().input('ACTION_SP', action);

  for (const [key, value] of Object.entries(params)) {
    request.input(key, value);
  }

  return request.execute(qualifyProcedureName('CUSTOMERS_SP'));
};
