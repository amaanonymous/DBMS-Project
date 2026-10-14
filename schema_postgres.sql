-- Cinema DBMS: PostgreSQL version of the schema, rules, indexes, views and queries
-- Run in psql:  psql -d yourdb -f schema_postgres.sql   (the sections are in order)
-- The SQLite files used by server.py are schema.sql and seed.sql.

-- ===== Tables =====
CREATE TABLE cinema (cinema_id SERIAL PRIMARY KEY, name TEXT NOT NULL, location TEXT);
CREATE TABLE screen (
  screen_id SERIAL PRIMARY KEY,
  cinema_id INT NOT NULL REFERENCES cinema,
  name TEXT NOT NULL,
  screen_type TEXT CHECK (screen_type IN ('2D','3D','IMAX')),
  capacity INT CHECK (capacity > 0));
CREATE TABLE seat (
  seat_id SERIAL PRIMARY KEY,
  screen_id INT NOT NULL REFERENCES screen,
  seat_row CHAR(1), seat_number INT, seat_type TEXT,
  UNIQUE (screen_id, seat_row, seat_number));
CREATE TABLE movie (movie_id SERIAL PRIMARY KEY, title TEXT NOT NULL,
  duration_min INT, genre TEXT, language TEXT);
CREATE TABLE customer (customer_id SERIAL PRIMARY KEY,
  email TEXT UNIQUE NOT NULL, first_name TEXT, last_name TEXT, phone TEXT);

-- ===== No overlap =====
-- Rule 2: no two screenings overlap on one screen,
-- including a 20 minute cleaning buffer
CREATE EXTENSION btree_gist;

CREATE TABLE screening (
  screening_id SERIAL PRIMARY KEY,
  movie_id  INT NOT NULL REFERENCES movie,
  screen_id INT NOT NULL REFERENCES screen,
  start_time TIMESTAMPTZ NOT NULL,
  end_time   TIMESTAMPTZ NOT NULL,
  base_price NUMERIC(8,2),
  CHECK (end_time > start_time),
  CONSTRAINT screening_no_overlap
    EXCLUDE USING gist (
      screen_id WITH =,
      tstzrange(start_time, end_time + INTERVAL '20 minutes') WITH &&));

-- ===== No double booking =====
-- Rule 1: a seat is assigned once per screening
CREATE TABLE booking (
  booking_id SERIAL PRIMARY KEY,
  customer_id  INT NOT NULL REFERENCES customer,
  screening_id INT NOT NULL REFERENCES screening,
  booking_time TIMESTAMPTZ DEFAULT now(),
  total_amount NUMERIC(8,2) CHECK (total_amount >= 0),
  status TEXT CHECK (status IN ('CONFIRMED','CANCELLED')));

CREATE TABLE booked_seat (
  booking_id   INT REFERENCES booking ON DELETE CASCADE,
  seat_id      INT REFERENCES seat,
  screening_id INT NOT NULL REFERENCES screening,
  PRIMARY KEY (booking_id, seat_id),
  CONSTRAINT booked_seat_screening_seat_key
    UNIQUE (screening_id, seat_id));

-- Concurrency: lock the rows while booking
BEGIN;
SELECT * FROM screening WHERE screening_id = 101 FOR UPDATE;
-- insert booking + booked_seat rows, then
COMMIT;

-- ===== Refund and audit =====
-- Rule 3: refund limits and a permanent trail
ALTER TABLE booking
  ADD COLUMN cancelled_at TIMESTAMPTZ,
  ADD COLUMN refund_amount NUMERIC(8,2) DEFAULT 0,
  ADD CONSTRAINT refund_within_total
    CHECK (refund_amount >= 0 AND refund_amount <= total_amount),
  ADD CONSTRAINT cancel_once
    CHECK ((status = 'CANCELLED') = (cancelled_at IS NOT NULL));

CREATE TABLE audit_log (
  log_id BIGSERIAL PRIMARY KEY,
  booking_id INT REFERENCES booking,
  action TEXT NOT NULL,
  detail TEXT,
  logged_at TIMESTAMPTZ DEFAULT now());

-- ===== Tickets and payments =====
-- Tickets, concessions, payments, cancellations and refunds
CREATE TABLE ticket (
  ticket_id    SERIAL PRIMARY KEY,
  booking_id   INT  NOT NULL,
  seat_id      INT  NOT NULL,
  screening_id INT  NOT NULL REFERENCES screening,
  ticket_code  TEXT NOT NULL UNIQUE,
  status       TEXT NOT NULL DEFAULT 'VALID' CHECK (status IN ('VALID','VOID','USED')),
  FOREIGN KEY (booking_id, seat_id) REFERENCES booked_seat);

CREATE TABLE concession_item (
  item_id   SERIAL PRIMARY KEY,
  name      TEXT NOT NULL UNIQUE,
  category  TEXT NOT NULL CHECK (category IN ('Snacks','Drinks','Combos')),
  price     NUMERIC(8,2) NOT NULL CHECK (price > 0),
  is_active BOOLEAN NOT NULL DEFAULT TRUE);

CREATE TABLE orders (
  order_id     SERIAL PRIMARY KEY,
  booking_id   INT REFERENCES booking,          -- NULL for counter sales
  customer_id  INT NOT NULL REFERENCES customer,
  total_amount NUMERIC(8,2) NOT NULL CHECK (total_amount >= 0),
  ordered_at   TIMESTAMPTZ NOT NULL DEFAULT now());

CREATE TABLE order_item (
  order_id   INT REFERENCES orders ON DELETE CASCADE,
  item_id    INT REFERENCES concession_item,
  quantity   INT NOT NULL CHECK (quantity > 0),     -- positive quantity rule
  unit_price NUMERIC(8,2) NOT NULL CHECK (unit_price > 0),
  PRIMARY KEY (order_id, item_id));

CREATE TABLE payment (
  payment_id SERIAL PRIMARY KEY,
  booking_id INT REFERENCES booking,
  order_id   INT REFERENCES orders,
  method     TEXT NOT NULL CHECK (method IN ('UPI','Card','Cash','Net Banking')),
  amount     NUMERIC(8,2) NOT NULL CHECK (amount > 0),
  status     TEXT NOT NULL DEFAULT 'PAID'
             CHECK (status IN ('PAID','PART REFUNDED','REFUNDED')),
  paid_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (booking_id IS NOT NULL OR order_id IS NOT NULL));

CREATE TABLE cancellation (
  cancellation_id SERIAL PRIMARY KEY,
  booking_id      INT NOT NULL UNIQUE REFERENCES booking,   -- cancel only once
  cancelled_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  hours_before    NUMERIC(5,1) NOT NULL,
  refund_pct      INT NOT NULL CHECK (refund_pct IN (0, 50, 100)));  -- policy

CREATE TABLE refund (
  refund_id       SERIAL PRIMARY KEY,
  cancellation_id INT NOT NULL UNIQUE REFERENCES cancellation,
  payment_id      INT NOT NULL REFERENCES payment,
  amount          NUMERIC(8,2) NOT NULL CHECK (amount > 0),
  refunded_at     TIMESTAMPTZ NOT NULL DEFAULT now());

-- Refund limit: a refund can never exceed what was paid
CREATE FUNCTION check_refund_limit() RETURNS trigger AS $$
BEGIN
  IF NEW.amount > (SELECT amount FROM payment WHERE payment_id = NEW.payment_id) THEN
    RAISE EXCEPTION 'refund exceeds amount paid';
  END IF;
  RETURN NEW;
END $$ LANGUAGE plpgsql;
CREATE TRIGGER refund_limit BEFORE INSERT ON refund
  FOR EACH ROW EXECUTE FUNCTION check_refund_limit();

-- ===== Indexes =====
-- Indexes on frequently searched attributes
CREATE INDEX idx_screening_screen_time ON screening (screen_id, start_time);
CREATE INDEX idx_screening_movie       ON screening (movie_id);
CREATE INDEX idx_booking_customer      ON booking (customer_id);
CREATE INDEX idx_booking_screening     ON booking (screening_id, status);
CREATE INDEX idx_payment_booking       ON payment (booking_id);
CREATE INDEX idx_orders_booking        ON orders (booking_id);
CREATE UNIQUE INDEX idx_customer_email ON customer (lower(email));

-- booked_seat (screening_id, seat_id) is already indexed by its UNIQUE constraint,
-- so "which seats are taken for this show?" is an index lookup.

EXPLAIN ANALYZE
SELECT seat_id FROM booked_seat WHERE screening_id = 101;
-- Index Scan using booked_seat_screening_seat_key

-- ===== Views =====
-- Views for reporting
CREATE VIEW v_show_occupancy AS
SELECT s.screening_id, m.title, sc.name AS screen, s.start_time,
       COUNT(bs.seat_id) AS seats_sold, sc.capacity,
       ROUND(100.0 * COUNT(bs.seat_id) / sc.capacity, 1) AS occupancy_pct
FROM screening s
JOIN movie  m  USING (movie_id)
JOIN screen sc USING (screen_id)
LEFT JOIN booked_seat bs USING (screening_id)
GROUP BY s.screening_id, m.title, sc.name, s.start_time, sc.capacity;

CREATE VIEW v_movie_performance AS
SELECT m.title, COUNT(DISTINCT s.screening_id) AS shows,
       COALESCE(SUM(b.total_amount), 0) AS revenue
FROM movie m
LEFT JOIN screening s USING (movie_id)
LEFT JOIN booking b ON b.screening_id = s.screening_id AND b.status = 'CONFIRMED'
GROUP BY m.title;

CREATE VIEW v_daily_revenue AS
SELECT d.day, d.tickets, COALESCE(c.concessions, 0) AS concessions
FROM (SELECT booking_time::date AS day, SUM(total_amount) AS tickets
      FROM booking WHERE status = 'CONFIRMED' GROUP BY 1) d
LEFT JOIN (SELECT ordered_at::date AS day, SUM(total_amount) AS concessions
           FROM orders GROUP BY 1) c USING (day);

-- ===== Queries =====
-- 1. JOIN: every booking with customer, movie and screen
SELECT b.booking_id, cu.name, m.title, sc.name AS screen, b.total_amount
FROM booking b
JOIN customer  cu USING (customer_id)
JOIN screening s  ON s.screening_id = b.screening_id
JOIN movie     m  USING (movie_id)
JOIN screen    sc USING (screen_id);

-- 2. Aggregate: revenue and seats per movie
SELECT m.title, COUNT(bs.seat_id) AS seats, SUM(b.total_amount) AS revenue
FROM movie m
JOIN screening s USING (movie_id)
JOIN booking b   ON b.screening_id = s.screening_id AND b.status = 'CONFIRMED'
JOIN booked_seat bs ON bs.booking_id = b.booking_id
GROUP BY m.title ORDER BY revenue DESC;

-- 3. Nested query: bookings above the average ticket value
SELECT booking_id, total_amount FROM booking
WHERE total_amount > (SELECT AVG(total_amount) FROM booking WHERE status = 'CONFIRMED');

-- 4. Nested query: movies that have never been booked
SELECT title FROM movie
WHERE movie_id NOT IN (SELECT s.movie_id FROM screening s
                       JOIN booking b USING (screening_id));

-- 5. Seat availability for one show
SELECT seat_id FROM seat st
WHERE st.screen_id = (SELECT screen_id FROM screening WHERE screening_id = 101)
  AND NOT EXISTS (SELECT 1 FROM booked_seat bs
                  WHERE bs.screening_id = 101 AND bs.seat_id = st.seat_id);

-- 6. Concession sales with HAVING
SELECT ci.name, SUM(oi.quantity) AS qty, SUM(oi.quantity * oi.unit_price) AS revenue
FROM concession_item ci JOIN order_item oi USING (item_id)
GROUP BY ci.name HAVING SUM(oi.quantity) > 1 ORDER BY revenue DESC;

-- 7. Cancellations with refunds
SELECT c.booking_id, c.hours_before, c.refund_pct, r.amount
FROM cancellation c LEFT JOIN refund r USING (cancellation_id);

