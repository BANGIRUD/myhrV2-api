const ENUM_ADMIN_MENU_CODES = [
  'category_element',
  'problem_element',
  'analysis_element',
  'cause_by_element',
  'action_element',
  'remark_element',
  'backlog_element',
  'attribute_element',
  'level_user_control',
  'subsection_control',
  'pit_element',
  'equipment_type_element',
  'equipment_status_element',
  'ticket_status_element',
  'ticket_priority_element',
  'ticket_category_element',
];

const UNIT_MENU_CODES = ['jigsaw_population', 'network_population'];

const REPORT_MENU_CODES = ['jigsaw_report', 'network_report', 'other_report'];

export const methodToPermissionType = (method) => {
  switch (method.toUpperCase()) {
    case 'POST':
      return 'insert';
    case 'PUT':
    case 'PATCH':
      return 'update';
    case 'DELETE':
      return 'delete';
    default:
      return 'read';
  }
};

const normalizeApiPath = (originalUrl = '') => {
  const withoutQuery = originalUrl.split('?')[0] ?? '';
  const path = withoutQuery.replace(/^\/api/, '') || '/';
  return path.replace(/\/+$/, '') || '/';
};

/**
 * Resolve RBAC rule for an API request.
 * Returns null when no permission check is required (public routes).
 * Returns { authOnly: true } when JWT is enough (profile, navigation).
 */
export function resolveApiPermissionRule(method, originalUrl) {
  const path = normalizeApiPath(originalUrl);
  const permission = methodToPermissionType(method);

  if (path === '/auth/login') {
    return null;
  }

  if (path.startsWith('/portal')) {
    return null;
  }

  if (
    path === '/auth/logout' ||
    path === '/auth/change-password' ||
    path.startsWith('/auth/me') ||
    path.startsWith('/auth/profile')
  ) {
    return { authOnly: true };
  }

  if (path === '/menus/navigation') {
    return { authOnly: true };
  }

  if (path.startsWith('/samples')) {
    return null;
  }

  if (path.startsWith('/equipments')) {
    if (path.endsWith('/import')) {
      return { menuCodes: ['equipments'], permission: 'import' };
    }

    if (permission === 'read') {
      return { menuCodes: ['equipments'], permission: 'read' };
    }

    return { menuCodes: ['equipments'], permission };
  }

  if (path.startsWith('/tickets')) {
    return { menuCodes: ['tickets'], permission };
  }

  if (path.startsWith('/customers')) {
    return { menuCodes: ['customers_master'], permission };
  }

  if (path.startsWith('/users')) {
    if (permission === 'read') {
      return {
        menuCodes: ['users_master', 'work-reports', ...REPORT_MENU_CODES],
        permission,
        any: true,
      };
    }

    return { menuCodes: ['users_master'], permission };
  }

  if (path.startsWith('/units')) {
    if (permission === 'read') {
      return {
        menuCodes: [...UNIT_MENU_CODES, 'work-reports'],
        permission,
        any: true,
      };
    }

    return { menuCodes: UNIT_MENU_CODES, permission, any: true };
  }

  if (path.startsWith('/unit-serial-histories')) {
    return { menuCodes: UNIT_MENU_CODES, permission, any: true };
  }

  if (path.startsWith('/enums')) {
    if (permission === 'read') {
      return { anyRead: true };
    }

    return { menuCodes: ENUM_ADMIN_MENU_CODES, permission, any: true };
  }

  if (path.startsWith('/enum-relations')) {
    if (permission === 'read') {
      return {
        menuCodes: ['relations_control', 'work-reports'],
        permission,
        any: true,
      };
    }

    return { menuCodes: ['relations_control'], permission };
  }

  if (path.startsWith('/menus')) {
    return { menuCodes: ['menus'], permission };
  }

  if (path.startsWith('/backlogs')) {
    if (permission === 'read') {
      return {
        menuCodes: ['work-reports', ...REPORT_MENU_CODES],
        permission,
        any: true,
      };
    }

    return { menuCodes: ['work-reports'], permission };
  }

  if (path.startsWith('/work-reports')) {
    return { menuCodes: ['work-reports'], permission };
  }

  if (path.startsWith('/time-periodics')) {
    if (permission === 'read') {
      return {
        menuCodes: [
          'time_periodic_control',
          'work-reports',
          ...REPORT_MENU_CODES,
        ],
        permission,
        any: true,
      };
    }

    return { menuCodes: ['time_periodic_control'], permission };
  }

  if (path.startsWith('/pm-equipment-plans')) {
    return { menuCodes: ['equipment_plan_control'], permission };
  }

  if (path.startsWith('/pm-checksheet-templates')) {
    return { menuCodes: ['pm_checksheet_template'], permission };
  }

  if (path.startsWith('/dashboard')) {
    return { menuCodes: ['dashboard'], permission };
  }

  if (
    /^\/reports\/pm\/[^/]+\/(checksheet-template|checksheets|checksheet)/.test(
      path,
    )
  ) {
    return {
      menuCodes: ['work-reports', ...REPORT_MENU_CODES],
      permission,
      any: true,
    };
  }

  if (path.startsWith('/reports')) {
    return { menuCodes: REPORT_MENU_CODES, permission, any: true };
  }

  return { denied: true };
}
