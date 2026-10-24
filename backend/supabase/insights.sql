-- JobSummit "Help improve job picks": what phones that opted in share, and what the
-- pipeline learns from it. Paste into Supabase -> SQL Editor -> Run (safe to run again).
--
-- Phones (the public "publishable" key) can only call ingest() and forget(). They
-- can't read anything back. The tables live in the "insights" schema, which the API
-- doesn't expose; the project owner sees them in the Table Editor (the admin view),
-- and the pipeline reads the summary through picks_training() with the secret key.
--
-- Nothing here names a person: a random id per phone, age as a band, no Google
-- account data, no saved IDs or passwords.

create schema if not exists insights;
revoke all on schema insights from public, anon, authenticated;

create table if not exists insights.installs (
  id          uuid primary key,
  app_version text,
  created_at  timestamptz not null default now(),
  last_seen   timestamptz not null default now()
);

create table if not exists insights.profiles (
  install_id       uuid primary key references insights.installs (id) on delete cascade,
  age_band         text,       -- "18-21", "22-25", ...
  category         text,       -- UR / OBC / SC / ST / EWS
  pwbd             boolean,
  ex_serviceman    boolean,
  qual_level       text,       -- MATRIC / HSC / DIPLOMA / UG / PG / ...
  degrees          text[],     -- degree codes: B_TECH, BSC, ...
  subjects         text[],     -- "engineering:ece", ...
  experience_band  text,       -- "0", "1-2", "3-5", "6+"
  updated_at       timestamptz not null default now()
);

create table if not exists insights.preferences (
  install_id     uuid primary key references insights.installs (id) on delete cascade,
  show_first     text[],
  hidden_groups  text[],
  hidden_types   text[],
  min_pay        integer,
  languages      text[],
  updated_at     timestamptz not null default now()
);

create table if not exists insights.exams (
  install_id  uuid not null references insights.installs (id) on delete cascade,
  exam_id     text,            -- the app's exam list id, when known
  exam_name   text not null,
  stage       text,
  status      text,
  from_feed   boolean,
  primary key (install_id, exam_name)
);

create table if not exists insights.decisions (
  install_id  uuid not null references insights.installs (id) on delete cascade,
  job_id      text not null,
  applied     boolean not null,  -- false = "not for me"
  features    text[] not null,   -- cat:bank, org:..., role:clerk, type:..., pay:...
  decided_at  timestamptz,
  primary key (install_id, job_id)
);

alter table insights.installs enable row level security;
alter table insights.profiles enable row level security;
alter table insights.preferences enable row level security;
alter table insights.exams enable row level security;
alter table insights.decisions enable row level security;

-- One phone's whole state, replacing what it sent before. At most once an hour
-- per phone (the app sends once a day, or when something changed); capped sizes;
-- unknown fields ignored.
create or replace function public.ingest(payload jsonb)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  iid uuid := (payload->>'install_id')::uuid;
  seen timestamptz;
  p jsonb := payload->'profile';
  pr jsonb := payload->'preferences';
begin
  if iid is null then return 'no id'; end if;
  if octet_length(payload::text) > 300000 then return 'too big'; end if;
  select last_seen into seen from insights.installs where id = iid;
  if seen is not null and seen > now() - interval '1 hour' then return 'too soon'; end if;
  -- A flood of new ids in one day: refuse more until tomorrow.
  if seen is null and (select count(*) from insights.installs where created_at > now() - interval '1 day') > 20000
  then return 'busy'; end if;

  insert into insights.installs (id, app_version) values (iid, left(payload->>'app_version', 20))
  on conflict (id) do update set app_version = excluded.app_version, last_seen = now();

  if p is not null then
    insert into insights.profiles (install_id, age_band, category, pwbd, ex_serviceman, qual_level, degrees, subjects, experience_band)
    values (
      iid, left(p->>'age_band', 10), left(p->>'category', 10), (p->>'pwbd')::boolean, (p->>'ex_serviceman')::boolean,
      left(p->>'qual_level', 20),
      array(select left(x, 40) from jsonb_array_elements_text(coalesce(p->'degrees', '[]')) x limit 6),
      array(select left(x, 60) from jsonb_array_elements_text(coalesce(p->'subjects', '[]')) x limit 12),
      left(p->>'experience_band', 10))
    on conflict (install_id) do update set
      age_band = excluded.age_band, category = excluded.category, pwbd = excluded.pwbd,
      ex_serviceman = excluded.ex_serviceman, qual_level = excluded.qual_level, degrees = excluded.degrees,
      subjects = excluded.subjects, experience_band = excluded.experience_band, updated_at = now();
  end if;

  if pr is not null then
    insert into insights.preferences (install_id, show_first, hidden_groups, hidden_types, min_pay, languages)
    values (
      iid,
      array(select left(x, 30) from jsonb_array_elements_text(coalesce(pr->'show_first', '[]')) x limit 20),
      array(select left(x, 30) from jsonb_array_elements_text(coalesce(pr->'hidden_groups', '[]')) x limit 20),
      array(select left(x, 30) from jsonb_array_elements_text(coalesce(pr->'hidden_types', '[]')) x limit 10),
      least(greatest(coalesce((pr->>'min_pay')::integer, 0), 0), 1000000),
      array(select left(x, 30) from jsonb_array_elements_text(coalesce(pr->'languages', '[]')) x limit 20))
    on conflict (install_id) do update set
      show_first = excluded.show_first, hidden_groups = excluded.hidden_groups, hidden_types = excluded.hidden_types,
      min_pay = excluded.min_pay, languages = excluded.languages, updated_at = now();
  end if;

  delete from insights.exams where install_id = iid;
  insert into insights.exams (install_id, exam_id, exam_name, stage, status, from_feed)
  select iid, left(e->>'exam_id', 60), left(e->>'exam_name', 120), left(e->>'stage', 40), left(e->>'status', 30),
         (e->>'from_feed')::boolean
  from (select e from jsonb_array_elements(coalesce(payload->'exams', '[]')) e limit 100) t
  where coalesce(e->>'exam_name', '') <> ''
  on conflict do nothing;

  delete from insights.decisions where install_id = iid;
  insert into insights.decisions (install_id, job_id, applied, features, decided_at)
  select iid, left(d->>'job_id', 80), (d->>'applied')::boolean,
         array(select left(x, 60) from jsonb_array_elements_text(coalesce(d->'features', '[]')) x limit 12),
         (d->>'at')::timestamptz
  from (select d from jsonb_array_elements(coalesce(payload->'decisions', '[]')) d limit 2000) t
  where d->>'job_id' is not null and d->>'applied' is not null
  on conflict do nothing;

  return 'ok';
end;
$$;

-- "Delete my data": everything for this phone's id.
create or replace function public.forget(install_id uuid)
returns text
language sql
security definer
set search_path = ''
as $$
  delete from insights.installs where id = forget.install_id;
  select 'ok';
$$;

-- For the pipeline (secret key only): per group of people with the same degree
-- (or the same level, or everyone), how often each job feature was applied to and
-- turned down, and by how many people. Groups of fewer than 5 people are left out.
create or replace function public.picks_training()
returns table (cohort text, feature text, applied bigint, rejected bigint, people bigint)
language sql
security definer
set search_path = ''
as $$
  with d as (
    select d.install_id, d.applied, f as feature, p.qual_level, p.degrees
    from insights.decisions d
    join insights.profiles p using (install_id)
    cross join lateral unnest(d.features) f
  ),
  c as (
    select 'all' as cohort, install_id, applied, feature from d
    union all
    select 'lvl:' || qual_level, install_id, applied, feature from d where qual_level is not null
    union all
    select 'deg:' || deg, install_id, applied, feature from d cross join lateral unnest(degrees) deg
  )
  select cohort, feature, count(*) filter (where applied), count(*) filter (where not applied), count(distinct install_id)
  from c group by cohort, feature having count(distinct install_id) >= 5;
$$;

-- Same, by job: which jobs people of a degree applied to (for the career-track model).
create or replace function public.picks_jobs()
returns table (cohort text, job_id text, applied bigint, rejected bigint)
language sql
security definer
set search_path = ''
as $$
  select 'deg:' || deg, d.job_id, count(*) filter (where d.applied), count(*) filter (where not d.applied)
  from insights.decisions d join insights.profiles p using (install_id) cross join lateral unnest(p.degrees) deg
  group by 1, 2 having count(distinct d.install_id) >= 5;
$$;

revoke all on function public.ingest(jsonb), public.forget(uuid), public.picks_training(), public.picks_jobs()
  from public, anon, authenticated;
grant execute on function public.ingest(jsonb), public.forget(uuid) to anon, authenticated;
grant execute on function public.picks_training(), public.picks_jobs() to service_role;

-- Admin views (Table Editor -> schema "insights"): the dashboard.
create or replace view insights.daily_active as
  select date_trunc('day', last_seen)::date as day, count(*) as phones from insights.installs group by 1 order by 1 desc;
create or replace view insights.by_degree as
  select unnest(degrees) as degree, qual_level, count(*) as people from insights.profiles group by 1, 2 order by 3 desc;
create or replace view insights.exam_popularity as
  select coalesce(exam_id, exam_name) as exam, count(*) as people,
         count(*) filter (where status in ('result_declared', 'answer_key_live')) as finished
  from insights.exams group by 1 order by 2 desc;
create or replace view insights.group_apply_rates as
  select f as job_group, count(*) filter (where applied) as applied, count(*) filter (where not applied) as not_for_me
  from insights.decisions cross join lateral unnest(features) f where f like 'cat:%' group by 1 order by 2 desc;
