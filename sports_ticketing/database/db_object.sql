-- =============================================================================
-- SPORTS TICKETING MANAGEMENT SYSTEM
-- File: database/db_objects.sql
-- Run after schema.sql.
-- Order: indexes → views → functions → triggers → procedures → users
-- =============================================================================

USE sports_ticketing_db;

-- ============================================================
-- DATABASE CLEANUP SCRIPT 
-- ============================================================

-- Step 1: Disable foreign key constraints to allow truncation
SET FOREIGN_KEY_CHECKS = 0;

-- Step 2: Clear all transaction and infrastructure data
TRUNCATE TABLE TICKET;
TRUNCATE TABLE EVENT_SEAT;
TRUNCATE TABLE EVENT_ZONE;
TRUNCATE TABLE EVENT;
TRUNCATE TABLE BOX_OFFICE;
TRUNCATE TABLE CUSTOMER;
TRUNCATE TABLE SEAT;
TRUNCATE TABLE STADIUM;

-- Step 3: Re-enable foreign key constraints
SET FOREIGN_KEY_CHECKS = 1;

-- Verify Cleanup
SELECT 'Database successfully cleaned' AS Status;

-- Verify Cleanup
SELECT 'Database successfully cleaned' AS Status;

-- =============================================================================
-- 1. INDEXES
-- ALTER TABLE is used to add indexes safely.
-- MySQL shows a warning (not an error) if the index already exists.
-- =============================================================================

-- ALTER TABLE event_seat ADD INDEX idx_eventseat_status     (event_id, status);
-- ALTER TABLE ticket     ADD INDEX idx_ticket_customer      (customer_id);
-- ALTER TABLE event      ADD INDEX idx_event_status_date    (status, event_date);
-- ALTER TABLE ticket     ADD INDEX idx_ticket_status_expiry (status, expires_at);
-- ALTER TABLE event_zone ADD INDEX idx_eventzone_event      (event_id, seat_type);


-- =============================================================================
-- 2. VIEWS
-- =============================================================================

-- Events where every seat is booked
CREATE OR REPLACE VIEW v_sold_out_events AS
SELECT
    e.event_id,
    e.event_name,
    e.event_date,
    s.stadium_name,
    COUNT(es.event_seat_id)   AS total_seats,
    SUM(es.status = 'Booked') AS booked_seats
FROM event e
JOIN stadium s     ON s.stadium_id = e.stadium_id
JOIN event_seat es ON es.event_id  = e.event_id
GROUP BY e.event_id, e.event_name, e.event_date, s.stadium_name
HAVING booked_seats = total_seats;


-- Revenue summary per event
CREATE OR REPLACE VIEW v_revenue_by_event AS
SELECT
    e.event_id,
    e.event_name,
    e.event_date,
    s.stadium_name,
    COUNT(t.ticket_id)             AS tickets_sold,
    COALESCE(SUM(t.price_paid), 0) AS total_revenue,
    COALESCE(AVG(t.price_paid), 0) AS avg_price
FROM event e
JOIN stadium s          ON s.stadium_id    = e.stadium_id
LEFT JOIN event_seat es ON es.event_id     = e.event_id
LEFT JOIN ticket t      ON t.event_seat_id = es.event_seat_id
                       AND t.status        = 'Paid'
GROUP BY e.event_id, e.event_name, e.event_date, s.stadium_name;


-- Seat availability breakdown per zone per event
CREATE OR REPLACE VIEW v_seat_availability AS
SELECT
    e.event_id,
    e.event_name,
    s.stadium_name,
    ez.zone_name,
    ez.seat_type,
    ez.base_price,
    COUNT(es.event_seat_id)                                 AS total_seats,
    SUM(es.status = 'Available')                            AS available,
    SUM(es.status = 'Booked')                               AS booked,
    SUM(es.status = 'Locked')                               AS locked,
    SUM(es.status = 'Unavailable')                         AS unavailable,
    ROUND(SUM(es.status = 'Booked') / COUNT(*) * 100, 1)    AS sold_pct
FROM event e
JOIN stadium s      ON s.stadium_id = e.stadium_id
JOIN event_seat es  ON es.event_id  = e.event_id
JOIN event_zone ez  ON ez.zone_id   = es.zone_id 
GROUP BY e.event_id, e.event_name, s.stadium_name,
         ez.zone_name, ez.seat_type, ez.base_price;


-- Full purchase history per customer
CREATE OR REPLACE VIEW v_customer_history AS
SELECT
    c.customer_id,
    c.customer_name,
    c.email,
    e.event_name,
    e.event_date,
    s.stadium_name,
    ez.zone_name,
    seat.seat_name,
    t.price_paid,
    t.price_reason,
    t.status     AS ticket_status,
    t.created_at AS purchased_at,
    t.qr_code
FROM ticket t
JOIN customer c    ON c.customer_id    = t.customer_id
JOIN event_seat es ON es.event_seat_id = t.event_seat_id
JOIN event e       ON e.event_id       = es.event_id
JOIN stadium s     ON s.stadium_id     = e.stadium_id
JOIN seat          ON seat.seat_id     = es.seat_id
JOIN event_zone ez ON ez.event_id      = e.event_id
                  AND ez.seat_type     = seat.seat_type;


-- Tickets sold and revenue per box office channel
CREATE OR REPLACE VIEW v_boxoffice_revenue AS
SELECT
    bo.box_office_id,
    bo.office_name,
    bo.office_type,
    COUNT(t.ticket_id)             AS tickets_sold,
    COALESCE(SUM(t.price_paid), 0) AS total_revenue
FROM box_office bo
LEFT JOIN ticket t ON t.box_office_id = bo.box_office_id
                  AND t.status        = 'Paid'
GROUP BY bo.box_office_id, bo.office_name, bo.office_type;


-- =============================================================================
-- 3. FUNCTIONS
-- =============================================================================

DELIMITER $$

-- Returns total paid revenue for one event
DROP FUNCTION IF EXISTS fn_total_revenue$$
CREATE FUNCTION fn_total_revenue(p_event_id INT)
RETURNS DECIMAL(14,0)
DETERMINISTIC
READS SQL DATA
BEGIN
    DECLARE v_total DECIMAL(14,0);
    SELECT COALESCE(SUM(t.price_paid), 0) INTO v_total
    FROM   ticket t
    JOIN   event_seat es ON es.event_seat_id = t.event_seat_id
    WHERE  es.event_id = p_event_id
    AND    t.status    = 'Paid';
    RETURN v_total;
END$$


-- Returns number of paid tickets sold for one event
DROP FUNCTION IF EXISTS fn_tickets_sold$$
CREATE FUNCTION fn_tickets_sold(p_event_id INT)
RETURNS INT
DETERMINISTIC
READS SQL DATA
BEGIN
    DECLARE v_count INT;
    SELECT COUNT(*) INTO v_count
    FROM   ticket t
    JOIN   event_seat es ON es.event_seat_id = t.event_seat_id
    WHERE  es.event_id = p_event_id
    AND    t.status    = 'Paid';
    RETURN v_count;
END$$


-- Returns percentage of seats booked for one event
DROP FUNCTION IF EXISTS fn_sold_pct$$
CREATE FUNCTION fn_sold_pct(p_event_id INT)
RETURNS DECIMAL(5,2)
DETERMINISTIC
READS SQL DATA
BEGIN
    DECLARE v_total  INT;
    DECLARE v_booked INT;
    SELECT COUNT(*), SUM(status = 'Booked')
    INTO   v_total, v_booked
    FROM   event_seat
    WHERE  event_id = p_event_id;
    IF v_total = 0 THEN RETURN 0; END IF;
    RETURN ROUND(v_booked / v_total * 100, 2);
END$$

DELIMITER ;


-- =============================================================================
-- 4. TRIGGERS
-- =============================================================================

DELIMITER $$

-- When a ticket is marked Paid → set the seat to Booked
DROP TRIGGER IF EXISTS trg_ticket_paid$$
CREATE TRIGGER trg_ticket_paid
AFTER UPDATE ON ticket
FOR EACH ROW
BEGIN
    IF NEW.status = 'Paid' AND OLD.status != 'Paid' THEN
        UPDATE event_seat
        SET    status               = 'Booked',
               locked_until        = NULL,
               locked_by_ticket_id = NULL
        WHERE  event_seat_id = NEW.event_seat_id;
    END IF;
END$$


-- When a ticket is Cancelled or Expired → release the seat back to Available
DROP TRIGGER IF EXISTS trg_ticket_released$$
CREATE TRIGGER trg_ticket_released
AFTER UPDATE ON ticket
FOR EACH ROW
BEGIN
    IF NEW.status IN ('Cancelled', 'Expired')
    AND OLD.status NOT IN ('Cancelled', 'Expired') THEN
        UPDATE event_seat
        SET    status               = 'Available',
               locked_until        = NULL,
               locked_by_ticket_id = NULL
        WHERE  event_seat_id = NEW.event_seat_id;
    END IF;
END$$


-- When a seat is Booked → check if the entire event is now sold out
DROP TRIGGER IF EXISTS trg_check_soldout$$
CREATE TRIGGER trg_check_soldout
AFTER UPDATE ON event_seat
FOR EACH ROW
BEGIN
    DECLARE v_available INT;
    IF NEW.status = 'Booked' AND OLD.status != 'Booked' THEN
        SELECT COUNT(*) INTO v_available
        FROM   event_seat
        WHERE  event_id = NEW.event_id
        AND    status   = 'Available';
        IF v_available = 0 THEN
            UPDATE event
            SET    status = 'SoldOut'
            WHERE  event_id = NEW.event_id;
        END IF;
    END IF;
END$$

DELIMITER ;


-- =============================================================================
-- 5. STORED PROCEDURES
-- =============================================================================

DELIMITER $$

-- Lock a seat and create a Pending ticket in one atomic transaction.
-- Called by Python after the pricing engine calculates the final price.
-- OUT p_message returns: 'OK' | 'UNAVAILABLE: ...' | 'ERROR: ...'
DROP PROCEDURE IF EXISTS sp_book_ticket$$
CREATE PROCEDURE sp_book_ticket(
    IN  p_event_id      INT,
    IN  p_seat_id       INT,
    IN  p_customer_id   INT,
    IN  p_box_office_id INT,
    IN  p_price         DECIMAL(12,0),
    IN  p_price_reason  VARCHAR(255),
    OUT p_ticket_id     INT,
    OUT p_message       VARCHAR(100)
)
BEGIN
    DECLARE v_event_seat_id INT DEFAULT NULL;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SET p_ticket_id = NULL;
        SET p_message   = 'ERROR: Transaction failed';
    END;

    START TRANSACTION;

    -- Select and lock the row to block concurrent requests for the same seat
    SELECT event_seat_id INTO v_event_seat_id
    FROM   event_seat
    WHERE  event_id = p_event_id
    AND    seat_id  = p_seat_id
    AND    status   = 'Available'
    FOR UPDATE;

    IF v_event_seat_id IS NULL THEN
        ROLLBACK;
        SET p_ticket_id = NULL;
        SET p_message   = 'UNAVAILABLE: Seat already taken';
    ELSE
        -- Hold seat for 10 minutes
        UPDATE event_seat
        SET    status       = 'Locked',
               locked_until = DATE_ADD(NOW(), INTERVAL 10 MINUTE)
        WHERE  event_seat_id = v_event_seat_id;

        -- Create pending ticket
        INSERT INTO ticket (
            event_seat_id, customer_id, box_office_id,
            status, price_paid, price_reason,
            expires_at, qr_code
        ) VALUES (
            v_event_seat_id, p_customer_id, p_box_office_id,
            'Pending', p_price, p_price_reason,
            DATE_ADD(NOW(), INTERVAL 10 MINUTE),
            UUID()
        );

        SET p_ticket_id = LAST_INSERT_ID();

        -- Link the lock back to this ticket
        UPDATE event_seat
        SET    locked_by_ticket_id = p_ticket_id
        WHERE  event_seat_id       = v_event_seat_id;

        COMMIT;
        SET p_message = 'OK';
    END IF;
END$$


-- Release expired Pending tickets and free their seats.
-- Run every 60 seconds from Python cron job.
DROP PROCEDURE IF EXISTS sp_expire_locks$$
CREATE PROCEDURE sp_expire_locks()
BEGIN
    UPDATE event_seat es
    JOIN   ticket t ON t.event_seat_id = es.event_seat_id
    SET    es.status               = 'Available',
           es.locked_until         = NULL,
           es.locked_by_ticket_id  = NULL,
           t.status                = 'Expired'
    WHERE  t.status     = 'Pending'
    AND    t.expires_at < NOW();
END$$


-- Revenue report for all events at a given stadium.
DROP PROCEDURE IF EXISTS sp_revenue_summary$$
CREATE PROCEDURE sp_revenue_summary(IN p_stadium_id INT)
BEGIN
    SELECT
        e.event_id,
        e.event_name,
        e.event_date,
        fn_tickets_sold(e.event_id)  AS tickets_sold,
        fn_total_revenue(e.event_id) AS total_revenue,
        fn_sold_pct(e.event_id)      AS sold_pct
    FROM event e
    WHERE e.stadium_id = p_stadium_id
    ORDER BY e.event_date DESC;
END$$


-- Confirm payment for a Pending ticket → marks it Paid.
-- trg_ticket_paid fires automatically to update event_seat.
DROP PROCEDURE IF EXISTS sp_confirm_payment$$
CREATE PROCEDURE sp_confirm_payment(
    IN  p_ticket_id INT,
    OUT p_message   VARCHAR(100)
)
BEGIN
    DECLARE v_status VARCHAR(20);

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SET p_message = 'ERROR: Transaction failed';
    END;

    START TRANSACTION;

    SELECT status INTO v_status
    FROM   ticket
    WHERE  ticket_id = p_ticket_id
    FOR UPDATE;

    IF v_status != 'Pending' THEN
        ROLLBACK;
        SET p_message = CONCAT('INVALID: Ticket status is ', v_status);
    ELSE
        UPDATE ticket
        SET    status  = 'Paid',
               paid_at = NOW()
        WHERE  ticket_id = p_ticket_id;
        -- trg_ticket_paid fires here and marks the seat as Booked

        COMMIT;
        SET p_message = 'OK';
    END IF;
END$$


-- Cancel a Pending or Paid ticket.
-- trg_ticket_released fires automatically to release the seat.
DROP PROCEDURE IF EXISTS sp_cancel_ticket$$
CREATE PROCEDURE sp_cancel_ticket(
    IN  p_ticket_id INT,
    OUT p_message   VARCHAR(100)
)
BEGIN
    DECLARE v_status VARCHAR(20);

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SET p_message = 'ERROR: Transaction failed';
    END;

    START TRANSACTION;

    SELECT status INTO v_status
    FROM   ticket
    WHERE  ticket_id = p_ticket_id
    FOR UPDATE;

    IF v_status NOT IN ('Pending', 'Paid') THEN
        ROLLBACK;
        SET p_message = CONCAT('INVALID: Cannot cancel ticket with status ', v_status);
    ELSE
        UPDATE ticket
        SET    status = 'Cancelled'
        WHERE  ticket_id = p_ticket_id;
        -- trg_ticket_released fires here and releases the seat

        COMMIT;
        SET p_message = 'OK';
    END IF;
END$$

DELIMITER ;


-- =============================================================================
-- 6. USER ROLES
-- =============================================================================

-- Cashier: sell and cancel tickets; no access to revenue data
CREATE USER IF NOT EXISTS 'cashier'@'localhost' IDENTIFIED BY 'Cashier@2025';
GRANT SELECT          ON sports_ticketing_db.event             TO 'cashier'@'localhost';
GRANT SELECT          ON sports_ticketing_db.event_seat        TO 'cashier'@'localhost';
GRANT SELECT          ON sports_ticketing_db.event_zone        TO 'cashier'@'localhost';
GRANT SELECT          ON sports_ticketing_db.seat              TO 'cashier'@'localhost';
GRANT SELECT          ON sports_ticketing_db.stadium           TO 'cashier'@'localhost';
GRANT SELECT          ON sports_ticketing_db.customer          TO 'cashier'@'localhost';
GRANT SELECT, INSERT, UPDATE ON sports_ticketing_db.ticket     TO 'cashier'@'localhost';
GRANT SELECT          ON sports_ticketing_db.v_seat_availability  TO 'cashier'@'localhost';
GRANT SELECT          ON sports_ticketing_db.v_customer_history   TO 'cashier'@'localhost';
GRANT EXECUTE ON PROCEDURE sports_ticketing_db.sp_book_ticket     TO 'cashier'@'localhost';
GRANT EXECUTE ON PROCEDURE sports_ticketing_db.sp_cancel_ticket   TO 'cashier'@'localhost';
GRANT EXECUTE ON PROCEDURE sports_ticketing_db.sp_confirm_payment TO 'cashier'@'localhost';


-- Manager: read-only access to all tables and revenue reports
CREATE USER IF NOT EXISTS 'manager'@'localhost' IDENTIFIED BY 'Manager@2025';
GRANT SELECT          ON sports_ticketing_db.*                    TO 'manager'@'localhost';
GRANT EXECUTE ON PROCEDURE sports_ticketing_db.sp_revenue_summary TO 'manager'@'localhost';
GRANT EXECUTE ON FUNCTION  sports_ticketing_db.fn_total_revenue   TO 'manager'@'localhost';
GRANT EXECUTE ON FUNCTION  sports_ticketing_db.fn_tickets_sold    TO 'manager'@'localhost';
GRANT EXECUTE ON FUNCTION  sports_ticketing_db.fn_sold_pct        TO 'manager'@'localhost';


-- Admin: full access
CREATE USER IF NOT EXISTS 'admin_user'@'localhost' IDENTIFIED BY 'Admin@2025';
GRANT ALL PRIVILEGES ON sports_ticketing_db.* TO 'admin_user'@'localhost';

FLUSH PRIVILEGES;


