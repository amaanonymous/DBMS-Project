-- Retrieval, joins, aggregates, nested queries, views and reports (SQLite)

-- 1. JOIN: every booking with customer, movie and screen
SELECT b.booking_id, cu.name AS customer, m.title, sc.name AS screen, b.total_amount, b.status
FROM booking b
JOIN customer cu ON cu.customer_id = b.customer_id
JOIN screening s ON s.screening_id = b.screening_id
JOIN movie m     ON m.movie_id = s.movie_id
JOIN screen sc   ON sc.screen_id = s.screen_id;

-- 2. Aggregate: ticket revenue and seats per movie
SELECT m.title, COUNT(bs.seat) AS seats_sold, SUM(b.total_amount) AS revenue
FROM movie m
JOIN screening s ON s.movie_id = m.movie_id
JOIN booking b   ON b.screening_id = s.screening_id AND b.status = 'CONFIRMED'
JOIN booked_seat bs ON bs.booking_id = b.booking_id
GROUP BY m.title ORDER BY revenue DESC;

-- 3. Nested query: bookings above the average ticket value
SELECT booking_id, total_amount FROM booking
WHERE total_amount > (SELECT AVG(total_amount) FROM booking WHERE status = 'CONFIRMED');

-- 4. Nested query: movies that have never been booked
SELECT title FROM movie
WHERE movie_id NOT IN (SELECT s.movie_id FROM screening s JOIN booking b ON b.screening_id = s.screening_id);

-- 5. Seat availability for show 101 (seats already taken)
SELECT seat FROM booked_seat WHERE screening_id = 101 ORDER BY seat;

-- 6. Concession sales with HAVING
SELECT ci.name, SUM(oi.quantity) AS qty, SUM(oi.quantity * oi.unit_price) AS revenue
FROM concession_item ci JOIN order_item oi ON oi.item_id = ci.item_id
GROUP BY ci.name HAVING SUM(oi.quantity) > 1 ORDER BY revenue DESC;

-- 7. Cancellations with refunds
SELECT c.booking_id, c.hours_before, c.refund_pct, r.amount AS refunded
FROM cancellation c LEFT JOIN refund r ON r.cancellation_id = c.cancellation_id;

-- Reports (using the views)
SELECT * FROM v_show_occupancy;                       -- show occupancy
SELECT * FROM v_movie_performance ORDER BY ticket_revenue DESC;   -- movie performance
SELECT * FROM v_concession_sales;                     -- concessions

-- Screen utilization: scheduled minutes out of the 840 open minutes (10:00 to 24:00)
SELECT sc.name, COUNT(s.screening_id) AS shows,
       COALESCE(SUM(s.end_min - s.start_min), 0) AS minutes,
       ROUND(100.0 * COALESCE(SUM(s.end_min - s.start_min), 0) / 840, 1) AS utilization_pct
FROM screen sc LEFT JOIN screening s ON s.screen_id = sc.screen_id GROUP BY sc.screen_id;

-- Revenue summary
SELECT 'Tickets' AS source, SUM(total_amount) AS amount FROM booking WHERE status = 'CONFIRMED'
UNION ALL SELECT 'Concessions', SUM(total_amount) FROM orders
UNION ALL SELECT 'Refunds', -COALESCE(SUM(amount), 0) FROM refund;
