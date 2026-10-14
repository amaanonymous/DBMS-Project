# Cinema DBMS: full project

A cinema screening and ticket booking system: website, simulation app,
Python backend and a real database file.

## Folder map

| Path | What it is |
|------|------------|
| `server.py` | Python backend. Standard library only, nothing to install |
| `cinema.db` | The SQLite database file (already created and filled with sample data) |
| `sql/schema.sql` | All 14 tables, keys, CHECK/UNIQUE/DEFAULT rules, triggers, indexes and views |
| `sql/seed.sql` | Realistic sample data |
| `sql/queries.sql` | Joins, aggregates, nested queries, views and the six reports |
| `sql/schema_postgres.sql` | The same design written for PostgreSQL (reference) |
| `public/index.html` | Website + simulation app, connected to the backend |
| `standalone/index.html` | The same website with no backend (data lives in the browser) |

## Run with the backend (data is saved in cinema.db)

1. Install Python 3.8 or newer (`python3 --version`).
2. Open a terminal in this folder and run:

       python3 server.py        (on Windows: py server.py)

3. Open **http://localhost:8000** and click **Launch Simulation**.

Leave the terminal open while you use the site. Every booking, concession order,
payment, cancellation, refund, movie and screening is written to `cinema.db` and
is still there after you stop and restart the server. **Reset data** in the app
restores the sample data. To use another port: `PORT=8080 python3 server.py`.

## Run without a backend

Double-click `standalone/index.html`. Data lives in the browser and resets on refresh.

## Look at the database

    sqlite3 -header -column cinema.db "SELECT * FROM booking;"
    sqlite3 -header -column cinema.db "SELECT * FROM v_show_occupancy;"
    sqlite3 cinema.db < sql/queries.sql

Or open `cinema.db` in DB Browser for SQLite (free). Do not open it in a text editor.

To rebuild the database from scratch: delete `cinema.db` and start the server,
or run `sqlite3 cinema.db < sql/schema.sql` then `sqlite3 cinema.db < sql/seed.sql`.

## Tables (14)

movie, screen, customer, screening, booking, booked_seat, ticket, concession_item,
orders, order_item, payment, cancellation, refund, audit_log.

## Business rules enforced by the database

| Rule | How |
|------|-----|
| One seat per screening | `UNIQUE (screening_id, seat)` on `booked_seat` |
| No screen overlap, 20 minute gap | trigger `screening_no_overlap` |
| Shows run 10:00 to midnight | `CHECK` constraint `show_within_hours` |
| Positive quantity and price | `CHECK` constraints `quantity_positive`, `price_positive` |
| Valid cancellation policy (100/50/0%) | `CHECK (refund_pct IN (0,50,100))` |
| Cancel only once | trigger `cancel_once` and `UNIQUE` on `cancellation.booking_id` |
| Refund never above the amount paid | trigger `refund_limit` and `CHECK` on `booking` |
| No deleting a show that has bookings | foreign keys |

## API

| Method and path | Action |
|-----------------|--------|
| `GET /api/state` | All tables |
| `POST /api/checkout` | Seats and/or concessions, tickets and payment in one transaction |
| `POST /api/bookings/<id>/cancel` | Cancel with refund, cancellation and refund records |
| `POST /api/movies` | Add a movie |
| `POST /api/menu` | Add a concession item |
| `POST /api/screenings` | Schedule a show |
| `DELETE /api/screenings/<id>` | Delete a show |
| `POST /api/reset` | Restore sample data |

## Using PostgreSQL or MySQL

`sql/schema_postgres.sql` has the PostgreSQL version of the schema, rules, indexes,
views and queries. To run the app on it, replace the `sqlite3` calls in `server.py`
with `psycopg2` and keep the same SQL.
