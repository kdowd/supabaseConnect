# supabaseConnect — agent context

Handoff notes for this folder. Written to be read cold by a future session.

**Three deliverables live here:** a live data-table page (`index.html`), a teaching
worksheet (`WORKSHEET.md`), and a second app with its schema (`status.html` +
`status_schema.sql`). All talk to one Supabase project over its REST API.

---

## 1. Environment facts (hard-won — re-verifying these wastes a lot of time)

* Workspace: `/mnt/7E3875FB3875B2AF/dsh_projects/supabaseConnect`. **It persists
  between bash calls.**
* **`/tmp` does NOT persist between bash calls** — it is wiped every time. Files
  written there in one call are gone in the next. Write scratch files **inside the
  workspace**, then delete them. (This wasted a debugging cycle: a `--dump-dom`
  capture written to `/tmp` vanished before the analysis call.)
* Each bash call is a **fresh shell** — no `cd`, variables, or functions carry over.
  Start long-lived processes with `run_in_background: true`, not `&`.
* `uid=1000(kdowd)`, **not root**. Privileged ports (<1024) are unavailable; verified
  empirically (`ip_unprivileged_port_start = 1024`).
* **This box is NOT the immutable snap system** described in the sibling
  `../normalsVideo/AGENTS.md`. Here there is a normal toolchain:
  `python3` 3.14, `node` 22, `curl`, `psql` (client only), `sqlite3`, `git`,
  `google-chrome`, and a **working `docker` daemon** (29.5.2).
* **`read_image` WORKS for this model.** Unlike normalsVideo, screenshots can be
  viewed directly. Use it — it caught a CSS bug that code review missed (§7).
* **Headless Chrome needs `--user-data-dir`** or it fails to start:
  `--headless=new --disable-gpu --no-sandbox --user-data-dir=/tmp/cp1`
  (without it, `/home/kdowd/.config` is read-only and Chrome dies, exit 1).
* Headless Chrome has a **minimum window width of ~500px** — `--window-size=430,...`
  reports `innerWidth === 500`. Don't trust narrow-width assertions below ~500.
* There is **no local PostgreSQL server** (only the `psql` client). Use Docker.
* **Do not touch the user's Docker containers.** They run `wordpress`, `phpmyadmin`,
  `mariadb`, plus stopped `special-one`/`special-two`/`angry_chatelet`. Only ever
  `docker rm` containers you created yourself (this project used `pgstatus`, `pgrst`).

---

## 2. The Supabase project

| Thing | Value |
|---|---|
| Project URL | `https://pkpbzthkwskkudqogyrl.supabase.co` |
| Publishable key | `sb_publishable_MOHaPhKPaA_4Gb7ZMgxQgg_I4YNNk_w` |
| REST base | `{URL}/rest/v1` |

The publishable key is **designed to be public** — it ships in `index.html` and
`status.html` on purpose. It is safe *only because RLS bounds it*.

**Project settings of note:** RLS on the `titanic` table was initially **disabled**
(public read *and* write). The user has since enabled it and added a read-only policy
for `anon`. Assume the same care is needed for any new table.

### `titanic` table (used by `index.html`)

2,207 rows. Columns: `id, name, gender, age, class, embarked, country, fare, survived`.

Verified data facts (use these as test oracles — they are real, not assumed):

| Fact | Value |
|---|---|
| Rows | 2,207 |
| Survived / died | 711 / 1,496 (32.2%) |
| Average age / fare | 30.4 / 33.4 |
| Distinct classes | 7 (`1st`, `2nd`, `3rd`, `deck crew`, `engineering crew`, `restaurant staff`, `victualling crew`) |
| Distinct countries | 49 |
| Embarked values | `B`, `C`, `Q`, `S` |
| Blank ages | 2 — ids **440** and **678** |
| Blank fares | 916 |
| Max fare / age range | 512.06 / 0.167–74 |
| 1st class + survived | 201 |
| Female passengers (survived) | 489 (359) |
| `search "Rose"` matches | 5 |

**`age` and `fare` are stored as TEXT**, not numeric. Sorting them naively is
lexicographic (`"9" > "10"`). `index.html` parses them in JS.

---

## 3. Hard rules — do not repeat these mistakes

1. **NEVER send a write-shaped request to the user's live database to "probe"
   permissions.** A POST intended to be *rejected* was **accepted** (`201 Created`)
   and inserted `id=999999, name='__probe__'` into the live `titanic` table. It was
   deleted immediately and the count verified back at 2,207, but it should not have
   happened. Read-only probes only. If a genuine write path must be tested, **do it
   against a local Docker Postgres**, never the cloud project.
2. **`/tmp` is not durable between calls** (§1). Use the workspace.
3. **Enabling RLS without a policy fails *silently*** — `200 []`, not an error. Never
   conclude "RLS is on, so we're safe" without checking `pg_policies`.
4. **Identify RLS write-blocking correctly.** RLS is asymmetric: `INSERT` raises
   `42501`, but `UPDATE`/`DELETE` **silently affect 0 rows** (`200 []`). A `200 []`
   from a DELETE proves nothing. To discriminate, use an `INSERT` that must fail a
   constraint anyway (e.g. a duplicate primary key) — or just read `pg_policies`.
5. **Don't trust a hand-written SQL statement to represent what a client library
   sends.** This caused the worst bug in this repo (§6). Reproduce the library's
   *actual* generated SQL.
6. **Never leave a background server running** when finished, and verify teardown
   (port free + `curl` refusal). The user has asked for this explicitly.
7. **If you revise a file the user may already have run, say so loudly.**
   Two versions of `status_schema.sql` were handed over ~12 minutes apart. The user
   ran the first, so the tables and seed existed but the RPC did not — every tick
   404'd with `PGRST202`. Announcing "this supersedes the previous file" costs one
   line; not doing it cost a full debugging round trip. When version confusion is
   possible, hand over a **standalone snippet** rather than re-explaining which copy
   is current.

---

## 4. Supabase / PostgREST behaviour reference (all verified against the live API)

| Situation | Result |
|---|---|
| Missing table | `404`, code `PGRST205` |
| Bad column | `400`, code `42703`, with a *"Perhaps you meant…"* hint |
| No `apikey` header | `401` |
| Rows per request | **capped at 1,000, silently** |
| `content-range` | `0-999/*` — the `*` means total unknown |
| `Prefer: count=exact` | `content-range: 0-999/2207` — the only way to get a true total |
| OpenAPI/schema endpoint | **requires a secret key** (401) — the publishable key cannot introspect |
| supabase-js upsert | emits `ON CONFLICT ... DO UPDATE SET <every payload column>` |
| PostgREST + `Authorization` header, no JWT secret | `PGRST300 "Server lacks JWT secret"` |
| **RPC function not in PostgREST's schema cache** | `404`, code **`PGRST202`** — *see §3.7* |
| Calling a missing function from the SQL Editor | `42883` `function … does not exist` |

`anon` = the role for publishable-key requests with no logged-in user.
`authenticated` = logged-in users. A **secret / `service_role` key bypasses RLS
entirely** and must never reach a browser.

---

## 5. The `status.html` security model

4 tables: `students`, `modules`, `assignments` (catalogue), `progress` (one row per
student × assignment; composite PK makes duplicate cells impossible).

Because the user chose dropdown identity with **no authentication**, attribution is a
self-declared honour system. What the schema *does* guarantee (all verified by running
as the `anon` role):

* read everything; **no `INSERT`/`UPDATE`/`DELETE` grant on any table**
* the **only** write path is `public.set_submission(bigint, int, boolean)`,
  `SECURITY DEFINER`, `set search_path = public, pg_temp`
* `PUBLIC` execute on that function is revoked; only `anon`/`authenticated` may call it
* no DELETE grant anywhere → the grid cannot be wiped
* a trigger owns `submitted_at` / `updated_at`, so clients cannot forge timestamps

**Data-driven by design:** adding "Module 3 with 4 submissions" is an `INSERT` into
`modules` + `assignments`. `status.html` reads the structure from the DB and needs no
code change.

---

## 6. Bugs already fixed — do not reintroduce

1. **The column-grant vs. upsert bug (most instructive).** `status_schema.sql`
   originally granted `UPDATE (submitted)` only, to stop clients re-pointing cells.
   But supabase-js `.upsert()` makes PostgREST emit
   `DO UPDATE SET student_id=EXCLUDED.student_id, assignment_id=…, submitted=…` —
   **every** payload column. So the write was denied on every click. A hand-written
   `DO UPDATE SET submitted=…` passed and hid the bug. Fixed by removing all table
   write grants and routing writes through `set_submission()`.
2. **`index.html` sort indicator frozen.** `renderHead()` ran only at load, so
   `aria-sort` and the arrow never followed a click. Now called from `renderAll()`.
3. **`index.html` search box rendered 250px TALL.** `flex: 1 1 250px` sat on an input
   inside a **column** flex container, so the basis became its *height*. Size it with
   `width`, never a flex-basis, inside `.field`.
4. **`index.html` controls wrapped onto two rows.** `select` auto-sizes to its longest
   option (`"engineering crew"`). Fixed with explicit widths; the search field's
   `flex-basis` of 250px also pushed the row 32px over, so it is now 200px.
5. **Test-harness false failures** (the page was right every time):
   `"2,207" !== "2207"` (commas); `offsetTop` differing by **1px** misread as a wrapped
   row; `slice(-3)` on a 7-row page including a non-blank; the overall bar computed as
   `2/6` when it is `2/42`. **Check the assertion before blaming the code.**

---

## 7. Verification discipline

Do not assume; render and inspect.

* **HTML/JS:** run headless Chrome with `--virtual-time-budget=30000 --dump-dom`,
  then parse the DOM in Python. To drive interactions, write a **test copy** of the
  page (string-replace the config) with an appended `<script>` that simulates clicks
  and stores a JSON result blob in a hidden `<pre id="TESTOUT">`. Parse it with a
  regex. This caught real bugs in every deliverable.
* **Always take a screenshot and actually look at it** (`--screenshot=…` then
  `read_image`). It caught the 250px-tall search box that no DOM assertion noticed.
* **SQL:** validate against Docker before shipping.
  ```bash
  docker run -d --name pgstatus -e POSTGRES_PASSWORD=test -p 55432:5432 postgres:16
  # vanilla PG lacks the Supabase roles — create them first:
  docker exec -i pgstatus psql -U postgres -c "create role anon nologin; create role authenticated nologin;"
  docker exec -i pgstatus psql -U postgres -v ON_ERROR_STOP=1 < status_schema.sql
  # adversarial test AS anon:
  docker exec pgstatus psql -U postgres -c "set role anon;" -c "delete from public.progress;"
  ```
  Expect `permission denied`. `ON_ERROR_STOP=1` + applying twice proves idempotency.
* **Full end-to-end:** Postgres + PostgREST + a gateway proxy that emulates Kong
  (strip `/rest/v1`, mint an `anon` JWT signed with `PGRST_JWT_SECRET`, add CORS).
  PostgREST needs the secret or it returns `PGRST300` for any request carrying an
  `Authorization` header — which supabase-js always sends.
* **Cross-check the UI against the database.** After a browser run, query Postgres and
  confirm the rows match what the page displayed. That is the check that actually
  matters.
* **Clean up:** remove your containers *and* images, kill background jobs, and verify
  the ports are free. Leave the user's containers alone.

---

## 8. File inventory

| File | Purpose |
|---|---|
| `AGENTS.md` | this file |
| `index.html` | Titanic viewer: 2,207 rows, sortable/filterable/paginated, self-contained |
| `WORKSHEET.md` | teaching worksheet: MongoDB → Supabase, verified answer key |
| `status.html` | 7×6 checkbox tracker; writes only via `set_submission()` RPC |
| `status_schema.sql` | 4 tables, trigger, RPC, RLS, seed — idempotent |
| `titanic.sql` | **the user's own file — not created by the agent, do not overwrite** |

---

## 9. Current state / open threads

* **`status.html` is LIVE and user-tested against the real cloud project.** The
  schema is applied, the seed holds the user's own student/module names (no longer
  the `Student One…Seven` placeholders), and real progress rows exist.
* Live end-state verified with **non-writing** probes (an invalid `student_id = -1`
  cannot satisfy the foreign key, so nothing can be written):
  * RPC present and executing → `23503` FK violation (not `PGRST202`)
  * direct table write closed → `42501 permission denied for table progress`
  * `progress` contained 2 real rows: `(student 5, assignment 1)` and
    `(student 5, assignment 3)`
* `status.html` was also verified end-to-end on the local Docker + PostgREST stack:
  42 boxes render, existing DB state loads checked, only the selected student's row
  is editable, tick/untick persist, and the DB cross-check matched the UI exactly.
* **Resolved incident:** the user initially ran the *first* draft of
  `status_schema.sql`, so the RPC was missing and every tick 404'd (`PGRST202`).
  Fixed with the standalone snippet in §3.7 / §4. If a future session sees
  `PGRST202` on `/rpc/set_submission`, check `pg_proc` before blaming the cache.
* **Deliberate decision — do NOT "simplify" `set_submission()` unasked.** The
  function is more machinery than this threat model strictly requires (with no auth,
  the write policy is open either way). The user reviewed this trade-off explicitly,
  agreed the function is partly a workaround for self-imposed column-grant hardening,
  and **chose to keep it** because it works and it makes the future auth upgrade a
  one-line change. Rewriting tested, working code to save lines is its own kind of
  over-engineering. Leave it.
* Offered but **not built**: a teacher overview view, an append-only audit log
  (`submission_events`), and optional Supabase Auth linking via
  `students.auth_user_id` (commented pattern in section 10 of the schema).
* The schema's section 9 is a **commented-out** block that pre-creates all 42 grid
  cells. It is not needed — a missing row simply means "not submitted".
* `index.html` and the worksheet are complete and verified. The worksheet's line-number
  references point into `index.html` — **if you edit `index.html`, those shift.**
