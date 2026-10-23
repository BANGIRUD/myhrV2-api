-- =============================================
-- Seed: ticket menus + full permissions for level_id = 1
-- Run AFTER menus.sql and seed_enum_menus.sql (needs admin_elements parent)
-- Menu codes: tickets | customers_master |
--             ticket_status_element | ticket_priority_element | ticket_category_element
-- =============================================

DECLARE @parent_id INT = (
  SELECT TOP 1 id FROM ticketing.menus
  WHERE menu_code = 'admin_elements' AND deleted_at IS NULL
);

IF @parent_id IS NULL
BEGIN
  INSERT INTO ticketing.menus (
    menu_code, menu_name, menu_url, icon, parent_id, sort_order,
    show_sidebar, is_active, created_by, by_jobsite
  )
  VALUES (
    'admin_elements', 'Admin Elements', NULL, 'folder', NULL, 2,
    1, 1, 'system', 1
  );
  SET @parent_id = SCOPE_IDENTITY();
END

-- Tickets (staff)
IF NOT EXISTS (SELECT 1 FROM ticketing.menus WHERE menu_code = 'tickets' AND deleted_at IS NULL)
BEGIN
  INSERT INTO ticketing.menus (
    menu_code, menu_name, menu_url, icon, parent_id, sort_order,
    show_sidebar, is_active, created_by, by_jobsite
  )
  VALUES (
    'tickets', 'Tickets', '/tickets', 'list',
    NULL, 5, 1, 1, 'system', 1
  );
END

-- Customers master
IF NOT EXISTS (SELECT 1 FROM ticketing.menus WHERE menu_code = 'customers_master' AND deleted_at IS NULL)
BEGIN
  INSERT INTO ticketing.menus (
    menu_code, menu_name, menu_url, icon, parent_id, sort_order,
    show_sidebar, is_active, created_by, by_jobsite
  )
  VALUES (
    'customers_master', 'Customers', '/customers', 'list',
    NULL, 6, 1, 1, 'system', 1
  );
END

-- Enum masters under admin_elements
IF NOT EXISTS (SELECT 1 FROM ticketing.menus WHERE menu_code = 'ticket_status_element' AND deleted_at IS NULL)
BEGIN
  INSERT INTO ticketing.menus (
    menu_code, menu_name, menu_url, icon, parent_id, sort_order,
    show_sidebar, is_active, created_by, by_jobsite
  )
  VALUES (
    'ticket_status_element', 'Ticket Status', '/master/enums/ticket_status', 'list',
    @parent_id, 30, 1, 1, 'system', 1
  );
END

IF NOT EXISTS (SELECT 1 FROM ticketing.menus WHERE menu_code = 'ticket_priority_element' AND deleted_at IS NULL)
BEGIN
  INSERT INTO ticketing.menus (
    menu_code, menu_name, menu_url, icon, parent_id, sort_order,
    show_sidebar, is_active, created_by, by_jobsite
  )
  VALUES (
    'ticket_priority_element', 'Ticket Priority', '/master/enums/ticket_priority', 'list',
    @parent_id, 31, 1, 1, 'system', 1
  );
END

IF NOT EXISTS (SELECT 1 FROM ticketing.menus WHERE menu_code = 'ticket_category_element' AND deleted_at IS NULL)
BEGIN
  INSERT INTO ticketing.menus (
    menu_code, menu_name, menu_url, icon, parent_id, sort_order,
    show_sidebar, is_active, created_by, by_jobsite
  )
  VALUES (
    'ticket_category_element', 'Ticket Category', '/master/enums/ticket_category', 'list',
    @parent_id, 32, 1, 1, 'system', 1
  );
END
GO

-- Full permissions for level_id = 1 (superadmin)
DECLARE @codes TABLE (menu_code VARCHAR(100));
INSERT INTO @codes (menu_code)
VALUES
  ('tickets'),
  ('customers_master'),
  ('ticket_status_element'),
  ('ticket_priority_element'),
  ('ticket_category_element');

DECLARE @menu_code VARCHAR(100);
DECLARE @menu_id INT;

DECLARE menu_cursor CURSOR FOR SELECT menu_code FROM @codes;
OPEN menu_cursor;
FETCH NEXT FROM menu_cursor INTO @menu_code;

WHILE @@FETCH_STATUS = 0
BEGIN
  SELECT @menu_id = id
  FROM ticketing.menus
  WHERE menu_code = @menu_code AND deleted_at IS NULL;

  IF @menu_id IS NOT NULL
     AND NOT EXISTS (
       SELECT 1
       FROM ticketing.menu_permissions
       WHERE level_id = 1
         AND menu_id = @menu_id
         AND deleted_at IS NULL
     )
  BEGIN
    INSERT INTO ticketing.menu_permissions (
      level_id, menu_id,
      can_read, can_insert, can_update, can_delete,
      can_approve, can_export, can_import,
      created_by, by_jobsite
    )
    VALUES (
      1, @menu_id,
      1, 1, 1, 1,
      0, 1, 1,
      'system', 1
    );
  END

  FETCH NEXT FROM menu_cursor INTO @menu_code;
END

CLOSE menu_cursor;
DEALLOCATE menu_cursor;
GO
