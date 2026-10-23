import express from 'express';
import authRoutes from './auth.js';
import menusRoutes from './menus.js';
import hrMasterRoutes from './hrMaster.js';
import hrDashboardRoutes from './hrDashboard.js';
import notificationRoutes from './notifications.js';

// Legacy ticketing/FLEET modules (schema `ticketing`) — disabled; MyHR uses schema `hr`.
// import samplesRoutes from './samples.js';
// import equipmentsRoutes from './equipments.js';
// import enumsRoutes from './enums.js';
// import ticketsRoutes from './tickets.js';
// import customersRoutes from './customers.js';
// import portalRoutes from './portal.js';

const router = express.Router();

router.use('/auth', authRoutes);
router.use('/menus', menusRoutes);
router.use('/hr', hrMasterRoutes);
router.use('/dashboard', hrDashboardRoutes);
router.use('/notifications', notificationRoutes);

// router.use('/enums', enumsRoutes);
// router.use('/tickets', ticketsRoutes);
// router.use('/customers', customersRoutes);
// router.use('/portal', portalRoutes);
// router.use('/samples', samplesRoutes);
// router.use('/equipments', equipmentsRoutes);

export default router;
