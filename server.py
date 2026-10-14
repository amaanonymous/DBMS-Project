#!/usr/bin/env python3
"""Cinema DBMS backend (Python standard library only, nothing to install).

Run:   python server.py        (or python3 server.py)
Open:  http://localhost:8000

All data lives in the SQLite file cinema.db. The business rules are enforced by
the database (see sql/schema.sql); this server only runs the transactions."""
import json, os, re, sqlite3, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

BASE = os.path.dirname(os.path.abspath(__file__))
DB = os.path.join(BASE, "cinema.db")
SQLDIR = os.path.join(BASE, "sql")
LOCK = threading.Lock()
PORT = int(os.environ.get("PORT", "8000"))
SCHEMA_VERSION = 2
METHODS = ("UPI", "Card", "Cash", "Net Banking")

def conn():
    c = sqlite3.connect(DB, timeout=10, isolation_level=None)  # autocommit; explicit transactions below
    c.row_factory = sqlite3.Row
    c.execute("PRAGMA foreign_keys = ON")
    return c

def build():
    c = sqlite3.connect(DB)
    c.executescript(open(os.path.join(SQLDIR, "schema.sql"), encoding="utf-8").read())
    c.executescript(open(os.path.join(SQLDIR, "seed.sql"), encoding="utf-8").read())
    c.commit(); c.close()

def init(reset=False):
    if os.path.exists(DB):
        v = sqlite3.connect(DB).execute("PRAGMA user_version").fetchone()[0]
        if reset or v != SCHEMA_VERSION:
            if not reset:  # an older database from a previous version: keep a copy
                os.replace(DB, DB + ".old-" + time.strftime("%Y%m%d%H%M%S"))
            else:
                os.remove(DB)
    if not os.path.exists(DB):
        build()

RAWQ = {
 "movie": "SELECT movie_id, title, duration_min FROM movie",
 "screen": "SELECT screen_id, name, screen_type, capacity FROM screen",
 "customer": "SELECT customer_id, name FROM customer",
 "screening": "SELECT screening_id, movie_id, screen_id, printf('%02d:%02d',start_min/60,start_min%60) AS start_time, printf('%02d:%02d',end_min/60,end_min%60) AS end_time FROM screening",
 "booking": "SELECT booking_id, customer_id, screening_id, total_amount, status, refund_amount AS refund FROM booking",
 "booked_seat": "SELECT booking_id, seat, screening_id FROM booked_seat",
 "ticket": "SELECT ticket_id, booking_id, ticket_code, seat, screening_id, status FROM ticket",
 "concession_item": "SELECT item_id, name, category AS category, price, CASE is_active WHEN 1 THEN 'true' ELSE 'false' END AS is_active FROM concession_item",
 "orders": "SELECT order_id, booking_id, customer_id, total_amount, ordered_at FROM orders",
 "order_item": "SELECT order_id, item_id, quantity, unit_price FROM order_item",
 "payment": "SELECT payment_id, booking_id, order_id, method, amount, status, paid_at FROM payment",
 "cancellation": "SELECT cancellation_id, booking_id, hours_before, refund_pct, cancelled_at FROM cancellation",
 "refund": "SELECT refund_id, cancellation_id, payment_id, amount, refunded_at FROM refund",
 "audit_log": "SELECT logged_at AS time, action, detail FROM audit_log ORDER BY log_id DESC LIMIT 200",
}

def state():
    c = conn()
    q = lambda s, a=(): c.execute(s, a).fetchall()
    items = {}
    for r in q("SELECT * FROM order_item ORDER BY order_id, item_id"):
        items.setdefault(r["order_id"], []).append([r["item_id"], r["quantity"]])
    out = {
     "movies": [{"id":r["movie_id"],"title":r["title"],"dur":r["duration_min"]} for r in q("SELECT * FROM movie")],
     "screens": [{"id":r["screen_id"],"name":r["name"],"type":r["screen_type"],"base":r["base_price"]} for r in q("SELECT * FROM screen")],
     "custs": [{"id":r["customer_id"],"name":r["name"]} for r in q("SELECT * FROM customer")],
     "shows": [{"id":r["screening_id"],"movie":r["movie_id"],"screen":r["screen_id"],"start":r["start_min"],"end":r["end_min"]} for r in q("SELECT * FROM screening")],
     "books": [{"id":r["booking_id"],"c":r["customer_id"],"sc":r["screening_id"],"seats":r["seat_list"].split(", "),"total":r["total_amount"],"status":r["status"],"refund":r["refund_amount"]} for r in q("SELECT * FROM booking ORDER BY booking_id")],
     "taken": {f'{r["screening_id"]}|{r["seat"]}': r["booking_id"] for r in q("SELECT * FROM booked_seat")},
     "audit": [{"t":r["logged_at"],"a":r["action"],"d":r["detail"]} for r in q("SELECT * FROM audit_log ORDER BY log_id DESC LIMIT 200")],
     "menu": [{"id":r["item_id"],"name":r["name"],"cat":r["category"],"price":r["price"]} for r in q("SELECT * FROM concession_item WHERE is_active = 1 ORDER BY item_id")],
     "orders": [{"id":r["order_id"],"b":r["booking_id"],"c":r["customer_id"],"items":items.get(r["order_id"], []),"total":r["total_amount"],"t":r["ordered_at"]} for r in q("SELECT * FROM orders ORDER BY order_id")],
     "pays": [{"ref":"booking" if r["booking_id"] is not None else "order","rid":r["booking_id"] if r["booking_id"] is not None else r["order_id"],"id":r["payment_id"],"m":r["method"],"amt":r["amount"],"st":r["status"],"t":r["paid_at"]} for r in q("SELECT * FROM payment ORDER BY payment_id")],
     "cancels": [{"id":r["cancellation_id"],"b":r["booking_id"],"hrs":r["hours_before"],"pct":r["refund_pct"],"t":r["cancelled_at"]} for r in q("SELECT * FROM cancellation ORDER BY cancellation_id")],
     "refunds": [{"id":r["refund_id"],"b":r["booking_id"],"pay":r["payment_id"],"amt":r["amount"],"t":r["refunded_at"]} for r in q("SELECT r.*, c.booking_id FROM refund r JOIN cancellation c ON c.cancellation_id = r.cancellation_id ORDER BY r.refund_id")],
     "raw": {},
    }
    for t, sql in RAWQ.items():
        cur = c.execute(sql)
        out["raw"][t] = {"h": [d[0] for d in cur.description], "r": [list(r) for r in cur.fetchall()]}
    c.close()
    return out

class Fail(Exception):
    def __init__(self, code, msg): self.code, self.msg = code, msg

def audit(c, action, detail):
    c.execute("INSERT INTO audit_log(action, detail) VALUES (?,?)", (action, detail))

def log_outside(action, detail):
    c = conn(); audit(c, action, detail); c.close()

def friendly(e):
    if "booked_seat.screening_id" in e:
        return ('duplicate key violates unique constraint "booked_seat_screening_seat_key"', ("CONFLICT", "Seat already booked, transaction rolled back"))
    if "screening_no_overlap" in e:
        return ('conflicting key value violates exclusion constraint "screening_no_overlap"', ("REJECTED", "Overlapping screening blocked"))
    if "cancel_once" in e:
        return ('new row for relation "booking" violates check constraint "cancel_once"', ("REJECTED", "Second cancellation blocked"))
    if "refund_limit" in e:
        return ('refund exceeds the amount paid (trigger "refund_limit")', ("REJECTED", "Refund above amount paid blocked"))
    if "FOREIGN KEY" in e:
        return ('violates foreign key constraint: other rows still reference this row', ("REJECTED", "Delete blocked by foreign key"))
    if "quantity_positive" in e:
        return ('check constraint "quantity_positive" violated. Quantity must be a whole number greater than 0', None)
    if "price_positive" in e:
        return ('check constraint "price_positive" violated. Price must be greater than 0', None)
    if "concession_item.name" in e:
        return ('duplicate key violates unique constraint "concession_item_name_key"', None)
    if "movie.title" in e:
        return ("movie already exists", None)
    if "duration_min" in e:
        return ('check constraint "duration_min" violated (40 to 240 minutes)', None)
    if "show_within_hours" in e:
        return ('check constraint "show_within_hours" violated. Shows run 10:00 to midnight', None)
    return (e, None)

def run_tx(fn):
    """Run fn(c, sql) inside BEGIN IMMEDIATE ... COMMIT. Returns (status, json)."""
    sql = ["BEGIN;"]
    with LOCK:
        c = conn()
        try:
            c.execute("BEGIN IMMEDIATE")
            result = fn(c, sql)
            c.execute("COMMIT")
            sql.append("COMMIT;")
            result["sql"] = sql
            return 200, result
        except (sqlite3.IntegrityError, Fail) as e:
            try: c.execute("ROLLBACK")
            except sqlite3.Error: pass
            if isinstance(e, Fail):
                code, msg, note = e.code, e.msg, None
            else:
                msg, note = friendly(str(e)); code = 409
            sql.append("ERROR: " + msg)
            sql.append("ROLLBACK;")
            if note: log_outside(*note)
            return code, {"error": msg, "sql": sql}
        finally:
            c.close()

def price(base, seat):
    return base + (60 if seat[0] in "EF" else 0)

def checkout(d):
    """Seats and/or concessions, one payment each, in a single transaction."""
    try:
        cust, clock = int(d["customer"]), int(d.get("clock", 0))
        method = str(d.get("method", "UPI"))
        sid = int(d["screening"]) if d.get("screening") not in (None, "", 0) else None
        seats = sorted({str(x).upper() for x in d.get("seats", [])})
        items = [(int(i), q) for i, q in d.get("items", [])]
    except (KeyError, ValueError, TypeError):
        return 400, {"error": "Invalid request"}
    if method not in METHODS: return 400, {"error": "Choose a valid payment method"}
    if seats and (sid is None or len(seats) > 6 or any(not re.fullmatch(r"[A-F](10|[1-9])", x) for x in seats)):
        return 400, {"error": "Choose 1 to 6 valid seats (A1 to F10)"}
    for _, q in items:
        if not isinstance(q, int) or isinstance(q, bool) or q <= 0:
            return 400, {"error": 'check constraint "quantity_positive" violated. Quantity must be a whole number greater than 0.'}
    if not seats and not items: return 400, {"error": "Select seats or add a concession item first"}
    def fn(c, sql):
        res, bid, total_b, total_o = {}, None, 0, 0
        cu = c.execute("SELECT name FROM customer WHERE customer_id=?", (cust,)).fetchone()
        if not cu: raise Fail(404, "Customer not found")
        if seats:
            show = c.execute("SELECT s.*, sc.base_price FROM screening s JOIN screen sc USING (screen_id) WHERE screening_id=?", (sid,)).fetchone()
            if not show: raise Fail(404, "Screening not found")
            if show["start_min"] < clock: raise Fail(400, "This show has already started")
            sql.append(f"SELECT * FROM screening WHERE screening_id = {sid};  -- row lock (BEGIN IMMEDIATE)")
            total_b = sum(price(show["base_price"], x) for x in seats)
            bid = c.execute("INSERT INTO booking(customer_id,screening_id,total_amount,status,seat_list) VALUES (?,?,?,'CONFIRMED',?)", (cust, sid, total_b, ", ".join(seats))).lastrowid
            sql.append(f"INSERT INTO booking (customer_id, screening_id, total_amount) VALUES ({cust}, {sid}, {total_b});")
            for x in seats:
                sql.append(f"INSERT INTO booked_seat VALUES ({bid}, '{x}', {sid});")
                c.execute("INSERT INTO booked_seat VALUES (?,?,?)", (bid, x, sid))
            for x in seats:
                c.execute("INSERT INTO ticket(booking_id,seat,screening_id,ticket_code) VALUES (?,?,?,?)", (bid, x, sid, f"TK-{bid}-{x}"))
            sql.append("INSERT INTO ticket ... -- " + ", ".join(f"TK-{bid}-{x}" for x in seats))
            c.execute("INSERT INTO payment(booking_id,method,amount) VALUES (?,?,?)", (bid, method, total_b))
            sql.append(f"INSERT INTO payment (booking_id, method, amount) VALUES ({bid}, '{method}', {total_b});")
            audit(c, "BOOKED", f"#{bid} · {cu['name']} · {', '.join(seats)} · ₹{total_b}")
            res["booking_id"] = bid
        if items:
            rows = []
            for i, q in items:
                r = c.execute("SELECT item_id, price FROM concession_item WHERE item_id=? AND is_active=1", (i,)).fetchone()
                if not r: raise Fail(404, "Menu item not found")
                rows.append((i, q, r["price"]))
            total_o = sum(q * p for _, q, p in rows)
            oid = c.execute("INSERT INTO orders(booking_id,customer_id,total_amount) VALUES (?,?,?)", (bid, cust, total_o)).lastrowid
            sql.append(f"INSERT INTO orders (booking_id, customer_id, total_amount) VALUES ({bid if bid else 'NULL'}, {cust}, {total_o});")
            for i, q, p in rows:
                sql.append(f"INSERT INTO order_item VALUES ({oid}, {i}, {q}, {p});  -- quantity > 0")
                c.execute("INSERT INTO order_item(order_id,item_id,quantity,unit_price) VALUES (?,?,?,?)", (oid, i, q, p))
            c.execute("INSERT INTO payment(order_id,method,amount) VALUES (?,?,?)", (oid, method, total_o))
            sql.append(f"INSERT INTO payment (order_id, method, amount) VALUES ({oid}, '{method}', {total_o});")
            audit(c, "ORDER", f"#{oid} · {cu['name']} · ₹{total_o}")
            res["order_id"] = oid
        res["paid"] = total_b + total_o
        return res
    return run_tx(fn)

def cancel(bid, d):
    clock = int(d.get("clock", 0))
    def fn(c, sql):
        r = c.execute("SELECT b.*, s.start_min FROM booking b JOIN screening s USING (screening_id) WHERE booking_id=?", (bid,)).fetchone()
        if not r: raise Fail(404, "Booking not found")
        hours = (r["start_min"] - clock) / 60
        pct = 100 if hours >= 24 else 50 if hours >= 2 else 0
        refund = int(r["total_amount"] * pct / 100 + 0.5)
        sql.append(f"UPDATE booking SET status='CANCELLED', refund_amount={refund} WHERE booking_id={bid};")
        c.execute("UPDATE booking SET status='CANCELLED', refund_amount=? WHERE booking_id=?", (refund, bid))   # trigger cancel_once guards this
        sql.append(f"DELETE FROM booked_seat WHERE booking_id={bid};")
        c.execute("DELETE FROM booked_seat WHERE booking_id=?", (bid,))
        c.execute("UPDATE ticket SET status='VOID' WHERE booking_id=?", (bid,))
        sql.append(f"UPDATE ticket SET status='VOID' WHERE booking_id={bid};")
        cid = c.execute("INSERT INTO cancellation(booking_id,hours_before,refund_pct) VALUES (?,?,?)", (bid, round(hours, 1), pct)).lastrowid
        sql.append(f"INSERT INTO cancellation (booking_id, hours_before, refund_pct) VALUES ({bid}, {round(hours,1)}, {pct});")
        if refund > 0:
            pay = c.execute("SELECT payment_id FROM payment WHERE booking_id=?", (bid,)).fetchone()
            c.execute("INSERT INTO refund(cancellation_id,payment_id,amount) VALUES (?,?,?)", (cid, pay["payment_id"], refund))
            sql.append(f"INSERT INTO refund (cancellation_id, payment_id, amount) VALUES ({cid}, {pay['payment_id']}, {refund});")
            c.execute("UPDATE payment SET status=? WHERE payment_id=?", ("REFUNDED" if refund >= r["total_amount"] else "PART REFUNDED", pay["payment_id"]))
        audit(c, "CANCELLED", f"#{bid} · refund ₹{refund} ({pct}%) · seats released")
        return {"refund": refund, "total": r["total_amount"], "pct": pct}
    return run_tx(fn)

def add_movie(d):
    title = str(d.get("title", "")).strip()
    if len(title) < 2: return 400, {"error": "null value in column \"title\" violates not-null constraint (enter a title)"}
    try: dur = int(d.get("duration"))
    except (TypeError, ValueError): return 400, {"error": "Duration must be a number"}
    def fn(c, sql):
        sql.append(f"INSERT INTO movie (title, duration_min) VALUES ('{title}', {dur});")
        c.execute("INSERT INTO movie(title, duration_min) VALUES (?,?)", (title, dur))
        audit(c, "MOVIE ADDED", f"{title} · {dur} min")
        return {}
    return run_tx(fn)

def add_menu(d):
    name = str(d.get("name", "")).strip()
    if len(name) < 2: return 400, {"error": 'null value in column "name" violates not-null constraint.'}
    try: p = int(d.get("price"))
    except (TypeError, ValueError): return 400, {"error": "Price must be a whole number"}
    cat = d.get("category")
    def fn(c, sql):
        sql.append(f"INSERT INTO concession_item (name, category, price) VALUES ('{name}', '{cat}', {p});")
        c.execute("INSERT INTO concession_item(name, category, price) VALUES (?,?,?)", (name, cat, p))
        audit(c, "MENU ADDED", f"{name} · ₹{p}")
        return {}
    return run_tx(fn)

def add_screening(d):
    try: scr, mov, st = int(d["screen"]), int(d["movie"]), int(d["start"])
    except (KeyError, ValueError, TypeError): return 400, {"error": "Invalid request"}
    def fn(c, sql):
        m = c.execute("SELECT * FROM movie WHERE movie_id=?", (mov,)).fetchone()
        if not m: raise Fail(404, "Movie not found")
        end = st + m["duration_min"]
        sql.append(f"INSERT INTO screening (movie_id, screen_id, start_min, end_min) VALUES ({mov}, {scr}, {st}, {end});")
        try:
            c.execute("INSERT INTO screening(movie_id,screen_id,start_min,end_min) VALUES (?,?,?,?)", (mov, scr, st, end))
        except sqlite3.IntegrityError as e:
            if "screening_no_overlap" in str(e):
                x = c.execute("SELECT s.*, m.title FROM screening s JOIN movie m USING (movie_id) WHERE screen_id=? AND ?<s.end_min+20 AND s.start_min<?+20", (scr, st, end)).fetchone()
                raise Fail(409, f'conflicting key value violates exclusion constraint "screening_no_overlap". Existing: {x["title"]}, {x["start_min"]//60:02d}:{x["start_min"]%60:02d} to {x["end_min"]//60:02d}:{x["end_min"]%60:02d} plus the 20 minute gap.')
            raise
        audit(c, "SCHEDULED", f"{m['title']} · screen {scr} · {st//60:02d}:{st%60:02d}")
        return {}
    return run_tx(fn)

def del_screening(sid):
    def fn(c, sql):
        sql.append(f"DELETE FROM screening WHERE screening_id={sid};")
        c.execute("DELETE FROM screening WHERE screening_id=?", (sid,))
        audit(c, "SCREENING DELETED", f"#{sid}")
        return {}
    return run_tx(fn)

class H(BaseHTTPRequestHandler):
    def send(self, code, obj, ctype="application/json"):
        body = obj if isinstance(obj, bytes) else json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype + ("; charset=utf-8" if "json" in ctype or "html" in ctype else ""))
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        try: return json.loads(self.rfile.read(n) or b"{}")
        except ValueError: return {}
    def do_GET(self):
        p = urlparse(self.path).path
        if p == "/api/state":
            with LOCK: return self.send(200, state())
        if p in ("/", "/index.html"):
            return self.send(200, open(os.path.join(BASE, "public", "index.html"), "rb").read(), "text/html")
        self.send(404, {"error": "Not found"})
    def do_POST(self):
        p, d = urlparse(self.path).path, self.body()
        if p == "/api/checkout": return self.send(*checkout(d))
        m = re.fullmatch(r"/api/bookings/(\d+)/cancel", p)
        if m: return self.send(*cancel(int(m.group(1)), d))
        if p == "/api/movies": return self.send(*add_movie(d))
        if p == "/api/menu": return self.send(*add_menu(d))
        if p == "/api/screenings": return self.send(*add_screening(d))
        if p == "/api/reset":
            with LOCK: init(reset=True)
            return self.send(200, {"ok": True})
        self.send(404, {"error": "Not found"})
    def do_DELETE(self):
        m = re.fullmatch(r"/api/screenings/(\d+)", urlparse(self.path).path)
        if m: return self.send(*del_screening(int(m.group(1))))
        self.send(404, {"error": "Not found"})
    def log_message(self, fmt, *a):
        print("  " + (fmt % a))

if __name__ == "__main__":
    init()
    print(f"Cinema DBMS running at http://localhost:{PORT}  (database file: {DB})")
    try:
        ThreadingHTTPServer(("0.0.0.0", PORT), H).serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.")
