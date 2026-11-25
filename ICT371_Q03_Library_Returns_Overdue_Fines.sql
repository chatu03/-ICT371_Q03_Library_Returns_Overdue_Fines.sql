-- ICT371 Advanced Databases | Question 3
-- Library Returns and Overdue Fines
-- Run once in a database where you can create a fresh schema.
-- This script creates and uses ict371_q03.
-- The scheduler registration at the end is optional to execute.

BEGIN;

-- (a) Database and seed data
-- The six loans include a loan due today, an open overdue loan and a loan returned on
-- its due date. Run the two return calls after parts (b)–(d).
CREATE SCHEMA ict371_q03;
SET search_path = ict371_q03, pg_catalog;
SET TIME ZONE 'Africa/Lusaka';

CREATE TABLE books (
    book_id integer PRIMARY KEY,
    title text NOT NULL
);

CREATE TABLE loans (
    loan_id integer PRIMARY KEY,
    book_id integer NOT NULL REFERENCES books,
    borrower_name text NOT NULL,
    borrowed_on date NOT NULL CHECK (isfinite(borrowed_on)),
    due_on date NOT NULL CHECK (isfinite(due_on) AND due_on >= borrowed_on),
    returned_on date CHECK (isfinite(returned_on) AND returned_on >= borrowed_on),
    fine_amount numeric(12,2) NOT NULL DEFAULT 0
        CHECK (fine_amount >= 0 AND fine_amount <> 'NaN')
);

CREATE TABLE loan_audit (
    audit_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    loan_id integer NOT NULL REFERENCES loans,
    old_returned_on date,
    new_returned_on date,
    changed_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE overdue_summary (
    snapshot_date date PRIMARY KEY,
    overdue_count bigint NOT NULL CHECK (overdue_count >= 0),
    total_fine numeric NOT NULL CHECK (total_fine >= 0)
);

INSERT INTO books VALUES
    (1, 'Database Design'), (2, 'Computer Networks'), (3, 'Algorithm Basics');

INSERT INTO loans (loan_id, book_id, borrower_name, borrowed_on, due_on)
VALUES
    (1, 1, 'Ruth Banda', CURRENT_DATE - 14, CURRENT_DATE - 7),
    (2, 1, 'David Phiri', CURRENT_DATE - 7, CURRENT_DATE),
    (3, 2, 'Mary Zulu', CURRENT_DATE - 14, CURRENT_DATE - 7),
    (4, 2, 'Joseph Tembo', CURRENT_DATE - 14, CURRENT_DATE - 5),
    (5, 3, 'Grace Chanda', CURRENT_DATE - 1, CURRENT_DATE + 6),
    (6, 3, 'Peter Mwale', CURRENT_DATE - 10, CURRENT_DATE - 2);

-- (b) Function
-- LEAST caps the calculation at the return date when it exists. GREATEST gives zero
-- days for an on-time or early return.
CREATE FUNCTION fn_loan_fine(p_loan_id integer, p_as_of date)
RETURNS numeric LANGUAGE plpgsql SET search_path = ict371_q03, pg_catalog AS $$
DECLARE
    v_due date;
    v_returned date;
BEGIN
    IF p_as_of IS NULL OR NOT isfinite(p_as_of) THEN
        RAISE EXCEPTION 'A valid calculation date is required';
    END IF;

    SELECT due_on, returned_on INTO v_due, v_returned
    FROM loans WHERE loan_id = p_loan_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan ID: %', p_loan_id;
    END IF;

    RETURN 2.00 * GREATEST(
        LEAST(p_as_of, COALESCE(v_returned, p_as_of)) - v_due, 0
    );
END;
$$;

-- (c) Procedure
-- Lock the loan while checking and recording the return. One UPDATE saves the date and
-- final fine together.
CREATE PROCEDURE pr_return_loan(p_loan_id integer, p_returned_on date)
LANGUAGE plpgsql SET search_path = ict371_q03, pg_catalog AS $$
DECLARE
    v_borrowed date;
    v_returned date;
BEGIN
    SELECT borrowed_on, returned_on INTO v_borrowed, v_returned
    FROM loans WHERE loan_id = p_loan_id FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan ID: %', p_loan_id;
    END IF;
    IF v_returned IS NOT NULL THEN
        RAISE EXCEPTION 'Loan % has already been returned', p_loan_id;
    END IF;
    IF p_returned_on IS NULL OR NOT isfinite(p_returned_on)
       OR p_returned_on < v_borrowed THEN
        RAISE EXCEPTION 'Return date must be on or after borrowing';
    END IF;

    UPDATE loans
    SET returned_on = p_returned_on,
        fine_amount = fn_loan_fine(p_loan_id, p_returned_on)
    WHERE loan_id = p_loan_id;
END;
$$;

-- (d) Trigger
-- IS DISTINCT FROM detects a change from NULL to a date, from a date to NULL, or
-- between two different dates.
CREATE FUNCTION fn_audit_loan_return()
RETURNS trigger LANGUAGE plpgsql SET search_path = ict371_q03, pg_catalog AS $$
BEGIN
    INSERT INTO loan_audit (loan_id, old_returned_on, new_returned_on)
    VALUES (NEW.loan_id, OLD.returned_on, NEW.returned_on);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_audit_loan_return
AFTER UPDATE ON loans
FOR EACH ROW
WHEN (OLD.returned_on IS DISTINCT FROM NEW.returned_on)
EXECUTE FUNCTION fn_audit_loan_return();

-- (a) Deferred seed data, loaded after the routines and trigger
CALL pr_return_loan(3, CURRENT_DATE - 7);
CALL pr_return_loan(4, CURRENT_DATE - 2);

-- (e) View
-- On the seed date the view includes Ruth at K14.00 and Peter at K4.00. A loan due
-- today is excluded.
CREATE VIEW v_overdue_loans AS
SELECT b.title AS book_title, l.borrower_name, l.due_on,
       fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine
FROM loans AS l JOIN books AS b USING (book_id)
WHERE l.returned_on IS NULL AND l.due_on < CURRENT_DATE;

SELECT * FROM v_overdue_loans ORDER BY due_on;

-- (f) Index and execution plan
-- The partial index contains only unreturned loans. The matching query uses the same
-- partial predicate and filters by book_id.
CREATE INDEX idx_loans_open_book ON loans (book_id)
WHERE returned_on IS NULL;

EXPLAIN (COSTS OFF)
SELECT loan_id, borrower_name, due_on FROM loans
WHERE book_id = 1 AND returned_on IS NULL;

-- Plan observed on the seed dataset:
-- Seq Scan on loans
--   Filter: ((returned_on IS NULL) AND (book_id = 1))
-- Index plan observed when sequential scans were discouraged:
-- Index Scan using idx_loans_open_book on loans
--   Index Cond: (book_id = 1)

-- (g) Scheduled job
-- A loan is overdue on the snapshot date if it was due earlier and was still open at
-- the end of that date. A return recorded for a later date therefore counts as open in
-- a historical snapshot.
CREATE PROCEDURE pr_refresh_overdue(p_as_of date)
LANGUAGE plpgsql SET search_path = ict371_q03, pg_catalog AS $$
BEGIN
    IF p_as_of IS NULL OR NOT isfinite(p_as_of) THEN
        RAISE EXCEPTION 'A valid snapshot date is required';
    END IF;

    INSERT INTO overdue_summary (snapshot_date, overdue_count, total_fine)
    SELECT p_as_of, COUNT(*),
           COALESCE(SUM(fn_loan_fine(loan_id, p_as_of)), 0)
    FROM loans
    WHERE due_on < p_as_of
      AND (returned_on IS NULL OR returned_on > p_as_of)
    ON CONFLICT (snapshot_date) DO UPDATE
    SET overdue_count = EXCLUDED.overdue_count,
        total_fine = EXCLUDED.total_fine;
END;
$$;

COMMIT;

-- Manual verification. The rollback preserves the original seed state.
BEGIN;
CALL pr_refresh_overdue(CURRENT_DATE);
CALL pr_refresh_overdue(CURRENT_DATE);
SELECT * FROM overdue_summary;
ROLLBACK;

-- On the seed date the summary contains one row with 2 overdue loans and K18.00 in
-- fines. Mary’s final fine is K0.00 and Joseph’s is K6.00.

-- (g) Register the schedule when pg_cron is available.
-- Configure the server to preload pg_cron, set cron.database_name to this database and
-- set cron.timezone to Africa/Lusaka. Restart PostgreSQL, then select and run the
-- following block with its surrounding comment markers removed. Use an account allowed
-- to schedule and run the job.
/*
CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'ict371-q03',
    '10 0 * * *',
    $job$
    SET TIME ZONE 'Africa/Lusaka';
    CALL ict371_q03.pr_refresh_overdue(CURRENT_DATE);
    $job$
);
*/
