-- ============================================================
-- SilverConnect database schema
-- Paste this whole file into Supabase → SQL Editor → New query → Run
-- ============================================================

-- Needed for secure PIN hashing (bcrypt-style, via crypt()/gen_salt)
create extension if not exists pgcrypto;

-- ---------- Tables ----------
create table if not exists users (
  phone        text primary key,
  name         text not null,
  pin_hash     text not null,
  role         text not null check (role in ('senior','caretaker')),
  family_code  text not null,
  created_at   timestamptz default now()
);

create table if not exists families (
  code          text primary key,
  senior_phone  text not null references users(phone) on delete cascade,
  created_at    timestamptz default now()
);

-- lets one caretaker link to more than one senior later if you want to extend this
create table if not exists caretaker_links (
  caretaker_phone text not null references users(phone) on delete cascade,
  family_code     text not null references families(code) on delete cascade,
  primary key (caretaker_phone, family_code)
);

create table if not exists checkins (
  id            bigserial primary key,
  senior_phone  text not null references users(phone) on delete cascade,
  created_at    timestamptz default now()
);

create table if not exists moods (
  id            bigserial primary key,
  phone         text not null references users(phone) on delete cascade,
  emoji         text not null,
  label         text not null,
  created_at    timestamptz default now()
);

-- ---------- Lock every table down ----------
-- Row Level Security is ON with NO policies for anon, meaning the app
-- can only ever touch data through the functions below — never directly.
-- This keeps pin_hash (and everything else) unreadable to the browser.
alter table users            enable row level security;
alter table families         enable row level security;
alter table caretaker_links  enable row level security;
alter table checkins         enable row level security;
alter table moods            enable row level security;

-- ---------- Functions (the only way in) ----------
-- security definer = runs with the owner's rights, bypassing RLS safely,
-- because each function only exposes exactly what it's meant to.

create or replace function register_senior(p_name text, p_phone text, p_pin text)
returns table(phone text, name text, role text, family_code text)
language plpgsql security definer as $$
declare
  v_code text;
begin
  if exists (select 1 from users u where u.phone = p_phone) then
    raise exception 'PHONE_TAKEN';
  end if;
  v_code := lpad(floor(random()*900000+100000)::text, 6, '0');
  insert into users(phone, name, pin_hash, role, family_code)
  values (p_phone, p_name, crypt(p_pin, gen_salt('bf')), 'senior', v_code);
  insert into families(code, senior_phone) values (v_code, p_phone);
  return query select p_phone, p_name, 'senior'::text, v_code;
end;
$$;

create or replace function register_caretaker(p_name text, p_phone text, p_pin text, p_code text)
returns table(phone text, name text, role text, family_code text)
language plpgsql security definer as $$
begin
  if exists (select 1 from users u where u.phone = p_phone) then
    raise exception 'PHONE_TAKEN';
  end if;
  if not exists (select 1 from families f where f.code = p_code) then
    raise exception 'CODE_NOT_FOUND';
  end if;
  insert into users(phone, name, pin_hash, role, family_code)
  values (p_phone, p_name, crypt(p_pin, gen_salt('bf')), 'caretaker', p_code);
  insert into caretaker_links(caretaker_phone, family_code) values (p_phone, p_code);
  return query select p_phone, p_name, 'caretaker'::text, p_code;
end;
$$;

create or replace function login(p_phone text, p_pin text)
returns table(phone text, name text, role text, family_code text)
language plpgsql security definer as $$
begin
  return query
    select u.phone, u.name, u.role, u.family_code
    from users u
    where u.phone = p_phone and u.pin_hash = crypt(p_pin, u.pin_hash);
end;
$$;

create or replace function send_checkin(p_phone text)
returns void language sql security definer as $$
  insert into checkins(senior_phone) values (p_phone);
$$;

create or replace function share_mood(p_phone text, p_emoji text, p_label text)
returns void language sql security definer as $$
  insert into moods(phone, emoji, label) values (p_phone, p_emoji, p_label);
$$;

-- what a caretaker's dashboard reads: their linked senior's latest check-in + mood
create or replace function get_senior_status(p_family_code text)
returns table(
  name text, phone text,
  last_checkin timestamptz,
  last_mood_emoji text, last_mood_label text, last_mood_time timestamptz
)
language sql security definer as $$
  select u.name, u.phone,
    (select max(c.created_at) from checkins c where c.senior_phone = u.phone),
    (select m.emoji from moods m where m.phone = u.phone order by m.created_at desc limit 1),
    (select m.label from moods m where m.phone = u.phone order by m.created_at desc limit 1),
    (select m.created_at from moods m where m.phone = u.phone order by m.created_at desc limit 1)
  from users u
  join families f on f.senior_phone = u.phone
  where f.code = p_family_code;
$$;

-- ---------- Let the app's public (anon) key call these ----------
grant execute on function register_senior(text,text,text)               to anon;
grant execute on function register_caretaker(text,text,text,text)       to anon;
grant execute on function login(text,text)                              to anon;
grant execute on function send_checkin(text)                            to anon;
grant execute on function share_mood(text,text,text)                    to anon;
grant execute on function get_senior_status(text)                       to anon;

-- ============================================================
-- MIGRATION 2 — multi-family binding ("Add Family Member")
-- Safe to paste and re-run even if you already ran the section above.
-- Lets a caretaker link to more than one senior (Mum, Dad, Grandma, ...)
-- by entering additional Family Codes after their account already exists.
-- ============================================================

-- optional friendly nickname for a linked family, e.g. "Dad"
alter table caretaker_links add column if not exists label text;

-- Link an ADDITIONAL senior's family to an existing caretaker account.
create or replace function link_additional_family(p_phone text, p_code text, p_label text default null)
returns table(family_code text, senior_name text)
language plpgsql security definer as $$
declare
  v_senior_phone text;
  v_senior_name text;
begin
  if not exists (select 1 from users u where u.phone = p_phone and u.role = 'caretaker') then
    raise exception 'NOT_A_CARETAKER';
  end if;
  select f.senior_phone into v_senior_phone from families f where f.code = p_code;
  if v_senior_phone is null then
    raise exception 'CODE_NOT_FOUND';
  end if;
  if v_senior_phone = p_phone then
    raise exception 'CANNOT_LINK_SELF';
  end if;
  if exists (select 1 from caretaker_links cl where cl.caretaker_phone = p_phone and cl.family_code = p_code) then
    raise exception 'ALREADY_LINKED';
  end if;
  insert into caretaker_links(caretaker_phone, family_code, label) values (p_phone, p_code, p_label);
  select u.name into v_senior_name from users u where u.phone = v_senior_phone;
  return query select p_code, v_senior_name;
end;
$$;

-- Everything a caretaker's dashboard needs: ALL linked seniors, each with
-- their latest check-in + mood. Replaces the old single-senior
-- get_senior_status for accounts with more than one linked family member.
create or replace function get_my_families(p_phone text)
returns table(
  family_code text, label text, senior_name text, senior_phone text,
  last_checkin timestamptz,
  last_mood_emoji text, last_mood_label text, last_mood_time timestamptz
)
language sql security definer as $$
  select cl.family_code, cl.label, u.name, u.phone,
    (select max(c.created_at) from checkins c where c.senior_phone = u.phone),
    (select m.emoji from moods m where m.phone = u.phone order by m.created_at desc limit 1),
    (select m.label from moods m where m.phone = u.phone order by m.created_at desc limit 1),
    (select m.created_at from moods m where m.phone = u.phone order by m.created_at desc limit 1)
  from caretaker_links cl
  join families f on f.code = cl.family_code
  join users u on u.phone = f.senior_phone
  where cl.caretaker_phone = p_phone
  order by cl.family_code;
$$;

-- What a SENIOR sees: the list of caretakers currently linked to their family code.
create or replace function get_my_caretakers(p_code text)
returns table(name text, phone text)
language sql security definer as $$
  select u.name, u.phone
  from caretaker_links cl
  join users u on u.phone = cl.caretaker_phone
  where cl.family_code = p_code
  order by u.name;
$$;

grant execute on function link_additional_family(text,text,text) to anon;
grant execute on function get_my_families(text)                  to anon;
grant execute on function get_my_caretakers(text)                to anon;

-- ============================================================
-- MIGRATION 3 — any role can link family; 7-day history
-- Safe to re-run.
-- ============================================================

-- Allow BOTH senior and caretaker to link additional family codes
create or replace function link_additional_family(p_phone text, p_code text, p_label text default null)
returns table(family_code text, senior_name text)
language plpgsql security definer as $$
declare
  v_senior_phone text;
  v_senior_name text;
begin
  if not exists (select 1 from users u where u.phone = p_phone) then
    raise exception 'USER_NOT_FOUND';
  end if;
  select f.senior_phone into v_senior_phone from families f where f.code = p_code;
  if v_senior_phone is null then
    raise exception 'CODE_NOT_FOUND';
  end if;
  if v_senior_phone = p_phone then
    raise exception 'CANNOT_LINK_SELF';
  end if;
  if exists (select 1 from caretaker_links cl where cl.caretaker_phone = p_phone and cl.family_code = p_code) then
    raise exception 'ALREADY_LINKED';
  end if;
  insert into caretaker_links(caretaker_phone, family_code, label) values (p_phone, p_code, p_label);
  select u.name into v_senior_name from users u where u.phone = v_senior_phone;
  return query select p_code, v_senior_name;
end;
$$;

-- Last 7 calendar days of check-ins + moods for one person
create or replace function get_week_history(p_phone text)
returns table(
  day date,
  checked_in boolean,
  mood_emoji text,
  mood_label text
)
language sql security definer as $$
  with days as (
    select (current_date - g.i)::date as day
    from generate_series(0, 6) as g(i)
  )
  select
    d.day,
    exists (
      select 1 from checkins c
      where c.senior_phone = p_phone
        and (c.created_at at time zone 'UTC')::date = d.day
    ) as checked_in,
    (
      select m.emoji from moods m
      where m.phone = p_phone
        and (m.created_at at time zone 'UTC')::date = d.day
      order by m.created_at desc limit 1
    ) as mood_emoji,
    (
      select m.label from moods m
      where m.phone = p_phone
        and (m.created_at at time zone 'UTC')::date = d.day
      order by m.created_at desc limit 1
    ) as mood_label
  from days d
  order by d.day asc;
$$;

grant execute on function link_additional_family(text,text,text) to anon;
grant execute on function get_week_history(text) to anon;
