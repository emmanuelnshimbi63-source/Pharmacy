
Question 1: Pharmacy Stock and Daily Sales

(a) DATABASE AND SEED DATA
Fresh schema (DROP lets you rerun the whole file safely)
DROP SCHEMA IF EXISTS q1_pharmacy CASCADE;
CREATE SCHEMA q1_pharmacy;
SET search_path TO q1_pharmacy;

Medicines: price must be above 0, stock cannot go below 0
CREATE TABLE medicines (
    medicine_id   SERIAL PRIMARY KEY,
    medicine_name VARCHAR(100) NOT NULL,
    unit_price    NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    stock_qty     INTEGER NOT NULL CHECK (stock_qty >= 0)
);

Sales: stores the price at the time of sale
CREATE TABLE sales (
    sale_id     SERIAL PRIMARY KEY,
    medicine_id INTEGER NOT NULL REFERENCES medicines(medicine_id),
    quantity    INTEGER NOT NULL CHECK (quantity > 0),
    unit_price  NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    sold_on     DATE NOT NULL DEFAULT CURRENT_DATE
);

Stock history: filled automatically by the trigger
CREATE TABLE stock_audit (
    audit_id    SERIAL PRIMARY KEY,
    medicine_id INTEGER NOT NULL REFERENCES medicines(medicine_id),
    old_qty     INTEGER NOT NULL,
    new_qty     INTEGER NOT NULL,
    changed_at  TIMESTAMP NOT NULL DEFAULT now()
);

Daily totals: one row per day
CREATE TABLE daily_sales (
    sales_date   DATE PRIMARY KEY,
    total_qty    INTEGER NOT NULL,
    total_amount NUMERIC(12,2) NOT NULL
);

Seed data: 3 medicines
INSERT INTO medicines (medicine_name, unit_price, stock_qty) VALUES
('Paracetamol', 2.50, 100),
('Amoxicillin', 8.00, 50),
('Ibuprofen',   4.00, 30);

(b) FUNCTION: price x quantity
CREATE OR REPLACE FUNCTION fn_sale_value(p_medicine_id INT, p_quantity INT)
RETURNS NUMERIC AS $$
DECLARE v_price NUMERIC;
BEGIN
    Reject bad quantity
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Quantity must be positive';
    END IF;
    Find the current price
    SELECT unit_price INTO v_price
    FROM medicines WHERE medicine_id = p_medicine_id;
    Reject unknown medicine
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine %', p_medicine_id;
    END IF;
    RETURN v_price * p_quantity;
END;
$$ LANGUAGE plpgsql;

SELECT fn_sale_value(1, 4);   -- expect 10.00

(c) PROCEDURE: record a sale
Checks stock, saves the sale with the current price, deducts stock once.
Any error cancels everything, so the tables stay unchanged.
CREATE OR REPLACE PROCEDURE pr_record_sale(p_medicine_id INT, p_quantity INT, p_sold_on DATE)
LANGUAGE plpgsql AS $$
DECLARE v_price NUMERIC; v_stock INT;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Quantity must be positive';
    END IF;

    Lock the row so two sales cannot overlap
    SELECT unit_price, stock_qty INTO v_price, v_stock
    FROM medicines WHERE medicine_id = p_medicine_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine %', p_medicine_id;
    END IF;

    IF v_stock < p_quantity THEN
        RAISE EXCEPTION 'Not enough stock: have %, need %', v_stock, p_quantity;
    END IF;

    Save the sale with the current price
    INSERT INTO sales (medicine_id, quantity, unit_price, sold_on)
    VALUES (p_medicine_id, p_quantity, v_price, COALESCE(p_sold_on, CURRENT_DATE));

    Deduct stock exactly once
    UPDATE medicines SET stock_qty = stock_qty - p_quantity
    WHERE medicine_id = p_medicine_id;
END;
$$;

(d) TRIGGER: log stock changes
Writes a history row only when stock_qty really changes
CREATE OR REPLACE FUNCTION trg_stock_audit_fn()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.stock_qty IS DISTINCT FROM OLD.stock_qty THEN
        INSERT INTO stock_audit (medicine_id, old_qty, new_qty)
        VALUES (OLD.medicine_id, OLD.stock_qty, NEW.stock_qty);
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_stock_audit
AFTER UPDATE ON medicines
FOR EACH ROW
EXECUTE FUNCTION trg_stock_audit_fn();

LOAD 6 SALES (through the procedure, after the trigger exists)
CALL pr_record_sale(1, 10, '2026-11-20');
CALL pr_record_sale(1, 20, '2026-11-21');
CALL pr_record_sale(2,  5, '2026-11-21');
CALL pr_record_sale(3, 10, '2026-11-22');
CALL pr_record_sale(3,  8, '2026-11-23');
CALL pr_record_sale(3,  5, '2026-11-23');

SELECT * FROM sales;
SELECT * FROM stock_audit;    -- 6 rows
SELECT * FROM medicines;

Invalid sale test: run this line alone. It errors and changes nothing.
CALL pr_record_sale(3, 500, CURRENT_DATE);

(e) VIEW: medicines with stock below 10
CREATE VIEW v_low_stock AS
SELECT medicine_name, unit_price, stock_qty AS remaining_stock
FROM medicines
WHERE stock_qty < 10;

SELECT * FROM v_low_stock;    -- Ibuprofen, 7 left

--(f) INDEX: one medicine's sales in a date range
-- Justification: the query filters medicine_id (equality) then sold_on (range).
-- An index on (medicine_id, sold_on) jumps straight to those rows, already
-- sorted by date, so the whole table is not read.
CREATE INDEX idx_sales_medicine_date ON sales (medicine_id, sold_on);

SET enable_seqscan = off;     -- only because the table is tiny
EXPLAIN
SELECT * FROM sales
WHERE medicine_id = 3
  AND sold_on BETWEEN '2026-11-20' AND '2026-11-30';
SET enable_seqscan = on;

(g) SCHEDULED JOB: daily totals
ON CONFLICT DO UPDATE replaces the totals, so reruns never double-count
CREATE OR REPLACE PROCEDURE pr_refresh_sales(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO daily_sales (sales_date, total_qty, total_amount)
    SELECT p_day,
           COALESCE(SUM(quantity), 0),
           COALESCE(SUM(quantity * unit_price), 0)
    FROM sales
    WHERE sold_on = p_day
    ON CONFLICT (sales_date) DO UPDATE
    SET total_qty    = EXCLUDED.total_qty,
        total_amount = EXCLUDED.total_amount;
END;
$$;

CALL pr_refresh_sales('2026-11-21');
CALL pr_refresh_sales('2026-11-21');   -- rerun: still one row
SELECT * FROM daily_sales;             -- qty 25, amount 90.00

Schedule: every day at 00:15 for the previous day (needs pg_cron)
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule(
    'refresh_sales_daily',
    '15 0 * * *',
    $$CALL q1_pharmacy.pr_refresh_sales(CURRENT_DATE - 1)$$
);
SELECT * FROM cron.job;