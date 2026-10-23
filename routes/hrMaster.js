import express from 'express';
import { requireFullMenuAccess, verifyToken } from '../middleware/auth.js';
import { uploadExcelFile } from '../middleware/excelUpload.js';
import {
  uploadFingerErrorEvidence,
  uploadPermitEvidence,
  uploadSicknessEvidence,
} from '../middleware/attachmentUpload.js';
import {
  listJobsites,
  listLevels,
  listSubmissions,
  listStructure,
  listUsers,
  getUser,
  createUser,
  updateUser,
  deleteUser,
  resetUserPassword,
  listMenus,
  getMenu,
  createMenu,
  updateMenu,
  deleteMenu,
  listEnums,
  listEnumTypes,
  getEnum,
  createEnum,
  updateEnum,
  deleteEnum,
  listWorkPattern,
  lookupWorkPatternWorker,
  getWorkPattern,
  createWorkPattern,
  updateWorkPattern,
  deleteWorkPattern,
  downloadWorkPatternExample,
  exportWorkPattern,
  previewGenerateWorkPattern,
  generateWorkPattern,
  importWorkPattern,
  listRoster,
  getRoster,
  getRosterEditPolicy,
  updateRoster,
  exportRoster,
  listSickness,
  getSickness,
  lookupSicknessWorker,
  listSicknessSection,
  approveSicknessSection,
  rejectSicknessSection,
  listSicknessGroup,
  approveSicknessGroup,
  rejectSicknessGroup,
  listSicknessDepartment,
  approveSicknessDepartment,
  rejectSicknessDepartment,
  listSicknessHr,
  exportSicknessHr,
  approveSicknessHr,
  rejectSicknessHr,
  listSicknessDepartmentExceptions,
  createSicknessDepartmentException,
  deleteSicknessDepartmentException,
  createSickness,
  updateSickness,
  cancelSickness,
  getSicknessEvidence,
  getSicknessEvidenceByPath,
  listEditPolicyModules,
  upsertEditPolicyModule,
  listEditPolicy,
  getEditPolicy,
  createEditPolicy,
  updateEditPolicy,
  deleteEditPolicy,
  listMenuPrivilege,
  listLevelPermissions,
  upsertLevelPermissions,
} from '../controllers/hrMaster.js';
import {
  listPermit,
  getPermit,
  lookupPermitWorker,
  listPermitSection,
  approvePermitSection,
  rejectPermitSection,
  listPermitGroup,
  approvePermitGroup,
  rejectPermitGroup,
  listPermitDepartment,
  approvePermitDepartment,
  rejectPermitDepartment,
  listPermitHr,
  exportPermitHr,
  approvePermitHr,
  rejectPermitHr,
  listPermitDepartmentExceptions,
  createPermitDepartmentException,
  deletePermitDepartmentException,
  createPermit,
  updatePermit,
  cancelPermit,
  getPermitEvidence,
  getPermitEvidenceByPath,
} from '../controllers/hrPermit.js';
import {
  listFingerError,
  getFingerError,
  lookupFingerErrorWorker,
  listFingerErrorSection,
  approveFingerErrorSection,
  rejectFingerErrorSection,
  listFingerErrorHr,
  exportFingerErrorHr,
  approveFingerErrorHr,
  rejectFingerErrorHr,
  createFingerError,
  updateFingerError,
  cancelFingerError,
  getFingerErrorEvidence,
  getFingerErrorEvidenceByPath,
  downloadFingerErrorExample,
  importFingerError,
} from '../controllers/hrFingerError.js';

const router = express.Router();

router.get('/jobsites', verifyToken, listJobsites);
router.get('/submissions', verifyToken, listSubmissions);
router.get('/levels', verifyToken, listLevels);
router.get('/structure', verifyToken, listStructure);

router.get('/users', verifyToken, listUsers);
router.post('/users/:id/reset-password', verifyToken, resetUserPassword);
router.get('/users/:id', verifyToken, getUser);
router.post('/users', verifyToken, createUser);
router.put('/users/:id', verifyToken, updateUser);
router.delete('/users/:id', verifyToken, deleteUser);

router.get('/menus', verifyToken, listMenus);
router.get('/menus/:id', verifyToken, getMenu);
router.post('/menus', verifyToken, createMenu);
router.put('/menus/:id', verifyToken, updateMenu);
router.delete('/menus/:id', verifyToken, deleteMenu);

router.get('/enums', verifyToken, listEnums);
router.get('/enums/types', verifyToken, listEnumTypes);
router.get('/enums/:id', verifyToken, getEnum);
router.post('/enums', verifyToken, createEnum);
router.put('/enums/:id', verifyToken, updateEnum);
router.delete('/enums/:id', verifyToken, deleteEnum);

router.get('/work-pattern', verifyToken, listWorkPattern);
router.get('/work-pattern/example', verifyToken, downloadWorkPatternExample);
router.get('/work-pattern/export', verifyToken, exportWorkPattern);
router.get('/work-pattern/lookup', verifyToken, lookupWorkPatternWorker);
router.get('/work-pattern/generate-preview', verifyToken, previewGenerateWorkPattern);
router.post('/work-pattern/generate', verifyToken, generateWorkPattern);
router.post(
  '/work-pattern/import',
  verifyToken,
  uploadExcelFile,
  importWorkPattern,
);
router.get('/work-pattern/:id', verifyToken, getWorkPattern);
router.post('/work-pattern', verifyToken, createWorkPattern);
router.put('/work-pattern/:id', verifyToken, updateWorkPattern);
router.delete('/work-pattern/:id', verifyToken, deleteWorkPattern);

router.get('/roster', verifyToken, listRoster);
router.get('/roster/export', verifyToken, exportRoster);
router.get('/roster/edit-policy', verifyToken, getRosterEditPolicy);
router.get('/roster/:id', verifyToken, getRoster);
router.put('/roster/:id', verifyToken, updateRoster);

router.get('/sickness', verifyToken, listSickness);
router.get('/sickness/section', verifyToken, listSicknessSection);
router.get('/sickness/group', verifyToken, listSicknessGroup);
router.get('/sickness/department', verifyToken, listSicknessDepartment);
router.get('/sickness/hr/export', verifyToken, exportSicknessHr);
router.get('/sickness/hr', verifyToken, listSicknessHr);
router.get('/sickness/department-exceptions', verifyToken, listSicknessDepartmentExceptions);
router.post('/sickness/department-exceptions', verifyToken, createSicknessDepartmentException);
router.delete('/sickness/department-exceptions/:id', verifyToken, deleteSicknessDepartmentException);
router.get('/sickness/lookup', verifyToken, lookupSicknessWorker);
router.post('/sickness/:id/approve-section', verifyToken, approveSicknessSection);
router.post('/sickness/:id/reject-section', verifyToken, rejectSicknessSection);
router.post('/sickness/:id/approve-group', verifyToken, approveSicknessGroup);
router.post('/sickness/:id/reject-group', verifyToken, rejectSicknessGroup);
router.post('/sickness/:id/approve-department', verifyToken, approveSicknessDepartment);
router.post('/sickness/:id/reject-department', verifyToken, rejectSicknessDepartment);
router.post('/sickness/:id/approve-hr', verifyToken, approveSicknessHr);
router.post('/sickness/:id/reject-hr', verifyToken, rejectSicknessHr);
router.get('/sickness/evidence', verifyToken, getSicknessEvidenceByPath);
router.get('/sickness/evidence/:photoId', verifyToken, getSicknessEvidence);
router.post('/sickness', verifyToken, uploadSicknessEvidence, createSickness);
router.post('/sickness/:id/cancel', verifyToken, cancelSickness);
router.get('/sickness/:id', verifyToken, getSickness);
router.put('/sickness/:id', verifyToken, updateSickness);

router.get('/permit', verifyToken, listPermit);
router.get('/permit/section', verifyToken, listPermitSection);
router.get('/permit/group', verifyToken, listPermitGroup);
router.get('/permit/department', verifyToken, listPermitDepartment);
router.get('/permit/hr/export', verifyToken, exportPermitHr);
router.get('/permit/hr', verifyToken, listPermitHr);
router.get('/permit/department-exceptions', verifyToken, listPermitDepartmentExceptions);
router.post('/permit/department-exceptions', verifyToken, createPermitDepartmentException);
router.delete('/permit/department-exceptions/:id', verifyToken, deletePermitDepartmentException);
router.get('/permit/lookup', verifyToken, lookupPermitWorker);
router.post('/permit/:id/approve-section', verifyToken, approvePermitSection);
router.post('/permit/:id/reject-section', verifyToken, rejectPermitSection);
router.post('/permit/:id/approve-group', verifyToken, approvePermitGroup);
router.post('/permit/:id/reject-group', verifyToken, rejectPermitGroup);
router.post('/permit/:id/approve-department', verifyToken, approvePermitDepartment);
router.post('/permit/:id/reject-department', verifyToken, rejectPermitDepartment);
router.post('/permit/:id/approve-hr', verifyToken, approvePermitHr);
router.post('/permit/:id/reject-hr', verifyToken, rejectPermitHr);
router.get('/permit/evidence', verifyToken, getPermitEvidenceByPath);
router.get('/permit/evidence/:photoId', verifyToken, getPermitEvidence);
router.post('/permit', verifyToken, uploadPermitEvidence, createPermit);
router.post('/permit/:id/cancel', verifyToken, cancelPermit);
router.get('/permit/:id', verifyToken, getPermit);
router.put('/permit/:id', verifyToken, updatePermit);

router.get('/finger-error', verifyToken, listFingerError);
router.get('/finger-error/section', verifyToken, listFingerErrorSection);
router.get('/finger-error/hr/export', verifyToken, exportFingerErrorHr);
router.get('/finger-error/hr', verifyToken, listFingerErrorHr);
router.get('/finger-error/example', verifyToken, downloadFingerErrorExample);
router.get('/finger-error/lookup', verifyToken, lookupFingerErrorWorker);
router.post(
  '/finger-error/import',
  verifyToken,
  uploadExcelFile,
  importFingerError,
);
router.post('/finger-error/:id/approve-section', verifyToken, approveFingerErrorSection);
router.post('/finger-error/:id/reject-section', verifyToken, rejectFingerErrorSection);
router.post('/finger-error/:id/approve-hr', verifyToken, approveFingerErrorHr);
router.post('/finger-error/:id/reject-hr', verifyToken, rejectFingerErrorHr);
router.get('/finger-error/evidence', verifyToken, getFingerErrorEvidenceByPath);
router.get('/finger-error/evidence/:photoId', verifyToken, getFingerErrorEvidence);
router.post('/finger-error', verifyToken, uploadFingerErrorEvidence, createFingerError);
router.post('/finger-error/:id/cancel', verifyToken, cancelFingerError);
router.get('/finger-error/:id', verifyToken, getFingerError);
router.put('/finger-error/:id', verifyToken, updateFingerError);

router.get('/edit-policy/modules', verifyToken, listEditPolicyModules);
router.post('/edit-policy/modules', verifyToken, upsertEditPolicyModule);
router.get('/edit-policy', verifyToken, listEditPolicy);
router.get('/edit-policy/:id', verifyToken, getEditPolicy);
router.post('/edit-policy', verifyToken, createEditPolicy);
router.put('/edit-policy/:id', verifyToken, updateEditPolicy);
router.delete('/edit-policy/:id', verifyToken, deleteEditPolicy);

router.get('/menu-privilege', verifyToken, listMenuPrivilege);
router.get('/level-permissions', verifyToken, listLevelPermissions);
router.put(
  '/level-permissions',
  verifyToken,
  requireFullMenuAccess,
  upsertLevelPermissions,
);

export default router;
