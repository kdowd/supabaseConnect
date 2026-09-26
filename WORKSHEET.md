# Worksheet — Connecting a Web Page to Supabase

**Audience:** someone who knows MongoDB and is new to Supabase / Postgres / HTTP APIs.
**Companion artifact:** `index.html` in this folder (a working Titanic table viewer).
**Time:** roughly 2–3 hours if you do every part and the challenge.

Everything in the answer key was verified against the live project, so the numbers are real — you can check your work against them.

---

## 0. Setup

Serve the folder (don't open the file directly if you can avoid it — an `http://` origin behaves like a real deployment):

```bash
python3 -m http.server 8137 --bind 127.0.0.1
```

Then open <http://127.0.0.1:8137/index.html>. You should see a green pill reading **Connected · 2,207 rows**.

> **Work on a copy.** For the "break it on purpose" drills, copy `index.html` to `lab.html` and edit that, so the working page stays intact.

**The project you're talking to**

| Thing | Value |
|---|---|
| Project URL | `https://pkpbzthkwskkudqogyrl.supabase.co` |
| Table | `public.titanic` |
| Rows | 2,207 |
| Columns | `id, name, gender, age, class, embarked, country, fare, survived` |

---

## Part 1 — The mental model

Before touching code, fix this in your head, because it's the biggest difference from MongoDB.

**MongoDB** is a *server you connect to* and *hold a connection open to*. Your driver speaks a binary wire protocol over a socket you explicitly opened with `await client.connect()`.

**Supabase** is an *HTTP API in front of a Postgres database*. There is no connection to open. Every query is a separate HTTPS request — the same kind of request your browser makes when it loads an image. The server is stateless between requests.

Consequences you'll feel immediately:

1. There is no `connect()` and no `disconnect()`.
2. You can debug the entire data layer with `curl` and the browser Network tab.
3. Failures arrive as **HTTP status codes** (404, 400, 401), not socket exceptions.

### Exercise 1.1 — Predict the translation

Without looking ahead, write the Supabase equivalent of each MongoDB call. Then check the cheat sheet at the end.

```
new MongoClient(uri)                        -> ?
client.db("x").collection("titanic")        -> ?
.find({})                                   -> ?
.sort({ id: 1 })                            -> ?
.skip(0).limit(1000)                        -> ?
```

### Exercise 1.2 — The missing method

Look at `index.html` lines 535–540. `createClient(...)` is called **without** `await`.

**Q:** Why? What would you expect `await supabase.createClient(...)` to even wait for?

<details><summary>Answer</summary>

It's an ordinary synchronous function that builds a small configuration object. It opens no socket, so there's nothing to await. `await` on a non-promise just returns the value immediately — harmless but misleading. Contrast with `new MongoClient(uri)` + `await client.connect()`, where a real network handshake happens.
</details>

---

## Part 2 — Guided code reading

Open `index.html` and read these regions. Answer before expanding.

```js
// line 7 (in <head>)
<script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/dist/umd/supabase.js"></script>

// lines 476-480
const SUPABASE_URL = "https://pkpbzthkwskkudqogyrl.supabase.co";
const SUPABASE_KEY = "sb_publishable_MOHaPhKPaA_4Gb7ZMgxQgg_I4YNNk_w";
const TABLE        = "titanic";
const CHUNK        = 1000;
const PAGE_SIZE    = 50;

// lines 537-551
client = window.supabase.createClient(SUPABASE_URL, SUPABASE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false }
});

const { data, error } = await client
  .from(TABLE)
  .select("*")
  .order("id", { ascending: true })
  .range(from, to);
```

### Exercise 2.1 — URL vs key

**Q:** In `mongodb+srv://user:password@host/dbname`, the address and the credentials are one string. Supabase splits them. Why does that split make sense here?

<details><summary>Answer</summary>

Because the key isn't a database password — it's an **API token** sent as an HTTP header (`apikey` / `Authorization: Bearer`) on each request. The URL identifies *which* service; the key identifies *who* is asking. A password would be useless on its own without the protocol and host, but a bearer token is meaningful to any request against that host.
</details>

### Exercise 2.2 — The range is inclusive

`.range(from, to)` with `from = 0` and `to = 999`.

**Q:** How many rows does that request? If you wanted 1,000 rows, would `.range(0, 1000)` be right?

<details><summary>Answer</summary>

`range(0, 999)` = 1,000 rows; both ends are **inclusive**. `.range(0, 1000)` would ask for 1,001. It maps to the HTTP `Range: 0-999` header, and HTTP byte/row ranges are inclusive.
</details>

### Exercise 2.3 — Two different "pages"

The file has both `CHUNK = 1000` and `PAGE_SIZE = 50`. Learners routinely conflate these.

**Q:** What is each one for? How many network requests does the page make in total?

<details><summary>Answer</summary>

- `CHUNK = 1000` — **network** paging. How many rows per HTTP request, forced by the server's 1,000-row cap.
- `PAGE_SIZE = 50` — **UI** paging. How many rows are displayed at once.

The page fetches all 2,207 rows into memory in **3 requests** (1000 + 1000 + 207), then slices that array for display. Filtering, sorting and search then happen entirely in JavaScript with no network traffic — which is why they feel instant.
</details>

### Exercise 2.4 — Why `auth: {...}`

**Q:** What do `persistSession: false` and `autoRefreshToken: false` switch off, and why does this page want them off?

<details><summary>Answer</summary>

They disable the login/session machinery — supabase-js otherwise stores auth tokens (in `localStorage`) and refreshes them in the background. This page never logs anyone in; it only does anonymous reads. Turning both off avoids writing tokens to the browser for no reason. It's a data client here, not an auth client.
</details>

---

## Part 3 — See the HTTP underneath

The library is sugar. This part proves it.

### Exercise 3.1 — Reproduce the query with curl

Run this and compare it to what `.from().select().order().range()` builds:

```bash
K="sb_publishable_MOHaPhKPaA_4Gb7ZMgxQgg_I4YNNk_w"
B="https://pkpbzthkwskkudqogyrl.supabase.co/rest/v1"

curl -s -D - "$B/titanic?select=*&order=id.asc&limit=2" \
  -H "apikey: $K" -H "Authorization: Bearer $K"
```

**Q1:** What HTTP status comes back?
**Q2:** What does `content-range: 0-1/*` tell you? What does the `*` mean?

<details><summary>Answer</summary>

**Q1:** `200`.

**Q2:** It describes the slice of rows returned: rows 0 through 1 of an **unknown** total. The `*` means the server didn't count the whole table (counting is expensive). To force a real total, add `Prefer: count=exact`:

```bash
curl -s -o /dev/null -D - "$B/titanic?select=id" \
  -H "apikey: $K" -H "Authorization: Bearer $K" \
  -H "Range: 0-999" -H "Prefer: count=exact" | grep -i content-range
# -> content-range: 0-999/2207
```

That `/2207` is exactly how the page knows the dataset size.
</details>

### Exercise 3.2 — Network tab

Open DevTools → **Network**, reload the page, and find the requests to `pkpbzthkwskkudqogyrl.supabase.co`.

**Q:** How many requests are there? Do the `Range` headers match your answer to Exercise 2.3?

<details><summary>Answer</summary>

Three requests to the `/rest/v1/titanic` endpoint, with `Range: 0-999`, `Range: 1000-1999`, `Range: 2000-3206` (or similar). The third returns only 207 rows. This is the single best way to demystify the library — the abstraction is thin.
</details>

---

## Part 4 — Debugging drills (read-only, safe)

**Copy `index.html` to `lab.html` first.** Each drill: make the change, reload, observe, then note the HTTP status and error `code`.

> These drills only break *reads*. Do **not** invent write tests against the live table — see the security note at the end.

### Drill 4.1 — Nonexistent table

Change `TABLE` to `"no_such_table_xyz"`.

- Status code? Error `code`? Does the page show the error panel or silently render nothing?

### Drill 4.2 — Nonexistent column

Restore the table, then change `.select("*")` to `.select("nope")`.

- Status code? Error `code`? What does the `hint` field suggest?

### Drill 4.3 — Remove the key

Set `SUPABASE_KEY = ""`.

- Status code? What does the message say?

### Drill 4.4 — The error-handling trap

Read lines 553–559:

```js
if (error) {
  const err = new Error(error.message || "Supabase request failed");
  err.details = error.details;
  err.hint = error.hint;
  err.code = error.code;
  throw err;
}
```

**Q:** Why bother re-throwing? Why not just show `error.message` directly? What would happen if this whole `if (error)` block were deleted?

<details><summary>Answer</summary>

supabase-js **does not throw** for API-level failures. It resolves the promise and hands you `{ data: null, error: {...} }`. So a `try/catch` alone catches nothing — you'd get `data === null` and the page would render an empty table with no explanation.

The `if (error) ... throw err` converts the returned error back into a real exception so the *outer* `try/catch` (line 848) behaves the way MongoDB habits expect, and so the UI can display `code` / `details` / `hint`.

Delete the block and every drill above becomes a **silent failure**.
</details>

---

## Part 5 — The silent 1,000-row bug

The most dangerous bug in this worksheet, because **nothing errors**.

### Exercise 5.1 — Reproduce it

```bash
K="sb_publishable_MOHaPhKPaA_4Gb7ZMgxQgg_I4YNNk_w"
B="https://pkpbzthkwskkudqogyrl.supabase.co/rest/v1"

# how many rows come back with no Range header at all?
curl -s "$B/titanic?select=id" -H "apikey: $K" -H "Authorization: Bearer $K" \
  | python3 -c "import sys,json; print('rows:', len(json.load(sys.stdin)))"
```

**Q:** The table has 2,207 rows. How many did you get? Was there an error?

<details><summary>Answer</summary>

**1,000 rows, and no error.** PostgREST applies a server-side maximum (default 1,000) and silently truncates. You get a `200 OK` and a plausible-looking payload.

This is exactly why naive code like this is *wrong*:

```js
const { data } = await client.from("titanic").select("*");  // silently 1,000 rows
```

Your totals, averages and counts would all be quietly incorrect.
</details>

### Exercise 5.2 — Fix it

Now read the loop at lines 542–567 in `index.html`.

**Q1:** Why is `.order("id", { ascending: true })` necessary for the loop, rather than cosmetic?
**Q2:** Why does the loop stop on a *short* page (`data.length < CHUNK`) rather than on an empty page?

<details><summary>Answer</summary>

**Q1:** Without a stable, unique sort, the database is free to return rows in a different order for each request. Paging with `Range` would then skip some rows and duplicate others. A deterministic `ORDER BY` is what makes offset paging correct. (Ties on a non-unique column break this too — hence sorting by `id`.)

**Q2:** A short page means you've reached the end: 207 < 1000. Stopping only on an empty page would cost one extra request, and — more importantly — it's the wrong signal, since a full page followed by a short one is the normal ending.
</details>

### Exercise 5.3 — Break the ordering

In `lab.html`, change `.order("id", { ascending: true })` to remove the `.order(...)` call entirely. Reload a few times and watch the last page / total.

**Q:** Does the total stay at 2,207? Look for duplicate or missing ids across your three pages.

> **Note:** Postgres often returns a consistent order in practice for small tables, so this may not visibly break. That's the point — it's a *latent* bug. It bites when the planner changes, the table grows, or rows are updated. Explain why you'd never rely on it.

---

## Part 6 — Build your own mini client

Now write the connection from scratch. Create `lab.html` in this folder:

```html
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8" />
  <title>Supabase lab</title>
  <script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/dist/umd/supabase.js"></script>
</head>
<body>
  <h1>Lab</h1>
  <pre id="out">loading…</pre>

  <script>
    const SUPABASE_URL = "https://pkpbzthkwskkudqogyrl.supabase.co";
    const SUPABASE_KEY = "sb_publishable_MOHaPhKPaA_4Gb7ZMgxQgg_I4YNNk_w";

    const client = window.supabase.createClient(SUPABASE_URL, SUPABASE_KEY, {
      auth: { persistSession: false, autoRefreshToken: false }
    });

    const out = document.getElementById("out");

    async function main() {
      // ---- TASK 1: fetch the first 5 rows, ordered by id ascending ----
      // ---- TASK 2: print how many rows came back ----
      // ---- TASK 3: count survivors using .eq("survived", "yes") ----
      //             hint: use { count: "exact", head: true } to get a count
      //             without downloading the rows
      // ---- TASK 4: find passengers in 1st class who survived ----
      // ---- TASK 5: always check `error` before using `data` ----
    }

    main();
  </script>
</body>
</html>
```

### Task notes

- **Filters** replace the client-side JS filtering used by `index.html`. The MongoDB analogue is `.find({ survived: "yes" })` → `.select("*").eq("survived", "yes")`.
- **Chaining** multiple filters narrows the result, like an implicit `AND`: `.eq("class", "1st").eq("survived", "yes")`.
- **Counting without fetching** — `head: true` asks for the count only:

```js
const { count, error } = await client
  .from("titanic")
  .select("*", { count: "exact", head: true })
  .eq("survived", "yes");
```

**Checkpoints (verified against the live data):**

| Task | Expected |
|---|---|
| T1 first row id | `1` |
| T1 first row name | `Abbing, Mr. Anthony` |
| T3 survivors count | `711` |
| T4 1st class + survived | `201` |
| Total rows | `2207` |
| Female passengers | `489` (of whom `359` survived) |

---

## Part 7 — Challenge exercises

1. **Average age, done server-side.** The page computes this in JS. PostgREST can't `AVG()` directly — explain why, then describe two ways to get it (fetch-and-compute client-side vs. a Postgres view or RPC function).
2. **Sort by a text column.** Add a button to `lab.html` that lists the 10 oldest passengers. Remember `age` is stored as **text**, so a naive `order("age")` sorts `"9"` after `"10"`. Verify this, then explain how you'd fix it.
3. **Explain the `PAGE_SIZE` vs `CHUNK` tradeoff.** If `CHUNK` were 200 instead of 1000, what changes? What if `PAGE_SIZE` were 1000?
4. **Security reasoning.** The key is in plain HTML. Write three sentences explaining to a non-technical colleague why that is *sometimes* acceptable and what condition makes it unacceptable.

<details><summary>Hints for 2 and 4</summary>

**2.** Text sorting is lexicographic: `"9" > "10"`. Fixes: cast in the database (`order("age::int")` isn't valid PostgREST syntax — you'd use an RPC/view), or fetch and sort numerically in JS, which is what `index.html`'s `num()` + comparator already does.

**4.** The publishable key is safe to expose **only because Row Level Security** limits what it can touch. Think of it as a database user with a restrictive role — except the rules are per-row policies. The moment RLS is off (or a policy is too permissive), that key becomes a full-access credential for anyone who views source.
</details>

---

## Answer key — verified API behaviour

These are real responses captured from your project.

**Nonexistent table** → `404`

```json
{"code":"PGRST205","details":null,"hint":null,
 "message":"Could not find the table 'public.no_such_table_xyz' in the schema cache"}
```

**Nonexistent column** → `400`

```json
{"code":"42703","details":null,
 "hint":"Perhaps you meant to reference the column \"titanic.name\".",
 "message":"column titanic.nope does not exist"}
```

**No API key** → `401`

```json
{"message":"No API key found in request",
 "hint":"No `apikey` request header or url param was found."}
```

**Normal request** → `200`, `content-range: 0-1/*`
**With `Range: 0-999` + `Prefer: count=exact`** → `content-range: 0-999/2207`
**No `Range` header** → silently capped at **1,000** rows

---

## Cheat sheet — MongoDB → Supabase

| MongoDB | Supabase |
|---|---|
| `new MongoClient(uri)` | `createClient(url, key)` |
| `await client.connect()` | — none; HTTP per request |
| `client.db("x").collection("titanic")` | `.from("titanic")` |
| `.find({})` | `.select("*")` |
| `.find({}, { name: 1 })` | `.select("name")` |
| `.sort({ id: 1 })` | `.order("id", { ascending: true })` |
| `.skip(0).limit(1000)` | `.range(0, 999)` |
| `.find({ survived: "yes" })` | `.select("*").eq("survived", "yes")` |
| `.findOne({ id: 1 })` | `.select("*").eq("id", 1).single()` |
| `.countDocuments()` | `.select("*", { count: "exact", head: true })` |
| errors **throw** | returns `{ data, error }` — **check it** |
| cursor reads everything | server caps at **1,000**/request |

**Concept map:** project URL ≈ host · API key ≈ bearer token (not a password) · table ≈ collection · row ≈ document · column ≈ field · PostgREST ≈ the query layer · RLS ≈ per-row permissions.

---

## Security note (read before experimenting)

This `titanic` table currently has Row Level Security **disabled**, which makes it publicly readable **and writable** by anyone holding the key in this page's source.

I confirmed this accidentally while preparing this worksheet: a probe request intended to be rejected was instead accepted (`201 Created`) and **inserted a row**. I deleted it immediately and verified the table is back to its original 2,207 rows. The lesson is real, and it's the most important one here:

> A `201 Created` from a request you expected to fail is the clearest possible evidence that your table has no write protection.

**Recommended fix:** enable RLS and add a read-only policy for the `anon` role:

```sql
alter table public.titanic enable row level security;

create policy "public read" on public.titanic
  for select to anon using (true);
```

That keeps this page working (it only ever reads) while removing anonymous `INSERT`/`UPDATE`/`DELETE`. Any write drills should be done on a throwaway table you create for that purpose.
