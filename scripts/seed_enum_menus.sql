-- Seed menus for fleet enum types (actual schema uses menu_url)
-- Parent: admin_elements (id resolved by menu_code)

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
GO

DECLARE @parent_id INT = (
  SELECT TOP 1 id FROM ticketing.menus
  WHERE menu_code = 'admin_elements' AND deleted_at IS NULL
);
DECLARE @master_id INT = (
  SELECT TOP 1 id FROM ticketing.menus
  WHERE menu_code = 'master_data' AND deleted_at IS NULL
);

-- Equipments (master)
IF NOT EXISTS (SELECT 1 FROM ticketing.menus WHERE menu_code = 'equipments' AND deleted_at IS NULL)
BEGIN
  INSERT INTO ticketing.menus (
    menu_code, menu_name, menu_url, icon, parent_id, sort_order,
    show_sidebar, is_active, created_by, by_jobsite
  )
  VALUES (
    'equipments', 'Equipments', '/equipments', 'list',
    @master_id, 10, 1, 1, 'system', 1
  );
END

-- Enum type menus
IF NOT EXISTS (SELECT 1 FROM ticketing.menus WHERE menu_code = 'pit_element' AND deleted_at IS NULL)
BEGIN
  INSERT INTO ticketing.menus (
    menu_code, menu_name, menu_url, icon, parent_id, sort_order,
    show_sidebar, is_active, created_by, by_jobsite
  )
  VALUES (
    'pit_element', 'Pit', '/master/enums/pit', 'list',
    @parent_id, 20, 1, 1, 'system', 1
  );
END

IF NOT EXISTS (SELECT 1 FROM ticketing.menus WHERE menu_code = 'equipment_type_element' AND deleted_at IS NULL)
BEGIN
  INSERT INTO ticketing.menus (
    menu_code, menu_name, menu_url, icon, parent_id, sort_order,
    show_sidebar, is_active, created_by, by_jobsite
  )
  VALUES (
    'equipment_type_element', 'Equipment Type', '/master/enums/equipment_type', 'list',
    @parent_id, 21, 1, 1, 'system', 1
  );
END

IF NOT EXISTS (SELECT 1 FROM ticketing.menus WHERE menu_code = 'equipment_status_element' AND deleted_at IS NULL)
BEGIN
  INSERT INTO ticketing.menus (
    menu_code, menu_name, menu_url, icon, parent_id, sort_order,
    show_sidebar, is_active, created_by, by_jobsite
  )
  VALUES (
    'equipment_status_element', 'Equipment Status', '/master/enums/equipment_status', 'list',
    @parent_id, 22, 1, 1, 'system', 1
  );
END
GO

-- Full permissions for level_id = 1 (superadmin)
DECLARE @codes TABLE (menu_code VARCHAR(100));
INSERT INTO @codes (menu_code)
VALUES
  ('equipments'),
  ('pit_element'),
  ('equipment_type_element'),
  ('equipment_status_element'),
  ('level_user_control');

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
      can_approve, can_export,
      created_by, by_jobsite
    )
    VALUES (
      1, @menu_id,
      1, 1, 1, 1,
      0, 1,
      'system', 1
    );
  END

  FETCH NEXT FROM menu_cursor INTO @menu_code;
END

CLOSE menu_cursor;
DEALLOCATE menu_cursor;
GO
