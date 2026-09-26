-- ============================================================================
--  status.html — student submission tracker
--  Schema, security policies and seed data for Supabase (Postgres).
--
--  HOW TO APPLY
--    1. Edit the SEED DATA section (section 8) with your real student names,
--       module titles and (optionally) submission titles.
--    2. Supabase dashboard -> SQL Editor -> paste this whole file -> Run.
--
--  Safe to re-run: every statement is idempotent.
--
--  DATA MODEL (4 tables)
--    students     the 7 people
--    modules      the 2 modules
--    assignments  the catalogue of submissions (which ones exist per module)
--    progress     one row per (student x assignment) = a single grid cell
--
--  Because assignments are DATA rather than columns, adding "Module 3 with 4
--  submissions" later is an INSERT — no schema change and no code change.
--
--  WRITE PATH
--    There is NO direct INSERT/UPDATE/DELETE access to any table. The only way
--    to change anything is the set_submission() function, which does one
--    narrowly-scoped upsert. See section 6.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 1. Students
-- ---------------------------------------------------------------------------
create table if not exists public.students (
  id         bigint generated always as identity primary key,
  full_name  text not null unique,
  sort_order int  not null default 0,
  created_at timestamptz not null default now()
);


-- ---------------------------------------------------------------------------
-- 2. Modules
-- ---------------------------------------------------------------------------
create table if not exists public.modules (
  id         int  generated always as identity primary key,
  title      text not null unique,
  sort_order int  not null default 0
);


-- ---------------------------------------------------------------------------
-- 3. Assignments — the catalogue of submissions belonging to each module
-- ---------------------------------------------------------------------------
create table if not exists public.assignments (
  id        int      generated always as identity primary key,
  module_id int      not null references public.modules(id) on delete cascade,
  sequence  smallint not null check (sequence > 0),
  title     text     not null,
  unique (module_id, sequence)
);


-- ---------------------------------------------------------------------------
-- 4. Progress — the grid cells. Primary key makes duplicate cells impossible.
-- ---------------------------------------------------------------------------
create table if not exists public.progress (
  student_id    bigint      not null references public.students(id)    on delete cascade,
  assignment_id int         not null references public.assignments(id) on delete cascade,
  submitted     boolean     not null default false,
  submitted_at  timestamptz,
  updated_at    timestamptz not null default now(),
  primary key (student_id, assignment_id)
);


-- ---------------------------------------------------------------------------
-- 5. Timestamp trigger
--    The client only ever sends `submitted`. The database owns both
--    timestamps, so they can never be forged or drift.
-- ---------------------------------------------------------------------------
create or replace function public.touch_progress()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();

  if tg_op = 'INSERT' then
    new.submitted_at := case when new.submitted then now() else null end;
  else
    if new.submitted and not old.submitted then
      new.submitted_at := now();              -- just ticked
    elsif not new.submitted then
      new.submitted_at := null;               -- unticked
    else
      new.submitted_at := old.submitted_at;   -- unchanged: keep the original
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_touch_progress on public.progress;
create trigger trg_touch_progress
  before insert or update on public.progress
  for each row execute function public.touch_progress();


-- ---------------------------------------------------------------------------
-- 6. The ONLY write path: set_submission()
--
--    Why a function instead of a direct table upsert?
--
--    supabase-js `.upsert()` makes PostgREST emit:
--        INSERT ... ON CONFLICT DO UPDATE SET
--          student_id = EXCLUDED.student_id,
--          assignment_id = EXCLUDED.assignment_id,
--          submitted = EXCLUDED.submitted
--    i.e. it assigns EVERY column in the payload, not just `submitted`. So a
--    column-level grant of UPDATE(submitted) alone makes the upsert fail with
--    "permission denied for table progress".
--
--    Granting UPDATE on the key columns instead would let a client re-point a
--    cell at a different student. So we take the write path away from the
--    client entirely: this function runs as its owner (SECURITY DEFINER),
--    performs exactly one upsert of one boolean, and is the only thing anon
--    may execute. The trigger still owns the timestamps.
--
--    `set search_path` is required on SECURITY DEFINER functions to prevent
--    search_path hijacking.
-- ---------------------------------------------------------------------------
create or replace function public.set_submission(
  p_student_id    bigint,
  p_assignment_id int,
  p_submitted     boolean
)
returns public.progress
language sql
security definer
set search_path = public, pg_temp
as $$
  insert into public.progress (student_id, assignment_id, submitted)
  values (p_student_id, p_assignment_id, p_submitted)
  on conflict (student_id, assignment_id)
  do update set submitted = excluded.submitted
  returning *;
$$;


-- ---------------------------------------------------------------------------
-- 7. Row Level Security + privileges
--
--    Read:  everything is publicly readable (the whole 7x6 grid is visible).
--    Write: only via set_submission(), which writes one boolean.
--
--    There are deliberately NO insert/update/delete policies: with RLS enabled
--    and no policy, those commands are denied even if a grant is ever added by
--    accident. Belt and braces alongside the missing grants.
-- ---------------------------------------------------------------------------
alter table public.students    enable row level security;
alter table public.modules     enable row level security;
alter table public.assignments enable row level security;
alter table public.progress    enable row level security;

drop policy if exists "read students" on public.students;
create policy "read students" on public.students
  for select to anon, authenticated using (true);

drop policy if exists "read modules" on public.modules;
create policy "read modules" on public.modules
  for select to anon, authenticated using (true);

drop policy if exists "read assignments" on public.assignments;
create policy "read assignments" on public.assignments
  for select to anon, authenticated using (true);

drop policy if exists "read progress" on public.progress;
create policy "read progress" on public.progress
  for select to anon, authenticated using (true);

-- Remove the older, weaker policies if this file was applied before.
drop policy if exists "insert progress" on public.progress;
drop policy if exists "toggle progress" on public.progress;

grant usage on schema public to anon, authenticated;

-- SELECT only. No INSERT, UPDATE or DELETE on any table, for anyone.
revoke all on public.students    from anon, authenticated;
revoke all on public.modules     from anon, authenticated;
revoke all on public.assignments from anon, authenticated;
revoke all on public.progress    from anon, authenticated;

grant select on public.students    to anon, authenticated;
grant select on public.modules     to anon, authenticated;
grant select on public.assignments to anon, authenticated;
grant select on public.progress    to anon, authenticated;

-- The single permitted action.
revoke all on function public.set_submission(bigint, int, boolean) from public;
grant execute on function public.set_submission(bigint, int, boolean) to anon, authenticated;


-- ============================================================================
-- 8. SEED DATA  ←←← EDIT THE NAMES BELOW
-- ============================================================================

insert into public.students (full_name, sort_order) values
  ('Student One',   1),
  ('Student Two',   2),
  ('Student Three', 3),
  ('Student Four',  4),
  ('Student Five',  5),
  ('Student Six',   6),
  ('Student Seven', 7)
on conflict (full_name) do nothing;

insert into public.modules (title, sort_order) values
  ('Module 1', 1),
  ('Module 2', 2)
on conflict (title) do nothing;

-- Three submissions for every module, created in one shot and idempotent.
insert into public.assignments (module_id, sequence, title)
select m.id, s.seq, 'Submission ' || s.seq
from public.modules m
cross join (values (1), (2), (3)) as s(seq)
on conflict (module_id, sequence) do nothing;


-- ============================================================================
-- 9. OPTIONAL — pre-create all 42 grid cells
--    Not required: a cell with no row simply means "not submitted", and rows
--    are created on first tick. Uncomment if you prefer rows to exist up front.
-- ============================================================================
-- insert into public.progress (student_id, assignment_id, submitted)
-- select s.id, a.id, false
-- from public.students s cross join public.assignments a
-- on conflict do nothing;


-- ============================================================================
-- 10. SECURITY NOTE
--
--    This design has NO authentication, so it cannot stop one student from
--    ticking another student's box — attribution is a self-declared dropdown
--    value. What it DOES prevent, verified by testing as the `anon` role:
--
--      * deleting anything (no DELETE grant anywhere)
--      * wiping or modifying the roster, modules or assignment catalogue
--      * re-pointing a cell at a different student
--      * forging submitted_at / updated_at
--      * inserting arbitrary rows
--
--    To add real per-student write protection later, add Supabase Auth plus a
--    `students.auth_user_id uuid references auth.users(id)` column, then
--    require the caller to own the cell inside set_submission(), e.g.:
--
--      if not exists (
--        select 1 from public.students
--        where id = p_student_id and auth_user_id = auth.uid()
--      ) then
--        raise exception 'not your row';
--      end if;
-- ============================================================================
