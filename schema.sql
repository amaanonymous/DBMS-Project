-- Cinema DBMS schema (SQLite). Business rules are enforced by the database itself.
-- Entities: cinema screens, seats, movies, screenings, customers, bookings, booked seats,
-- tickets, concession items, orders, payments, cancellations, refunds.
PRAGMA foreign_keys = ON;

CREATE TABLE movie (
  movie_id     INTEGER PRIMARY KEY AUTOINCREMENT,
  title        TEXT    NOT NULL UNIQUE,
  duration_min INTEGER NOT NULL CHECK (duration_min BETWEEN 40 AND 240)
);

CREATE TABLE screen (
  screen_id   INTEGER PRIMARY KEY,
  name        TEXT    NOT NULL,
  screen_type TEXT    NOT NULL CHECK (screen_type IN ('2D','3D','IMAX')),
  capacity    INTEGER NOT NULL CHECK (capacity > 0),
  base_price  INTEGER NOT NULL CHECK (base_price > 0)
);

CREATE TABLE customer (
  customer_id INTEGER PRIMARY KEY AUTOINCREMENT,
  name        TEXT NOT NULL
);

-- start_min / end_min are minutes after midnight. Shows run 10:00 to 24:00.
CREATE TABLE screening (
  screening_id INTEGER PRIMARY KEY AUTOINCREMENT,
  movie_id     INTEGER NOT NULL REFERENCES movie(movie_id),
  screen_id    INTEGER NOT NULL REFERENCES screen(screen_id),
  start_min    INTEGER NOT NULL,
  end_min      INTEGER NOT NULL,
  CONSTRAINT show_within_hours CHECK (start_min >= 600 AND end_min <= 1440 AND end_min > start_min)
);

-- Rule: no two shows overlap on one screen, with a 20 minute cleaning gap.
CREATE TRIGGER screening_no_overlap BEFORE INSERT ON screening
WHEN EXISTS (SELECT 1 FROM screening s
             WHERE s.screen_id = NEW.screen_id
               AND NEW.start_min < s.end_min + 20
               AND s.start_min < NEW.end_min + 20)
BEGIN
  SELECT RAISE(ABORT, 'screening_no_overlap');
END;

CREATE TABLE booking (
  booking_id    INTEGER PRIMARY KEY AUTOINCREMENT,
  customer_id   INTEGER NOT NULL REFERENCES customer(customer_id),
  screening_id  INTEGER NOT NULL REFERENCES screening(screening_id),
  total_amount  INTEGER NOT NULL CHECK (total_amount >= 0),
  status        TEXT    NOT NULL DEFAULT 'CONFIRMED' CHECK (status IN ('CONFIRMED','CANCELLED')),
  refund_amount INTEGER NOT NULL DEFAULT 0,
  seat_list     TEXT    NOT NULL,                 -- receipt snapshot kept after cancellation
  CONSTRAINT refund_within_total CHECK (refund_amount >= 0 AND refund_amount <= total_amount)
);

-- Rule: a booking can be cancelled only once.
CREATE TRIGGER cancel_once BEFORE UPDATE ON booking
WHEN OLD.status = 'CANCELLED'
BEGIN
  SELECT RAISE(ABORT, 'cancel_once');
END;

-- Rule: one seat per screening.
CREATE TABLE booked_seat (
  booking_id   INTEGER NOT NULL REFERENCES booking(booking_id) ON DELETE CASCADE,
  seat         TEXT    NOT NULL,
  screening_id INTEGER NOT NULL REFERENCES screening(screening_id),
  PRIMARY KEY (booking_id, seat),
  CONSTRAINT booked_seat_screening_seat_key UNIQUE (screening_id, seat)
);

-- One ticket is issued per booked seat.
CREATE TABLE ticket (
  ticket_id    INTEGER PRIMARY KEY AUTOINCREMENT,
  booking_id   INTEGER NOT NULL REFERENCES booking(booking_id),
  seat         TEXT    NOT NULL,
  screening_id INTEGER NOT NULL REFERENCES screening(screening_id),
  ticket_code  TEXT    NOT NULL UNIQUE,
  status       TEXT    NOT NULL DEFAULT 'VALID' CHECK (status IN ('VALID','VOID','USED'))
);

CREATE TABLE concession_item (
  item_id   INTEGER PRIMARY KEY AUTOINCREMENT,
  name      TEXT    NOT NULL UNIQUE,
  category  TEXT    NOT NULL CHECK (category IN ('Snacks','Drinks','Combos')),
  price     INTEGER NOT NULL CONSTRAINT price_positive CHECK (price > 0),
  is_active INTEGER NOT NULL DEFAULT 1 CHECK (is_active IN (0,1))
);

-- booking_id is NULL for counter sales (no seats booked).
CREATE TABLE orders (
  order_id     INTEGER PRIMARY KEY AUTOINCREMENT,
  booking_id   INTEGER REFERENCES booking(booking_id),
  customer_id  INTEGER NOT NULL REFERENCES customer(customer_id),
  total_amount INTEGER NOT NULL CHECK (total_amount >= 0),
  ordered_at   TEXT    NOT NULL DEFAULT (strftime('%H:%M:%S','now','localtime'))
);

CREATE TABLE order_item (
  order_id   INTEGER NOT NULL REFERENCES orders(order_id) ON DELETE CASCADE,
  item_id    INTEGER NOT NULL REFERENCES concession_item(item_id),
  quantity   INTEGER NOT NULL CONSTRAINT quantity_positive CHECK (quantity > 0),
  unit_price INTEGER NOT NULL CHECK (unit_price > 0),
  PRIMARY KEY (order_id, item_id)
);

CREATE TABLE payment (
  payment_id INTEGER PRIMARY KEY AUTOINCREMENT,
  booking_id INTEGER REFERENCES booking(booking_id),
  order_id   INTEGER REFERENCES orders(order_id),
  method     TEXT    NOT NULL CHECK (method IN ('UPI','Card','Cash','Net Banking')),
  amount     INTEGER NOT NULL CHECK (amount > 0),
  status     TEXT    NOT NULL DEFAULT 'PAID' CHECK (status IN ('PAID','PART REFUNDED','REFUNDED')),
  paid_at    TEXT    NOT NULL DEFAULT (strftime('%H:%M:%S','now','localtime')),
  CHECK (booking_id IS NOT NULL OR order_id IS NOT NULL)
);

-- Rule: valid cancellation policy (100 / 50 / 0 percent) and one cancellation per booking.
CREATE TABLE cancellation (
  cancellation_id INTEGER PRIMARY KEY AUTOINCREMENT,
  booking_id      INTEGER NOT NULL UNIQUE REFERENCES booking(booking_id),
  cancelled_at    TEXT    NOT NULL DEFAULT (strftime('%H:%M:%S','now','localtime')),
  hours_before    REAL    NOT NULL,
  refund_pct      INTEGER NOT NULL CHECK (refund_pct IN (0, 50, 100))
);

CREATE TABLE refund (
  refund_id       INTEGER PRIMARY KEY AUTOINCREMENT,
  cancellation_id INTEGER NOT NULL UNIQUE REFERENCES cancellation(cancellation_id),
  payment_id      INTEGER NOT NULL REFERENCES payment(payment_id),
  amount          INTEGER NOT NULL CHECK (amount > 0),
  refunded_at     TEXT    NOT NULL DEFAULT (strftime('%H:%M:%S','now','localtime'))
);

-- Rule: a refund can never exceed the amount paid.
CREATE TRIGGER refund_limit BEFORE INSERT ON refund
WHEN NEW.amount > (SELECT amount FROM payment WHERE payment_id = NEW.payment_id)
BEGIN
  SELECT RAISE(ABORT, 'refund_limit');
END;

CREATE TABLE audit_log (
  log_id    INTEGER PRIMARY KEY AUTOINCREMENT,
  logged_at TEXT NOT NULL DEFAULT (strftime('%H:%M:%S','now','localtime')),
  action    TEXT NOT NULL,
  detail    TEXT NOT NULL
);

-- Indexes on frequently searched attributes
-- (booked_seat (screening_id, seat) is already indexed by its UNIQUE constraint)
CREATE INDEX idx_screening_screen_time ON screening (screen_id, start_min);
CREATE INDEX idx_screening_movie       ON screening (movie_id);
CREATE INDEX idx_booking_customer      ON booking (customer_id);
CREATE INDEX idx_booking_screening     ON booking (screening_id, status);
CREATE INDEX idx_payment_booking       ON payment (booking_id);
CREATE INDEX idx_payment_order         ON payment (order_id);
CREATE INDEX idx_orders_booking        ON orders (booking_id);
CREATE INDEX idx_ticket_booking        ON ticket (booking_id);

-- Views used by the reports
CREATE VIEW v_show_occupancy AS
SELECT s.screening_id, m.title, sc.name AS screen,
       printf('%02d:%02d', s.start_min/60, s.start_min%60) AS start_time,
       COUNT(bs.seat) AS seats_sold, sc.capacity,
       ROUND(100.0 * COUNT(bs.seat) / sc.capacity, 1) AS occupancy_pct
FROM screening s
JOIN movie m   ON m.movie_id = s.movie_id
JOIN screen sc ON sc.screen_id = s.screen_id
LEFT JOIN booked_seat bs ON bs.screening_id = s.screening_id
GROUP BY s.screening_id;

CREATE VIEW v_movie_performance AS
SELECT m.title,
       COUNT(DISTINCT s.screening_id) AS shows,
       COALESCE(SUM(b.total_amount), 0) AS ticket_revenue
FROM movie m
LEFT JOIN screening s ON s.movie_id = m.movie_id
LEFT JOIN booking b   ON b.screening_id = s.screening_id AND b.status = 'CONFIRMED'
GROUP BY m.movie_id;

CREATE VIEW v_concession_sales AS
SELECT ci.name, ci.category, SUM(oi.quantity) AS qty_sold,
       SUM(oi.quantity * oi.unit_price) AS revenue
FROM concession_item ci
JOIN order_item oi ON oi.item_id = ci.item_id
GROUP BY ci.item_id;

PRAGMA user_version = 2;
