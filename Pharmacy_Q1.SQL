
DROP DATABASE IF EXISTS pharmacy_db;
CREATE DATABASE pharmacy_db;
USE pharmacy_db;

-- =====================================================================
-- (a) TABLES
-- =====================================================================
CREATE TABLE medicines (
    medicine_id   INT AUTO_INCREMENT PRIMARY KEY,
    medicine_name VARCHAR(100)  NOT NULL UNIQUE,
    unit_price    DECIMAL(10,2) NOT NULL,
    stock_qty     INT           NOT NULL DEFAULT 0,
    CONSTRAINT chk_med_price CHECK (unit_price > 0),
    CONSTRAINT chk_med_stock CHECK (stock_qty >= 0)
) ENGINE=InnoDB;

CREATE TABLE sales (
    sale_id     INT AUTO_INCREMENT PRIMARY KEY,
    medicine_id INT           NOT NULL,
    quantity    INT           NOT NULL,
    unit_price  DECIMAL(10,2) NOT NULL,      -- price at time of sale
    sold_on     DATE          NOT NULL,
    CONSTRAINT fk_sales_medicine FOREIGN KEY (medicine_id)
        REFERENCES medicines (medicine_id),
    CONSTRAINT chk_sale_qty   CHECK (quantity > 0),
    CONSTRAINT chk_sale_price CHECK (unit_price > 0)
) ENGINE=InnoDB;

CREATE TABLE stock_audit (
    audit_id    INT AUTO_INCREMENT PRIMARY KEY,
    medicine_id INT      NOT NULL,
    old_qty     INT      NOT NULL,
    new_qty     INT      NOT NULL,
    changed_at  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_audit_medicine FOREIGN KEY (medicine_id)
        REFERENCES medicines (medicine_id)
) ENGINE=InnoDB;

CREATE TABLE daily_sales (
    sales_date   DATE          PRIMARY KEY,
    total_qty    INT           NOT NULL DEFAULT 0,
    total_amount DECIMAL(12,2) NOT NULL DEFAULT 0.00
) ENGINE=InnoDB;

-- Seed medicines (inserts are not audited: the trigger is AFTER UPDATE only)
INSERT INTO medicines (medicine_name, unit_price, stock_qty) VALUES
    ('Paracetamol 500mg', 2.50, 100),
    ('Amoxicillin 250mg', 8.75,  40),
    ('Ibuprofen 400mg',   4.20,  25),
    ('Cetirizine 10mg',   3.10,  15);

DELIMITER $$

-- =====================================================================
-- (b) FUNCTION
-- =====================================================================
CREATE FUNCTION fn_sale_value(p_medicine_id INT, p_quantity INT)
RETURNS DECIMAL(12,2)
READS SQL DATA
BEGIN
    DECLARE v_price DECIMAL(10,2);

    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Quantity must be a positive number';
    END IF;

    SET v_price = (SELECT unit_price FROM medicines
                   WHERE medicine_id = p_medicine_id);

    IF v_price IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Unknown medicine';
    END IF;

    RETURN v_price * p_quantity;
END$$

-- =====================================================================
-- (c) PROCEDURE  (atomic: all-or-nothing)
-- =====================================================================
CREATE PROCEDURE pr_record_sale(
    IN p_medicine_id INT,
    IN p_quantity    INT,
    IN p_sold_on     DATE
)
BEGIN
    DECLARE v_stock INT;
    DECLARE v_price DECIMAL(10,2);

    -- Any error: undo everything, then re-raise it
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Quantity must be a positive number';
    END IF;
    IF p_sold_on IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Sale date is required';
    END IF;

    START TRANSACTION;

    -- Lock the row so two simultaneous sales cannot oversell
    SELECT stock_qty, unit_price
      INTO v_stock, v_price
      FROM medicines
     WHERE medicine_id = p_medicine_id
       FOR UPDATE;

    IF v_stock IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Unknown medicine';
    END IF;
    IF v_stock < p_quantity THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Insufficient stock';
    END IF;

    INSERT INTO sales (medicine_id, quantity, unit_price, sold_on)
    VALUES (p_medicine_id, p_quantity, v_price, p_sold_on);

    UPDATE medicines                      -- deducted exactly once
       SET stock_qty = stock_qty - p_quantity
     WHERE medicine_id = p_medicine_id;

    COMMIT;
END$$

-- =====================================================================
-- (d) TRIGGER
-- =====================================================================
CREATE TRIGGER trg_medicines_stock_audit
AFTER UPDATE ON medicines
FOR EACH ROW
BEGIN
    IF NOT (OLD.stock_qty <=> NEW.stock_qty) THEN
        INSERT INTO stock_audit (medicine_id, old_qty, new_qty)
        VALUES (OLD.medicine_id, OLD.stock_qty, NEW.stock_qty);
    END IF;
END$$

-- =====================================================================
-- (g) REFRESH PROCEDURE  (idempotent)
-- =====================================================================
CREATE PROCEDURE pr_refresh_sales(IN p_day DATE)
BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    IF p_day IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Day is required';
    END IF;

    START TRANSACTION;

    DELETE FROM daily_sales WHERE sales_date = p_day;   -- replace, never add

    INSERT INTO daily_sales (sales_date, total_qty, total_amount)
    SELECT p_day,
           COALESCE(SUM(quantity), 0),
           COALESCE(SUM(quantity * unit_price), 0)
      FROM sales
     WHERE sold_on = p_day;

    COMMIT;
END$$

DELIMITER ;

-- =====================================================================
-- (e) VIEW
-- =====================================================================
CREATE VIEW v_low_stock AS
SELECT medicine_id, medicine_name, unit_price, stock_qty
  FROM medicines
 WHERE stock_qty < 10;

-- =====================================================================
-- (f) INDEX
-- Equality column first (medicine_id), range column second (sold_on):
-- MySQL jumps to one medicine and reads only the date slice, in order.
-- It also replaces the single-column FK index on medicine_id.
-- =====================================================================
CREATE INDEX idx_sales_medicine_date ON sales (medicine_id, sold_on);

-- =====================================================================
-- (a) SEED SALES - six valid sales through the procedure
-- =====================================================================
CALL pr_record_sale(1, 10, '2026-11-22');
CALL pr_record_sale(2,  5, '2026-11-22');
CALL pr_record_sale(3,  8, '2026-11-23');
CALL pr_record_sale(4,  6, '2026-11-23');   -- Cetirizine drops to 9
CALL pr_record_sale(1, 20, '2026-11-23');
CALL pr_record_sale(3,  2, '2026-11-24');

-- =====================================================================
-- TESTS / DEMONSTRATIONS
-- =====================================================================
-- (b)
SELECT fn_sale_value(2, 3) AS value_3_amoxicillin;      -- 26.25
-- SELECT fn_sale_value(99, 1);   -- error: Unknown medicine
-- SELECT fn_sale_value(1, 0);    -- error: Quantity must be positive

-- (c) invalid sales (run one at a time; each errors and changes nothing)
-- CALL pr_record_sale(4, 500, '2026-11-24');   -- Insufficient stock
-- CALL pr_record_sale(99, 1,  '2026-11-24');   -- Unknown medicine
-- CALL pr_record_sale(1, -5,  '2026-11-24');   -- Invalid quantity

-- (d) audit history
SELECT * FROM stock_audit ORDER BY audit_id;

-- (e) view after the sales
SELECT * FROM v_low_stock;

-- (f) EXPLAIN
ANALYZE TABLE sales;
EXPLAIN
SELECT sale_id, quantity, unit_price, sold_on
  FROM sales
 WHERE medicine_id = 1
   AND sold_on BETWEEN '2026-11-22' AND '2026-11-24';

-- (g) run twice: totals must be identical (no double counting)
CALL pr_refresh_sales('2026-11-23');
CALL pr_refresh_sales('2026-11-23');
CALL pr_refresh_sales('2026-11-22');
SELECT * FROM daily_sales ORDER BY sales_date;

-- Scheduled job: every day at 00:15, refresh the previous day
SET GLOBAL event_scheduler = ON;

CREATE EVENT ev_refresh_sales_daily
ON SCHEDULE EVERY 1 DAY
STARTS (TIMESTAMP(CURRENT_DATE) + INTERVAL 1 DAY + INTERVAL 15 MINUTE)
DO CALL pr_refresh_sales(CURRENT_DATE - INTERVAL 1 DAY);

SHOW EVENTS FROM pharmacy_db;