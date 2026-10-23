-- =============================================
-- Seed: ticket enums (status / priority / category)
-- Run AFTER enums.sql
-- =============================================

-- Ticket statuses
IF NOT EXISTS (SELECT 1 FROM ticketing.enums WHERE deleted_at IS NULL AND type = 'ticket_status' AND code = 'new')
    INSERT INTO ticketing.enums (code, name, category, category_description, type, include)
    VALUES ('new', 'New', 'ticket_status', 'Ticket status', 'ticket_status', 1);

IF NOT EXISTS (SELECT 1 FROM ticketing.enums WHERE deleted_at IS NULL AND type = 'ticket_status' AND code = 'waiting_reply')
    INSERT INTO ticketing.enums (code, name, category, category_description, type, include)
    VALUES ('waiting_reply', 'Waiting Staff Reply', 'ticket_status', 'Ticket status', 'ticket_status', 1);

IF NOT EXISTS (SELECT 1 FROM ticketing.enums WHERE deleted_at IS NULL AND type = 'ticket_status' AND code = 'replied')
    INSERT INTO ticketing.enums (code, name, category, category_description, type, include)
    VALUES ('replied', 'Staff Replied', 'ticket_status', 'Ticket status', 'ticket_status', 1);

IF NOT EXISTS (SELECT 1 FROM ticketing.enums WHERE deleted_at IS NULL AND type = 'ticket_status' AND code = 'in_progress')
    INSERT INTO ticketing.enums (code, name, category, category_description, type, include)
    VALUES ('in_progress', 'In Progress', 'ticket_status', 'Ticket status', 'ticket_status', 1);

IF NOT EXISTS (SELECT 1 FROM ticketing.enums WHERE deleted_at IS NULL AND type = 'ticket_status' AND code = 'on_hold')
    INSERT INTO ticketing.enums (code, name, category, category_description, type, include)
    VALUES ('on_hold', 'On Hold', 'ticket_status', 'Ticket status', 'ticket_status', 1);

IF NOT EXISTS (SELECT 1 FROM ticketing.enums WHERE deleted_at IS NULL AND type = 'ticket_status' AND code = 'resolved')
    INSERT INTO ticketing.enums (code, name, category, category_description, type, include)
    VALUES ('resolved', 'Resolved', 'ticket_status', 'Ticket status', 'ticket_status', 1);
GO

-- Ticket priorities
IF NOT EXISTS (SELECT 1 FROM ticketing.enums WHERE deleted_at IS NULL AND type = 'ticket_priority' AND code = 'critical')
    INSERT INTO ticketing.enums (code, name, category, category_description, type, include)
    VALUES ('critical', 'Critical', 'ticket_priority', 'Ticket priority', 'ticket_priority', 1);

IF NOT EXISTS (SELECT 1 FROM ticketing.enums WHERE deleted_at IS NULL AND type = 'ticket_priority' AND code = 'high')
    INSERT INTO ticketing.enums (code, name, category, category_description, type, include)
    VALUES ('high', 'High', 'ticket_priority', 'Ticket priority', 'ticket_priority', 1);

IF NOT EXISTS (SELECT 1 FROM ticketing.enums WHERE deleted_at IS NULL AND type = 'ticket_priority' AND code = 'medium')
    INSERT INTO ticketing.enums (code, name, category, category_description, type, include)
    VALUES ('medium', 'Medium', 'ticket_priority', 'Ticket priority', 'ticket_priority', 1);

IF NOT EXISTS (SELECT 1 FROM ticketing.enums WHERE deleted_at IS NULL AND type = 'ticket_priority' AND code = 'low')
    INSERT INTO ticketing.enums (code, name, category, category_description, type, include)
    VALUES ('low', 'Low', 'ticket_priority', 'Ticket priority', 'ticket_priority', 1);
GO

-- Ticket categories (adjust to the product's real support areas)
IF NOT EXISTS (SELECT 1 FROM ticketing.enums WHERE deleted_at IS NULL AND type = 'ticket_category' AND code = 'it_support')
    INSERT INTO ticketing.enums (code, name, category, category_description, type, include)
    VALUES ('it_support', 'IT Support', 'ticket_category', 'Ticket category', 'ticket_category', 1);

IF NOT EXISTS (SELECT 1 FROM ticketing.enums WHERE deleted_at IS NULL AND type = 'ticket_category' AND code = 'hardware')
    INSERT INTO ticketing.enums (code, name, category, category_description, type, include)
    VALUES ('hardware', 'Hardware', 'ticket_category', 'Ticket category', 'ticket_category', 1);

IF NOT EXISTS (SELECT 1 FROM ticketing.enums WHERE deleted_at IS NULL AND type = 'ticket_category' AND code = 'network')
    INSERT INTO ticketing.enums (code, name, category, category_description, type, include)
    VALUES ('network', 'Network', 'ticket_category', 'Ticket category', 'ticket_category', 1);

IF NOT EXISTS (SELECT 1 FROM ticketing.enums WHERE deleted_at IS NULL AND type = 'ticket_category' AND code = 'general')
    INSERT INTO ticketing.enums (code, name, category, category_description, type, include)
    VALUES ('general', 'General', 'ticket_category', 'Ticket category', 'ticket_category', 1);
GO
