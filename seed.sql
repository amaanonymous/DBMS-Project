-- Sample data for the Cinema DBMS. Run after schema.sql.
INSERT INTO movie (movie_id, title, duration_min) VALUES
  (1,'Midnight Orbit',148),(2,'The Last Lighthouse',126),(3,'Monsoon Heist',134),(4,'Paper Kites',102);
INSERT INTO screen (screen_id, name, screen_type, capacity, base_price) VALUES
  (1,'Screen 1','2D',60,200),(2,'Screen 2','3D',60,280),(3,'Screen 3','IMAX',60,350);
INSERT INTO customer (customer_id, name) VALUES
  (1,'Ananya Rao'),(2,'Rohan Mehta'),(3,'Sara Iqbal'),(4,'Walk-in guest');
INSERT INTO screening (screening_id, movie_id, screen_id, start_min, end_min) VALUES
  (101,1,1,630,778),(102,4,1,840,942),(103,3,1,1020,1154),(104,2,2,660,786),
  (105,1,2,900,1048),(106,3,3,720,854),(107,1,3,1110,1258);
INSERT INTO booking (booking_id, customer_id, screening_id, total_amount, status, refund_amount, seat_list) VALUES
  (1001,1,101,400,'CONFIRMED',0,'C4, C5'),
  (1002,2,101,600,'CONFIRMED',0,'D6, D7, D8'),
  (1003,3,104,560,'CONFIRMED',0,'B2, B3');
INSERT INTO booked_seat (booking_id, seat, screening_id) VALUES
  (1001,'C4',101),(1001,'C5',101),(1002,'D6',101),(1002,'D7',101),(1002,'D8',101),(1003,'B2',104),(1003,'B3',104);
INSERT INTO ticket (ticket_id, booking_id, seat, screening_id, ticket_code, status) VALUES
  (1,1001,'C4',101,'TK-1001-C4','VALID'),(2,1001,'C5',101,'TK-1001-C5','VALID'),
  (3,1002,'D6',101,'TK-1002-D6','VALID'),(4,1002,'D7',101,'TK-1002-D7','VALID'),(5,1002,'D8',101,'TK-1002-D8','VALID'),
  (6,1003,'B2',104,'TK-1003-B2','VALID'),(7,1003,'B3',104,'TK-1003-B3','VALID');
INSERT INTO concession_item (item_id, name, category, price, is_active) VALUES
  (1,'Popcorn (Regular)','Snacks',150,1),(2,'Popcorn (Large)','Snacks',250,1),(3,'Nachos and Cheese','Snacks',200,1),
  (4,'Soft Drink','Drinks',120,1),(5,'Cold Coffee','Drinks',140,1),(6,'Combo: Popcorn + 2 Drinks','Combos',420,1);
INSERT INTO orders (order_id, booking_id, customer_id, total_amount, ordered_at) VALUES (5001,1001,1,540,'08:41:10');
INSERT INTO order_item (order_id, item_id, quantity, unit_price) VALUES (5001,1,2,150),(5001,4,2,120);
INSERT INTO payment (payment_id, booking_id, order_id, method, amount, status, paid_at) VALUES
  (9001,1001,NULL,'UPI',400,'PAID','08:40:55'),(9002,1002,NULL,'Card',600,'PAID','08:52:03'),
  (9003,1003,NULL,'Cash',560,'PAID','09:02:41'),(9004,NULL,5001,'UPI',540,'PAID','08:41:10');
