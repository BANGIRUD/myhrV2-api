import { getConnection } from '../config/database.js';
import { qualifyProcedureName } from '../config/databaseSchema.js';

async function executeProcedure(procedureName, action, params = {}) {
  const connection = await getConnection();
  const request = connection.request().input('ACTION_SP', action);

  for (const [key, value] of Object.entries(params)) {
    request.input(key, value);
  }

  return request.execute(qualifyProcedureName(procedureName));
}

export const executeTicketsSP = (action, params = {}) =>
  executeProcedure('TICKETS_SP', action, params);

export const executeTicketRepliesSP = (action, params = {}) =>
  executeProcedure('TICKET_REPLIES_SP', action, params);

export const executeTicketAttachmentsSP = (action, params = {}) =>
  executeProcedure('TICKET_ATTACHMENTS_SP', action, params);
