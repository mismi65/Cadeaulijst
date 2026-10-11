-- =============================================================
--  Cadeaulijst – Supabase schema
--  Plak dit volledig in Supabase → SQL Editor → Run.
--
--  Dit script is HERHAALBAAR: bij een nieuwe versie van de app
--  draai je het gewoon opnieuw. Bestaande lijsten blijven staan.
--
--  Ontwerp:
--  * Geen accounts. Een lijst heeft een publieke 'slug' (deellink)
--    en een geheime 'edit_token' (beheerlink voor de jarige).
--  * Twee soorten wensen:
--      - 'gift'         : een cadeau dat één gever afstreept
--      - 'contribution' : een geldbijdrage (goed doel, wellness-
--                         weekend…) waar meerdere gevers een
--                         bedrag voor toezeggen
--  * De app regelt geen betalingen: gevers zeggen een bedrag toe
--    en betalen zelf via de link/IBAN die de jarige opgeeft.
--  * De tabellen zijn dicht (RLS aan, geen policies): de browser
--    praat ALLEEN via onderstaande functies. Zo lekt de beheer-
--    token nooit en ziet de jarige niet wat er is gekozen.
-- =============================================================

create extension if not exists pgcrypto;

-- ---------- Tabellen ----------
create table if not exists public.lists (
  id          uuid primary key default gen_random_uuid(),
  slug        text unique not null,
  edit_token  uuid not null default gen_random_uuid(),
  title       text not null check (char_length(title) between 1 and 120),
  owner_name  text not null check (char_length(owner_name) between 1 and 80),
  occasion    text check (char_length(occasion) <= 80),
  event_date  date,
  description text check (char_length(description) <= 1000),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create table if not exists public.items (
  id          uuid primary key default gen_random_uuid(),
  list_id     uuid not null references public.lists(id) on delete cascade,
  title       text not null check (char_length(title) between 1 and 160),
  note        text check (char_length(note) <= 500),
  url         text check (char_length(url) <= 1000),
  price       numeric(10,2) check (price is null or price >= 0),
  priority    smallint not null default 0 check (priority between 0 and 2), -- 0 normaal, 1 graag, 2 grootste wens
  position    integer not null default 0,
  created_at  timestamptz not null default now()
);
create index if not exists items_list_idx on public.items(list_id);

-- v2: soort wens + doelbedrag voor geldbijdragen
alter table public.items add column if not exists kind text not null default 'gift';
alter table public.items add column if not exists target_amount numeric(10,2);
do $$ begin
  alter table public.items add constraint items_kind_chk check (kind in ('gift', 'contribution'));
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.items add constraint items_target_chk check (target_amount is null or target_amount > 0);
exception when duplicate_object then null; end $$;

create table if not exists public.reservations (
  item_id        uuid primary key references public.items(id) on delete cascade,
  reserver_name  text check (char_length(reserver_name) <= 60),
  reserver_token uuid not null,
  created_at     timestamptz not null default now()
);

-- v2: toezeggingen voor geldbijdragen (één per gever per wens, aanpasbaar)
create table if not exists public.contributions (
  id               uuid primary key default gen_random_uuid(),
  item_id          uuid not null references public.items(id) on delete cascade,
  contributor_name text check (char_length(contributor_name) <= 60),
  amount           numeric(10,2) not null check (amount > 0 and amount <= 100000),
  reserver_token   uuid not null,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (item_id, reserver_token)
);
create index if not exists contributions_item_idx on public.contributions(item_id);

alter table public.lists         enable row level security;
alter table public.items         enable row level security;
alter table public.reservations  enable row level security;
alter table public.contributions enable row level security;
-- Bewust GEEN policies: directe tabeltoegang is voor anon geblokkeerd.

-- ---------- Hulpfuncties (intern) ----------
create or replace function public._new_slug() returns text
language plpgsql as $$
declare
  alphabet constant text := 'abcdefghjkmnpqrstuvwxyz23456789'; -- geen verwarrende tekens
  s text;
begin
  loop
    s := '';
    for i in 1..8 loop
      s := s || substr(alphabet, 1 + floor(random() * length(alphabet))::int, 1);
    end loop;
    exit when not exists (select 1 from public.lists where slug = s);
  end loop;
  return s;
end $$;

create or replace function public._owner_list_id(p_slug text, p_token uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select id from public.lists where slug = p_slug and edit_token = p_token
$$;

create or replace function public._clean_url(p_url text) returns text
language sql immutable as $$
  select case
    when p_url is null or btrim(p_url) = '' then null
    when btrim(p_url) ~* '^https?://' then btrim(p_url)
    else 'https://' || btrim(p_url)
  end
$$;

-- ---------- Lijst aanmaken ----------
create or replace function public.create_list(
  p_title text, p_owner_name text, p_occasion text default null,
  p_event_date date default null, p_description text default null
) returns json
language plpgsql security definer set search_path = public as $$
declare r public.lists;
begin
  insert into public.lists(slug, title, owner_name, occasion, event_date, description)
  values (public._new_slug(), btrim(p_title), btrim(p_owner_name),
          nullif(btrim(p_occasion), ''), p_event_date, nullif(btrim(p_description), ''))
  returning * into r;
  return json_build_object('slug', r.slug, 'edit_token', r.edit_token);
end $$;

-- ---------- Lijst bekijken als gever ----------
-- Toont per cadeau OF het is afgestreept, door wie, en of JIJ het was;
-- per geldbijdrage het opgehaalde totaal en wie wat toezegde.
-- Tokens zelf komen nooit terug.
create or replace function public.get_list_public(p_slug text, p_reserver_token uuid default null)
returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'slug', l.slug, 'title', l.title, 'owner_name', l.owner_name,
    'occasion', l.occasion, 'event_date', l.event_date, 'description', l.description,
    'items', coalesce((
      select json_agg(json_build_object(
        'id', i.id, 'kind', i.kind, 'title', i.title, 'note', i.note, 'url', i.url,
        'price', i.price, 'target_amount', i.target_amount, 'priority', i.priority,
        'reserved', r.item_id is not null,
        'reserver_name', r.reserver_name,
        'mine', r.item_id is not null and r.reserver_token = p_reserver_token,
        'raised', coalesce((select sum(c.amount) from public.contributions c where c.item_id = i.id), 0),
        'my_amount', (select c.amount from public.contributions c where c.item_id = i.id and c.reserver_token = p_reserver_token),
        'contributions', coalesce((
          select json_agg(json_build_object(
            'name', c.contributor_name, 'amount', c.amount,
            'mine', c.reserver_token = p_reserver_token) order by c.created_at)
          from public.contributions c where c.item_id = i.id
        ), '[]'::json)
      ) order by i.priority desc, i.position, i.created_at)
      from public.items i
      left join public.reservations r on r.item_id = i.id
      where i.list_id = l.id
    ), '[]'::json)
  )
  from public.lists l where l.slug = p_slug
$$;

-- ---------- Lijst bekijken als jarige ----------
-- Bevat bewust GEEN afstrepingen of bedragen: de verrassing blijft intact.
create or replace function public.get_list_owner(p_slug text, p_token uuid)
returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'slug', l.slug, 'title', l.title, 'owner_name', l.owner_name,
    'occasion', l.occasion, 'event_date', l.event_date, 'description', l.description,
    'items', coalesce((
      select json_agg(json_build_object(
        'id', i.id, 'kind', i.kind, 'title', i.title, 'note', i.note, 'url', i.url,
        'price', i.price, 'target_amount', i.target_amount,
        'priority', i.priority, 'position', i.position
      ) order by i.priority desc, i.position, i.created_at)
      from public.items i where i.list_id = l.id
    ), '[]'::json)
  )
  from public.lists l where l.slug = p_slug and l.edit_token = p_token
$$;

-- ---------- Lijst wijzigen / verwijderen (jarige) ----------
create or replace function public.update_list(
  p_slug text, p_token uuid, p_title text, p_owner_name text,
  p_occasion text default null, p_event_date date default null, p_description text default null
) returns boolean
language plpgsql security definer set search_path = public as $$
declare lid uuid := public._owner_list_id(p_slug, p_token);
begin
  if lid is null then raise exception 'Geen toegang' using errcode = '42501'; end if;
  update public.lists set
    title = btrim(p_title), owner_name = btrim(p_owner_name),
    occasion = nullif(btrim(p_occasion), ''), event_date = p_event_date,
    description = nullif(btrim(p_description), ''), updated_at = now()
  where id = lid;
  return true;
end $$;

create or replace function public.delete_list(p_slug text, p_token uuid) returns boolean
language plpgsql security definer set search_path = public as $$
declare lid uuid := public._owner_list_id(p_slug, p_token);
begin
  if lid is null then raise exception 'Geen toegang' using errcode = '42501'; end if;
  delete from public.lists where id = lid;
  return true;
end $$;

-- ---------- Wensen beheren (jarige) ----------
drop function if exists public.upsert_item(text, uuid, uuid, text, text, text, numeric, smallint); -- v1-versie

create or replace function public.upsert_item(
  p_slug text, p_token uuid, p_item_id uuid, p_title text,
  p_note text default null, p_url text default null,
  p_price numeric default null, p_priority smallint default 0,
  p_kind text default 'gift', p_target_amount numeric default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  lid uuid := public._owner_list_id(p_slug, p_token);
  iid uuid;
  k text := coalesce(p_kind, 'gift');
  old_kind text;
begin
  if lid is null then raise exception 'Geen toegang' using errcode = '42501'; end if;
  if k not in ('gift', 'contribution') then raise exception 'Onbekend soort wens'; end if;
  if p_item_id is null then
    insert into public.items(list_id, kind, title, note, url, price, target_amount, priority, position)
    values (lid, k, btrim(p_title), nullif(btrim(p_note), ''), public._clean_url(p_url),
            case when k = 'gift' then p_price end,
            case when k = 'contribution' then p_target_amount end,
            coalesce(p_priority, 0),
            coalesce((select max(position) + 1 from public.items where list_id = lid), 0))
    returning id into iid;
  else
    select kind into old_kind from public.items where id = p_item_id and list_id = lid;
    if old_kind is null then raise exception 'Wens niet gevonden'; end if;
    update public.items set
      kind = k, title = btrim(p_title), note = nullif(btrim(p_note), ''), url = public._clean_url(p_url),
      price = case when k = 'gift' then p_price end,
      target_amount = case when k = 'contribution' then p_target_amount end,
      priority = coalesce(p_priority, 0)
    where id = p_item_id
    returning id into iid;
    -- Soort gewijzigd? Dan horen oude afstrepingen/toezeggingen er niet meer bij.
    if old_kind <> k then
      delete from public.reservations  where item_id = iid;
      delete from public.contributions where item_id = iid;
    end if;
  end if;
  update public.lists set updated_at = now() where id = lid;
  return iid;
end $$;

create or replace function public.delete_item(p_slug text, p_token uuid, p_item_id uuid)
returns boolean
language plpgsql security definer set search_path = public as $$
declare lid uuid := public._owner_list_id(p_slug, p_token);
begin
  if lid is null then raise exception 'Geen toegang' using errcode = '42501'; end if;
  delete from public.items where id = p_item_id and list_id = lid;
  return found;
end $$;

-- ---------- Afstrepen (gevers, alleen cadeaus) ----------
-- Atomair: als iemand anders je net voor was, krijg je 'false' terug.
create or replace function public.reserve_item(
  p_item_id uuid, p_reserver_token uuid, p_reserver_name text default null
) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if p_reserver_token is null then raise exception 'Token ontbreekt'; end if;
  if not exists (select 1 from public.items where id = p_item_id and kind = 'gift') then
    return false;
  end if;
  insert into public.reservations(item_id, reserver_name, reserver_token)
  values (p_item_id, nullif(btrim(p_reserver_name), ''), p_reserver_token)
  on conflict (item_id) do nothing;
  return found;
end $$;

-- Alleen degene die het afstreepte (zelfde browser-token) kan het terugdraaien.
create or replace function public.unreserve_item(p_item_id uuid, p_reserver_token uuid)
returns boolean
language plpgsql security definer set search_path = public as $$
begin
  delete from public.reservations
  where item_id = p_item_id and reserver_token = p_reserver_token;
  return found;
end $$;

-- ---------- Bijdragen (gevers, alleen geldbijdragen) ----------
-- Nieuw of aanpassen: per browser één toezegging per wens.
create or replace function public.pledge_contribution(
  p_item_id uuid, p_reserver_token uuid, p_amount numeric, p_contributor_name text default null
) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if p_reserver_token is null then raise exception 'Token ontbreekt'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'Vul een bedrag in'; end if;
  if not exists (select 1 from public.items where id = p_item_id and kind = 'contribution') then
    return false;
  end if;
  insert into public.contributions(item_id, contributor_name, amount, reserver_token)
  values (p_item_id, nullif(btrim(p_contributor_name), ''), round(p_amount, 2), p_reserver_token)
  on conflict (item_id, reserver_token) do update
    set amount = excluded.amount, contributor_name = excluded.contributor_name, updated_at = now();
  return true;
end $$;

create or replace function public.withdraw_contribution(p_item_id uuid, p_reserver_token uuid)
returns boolean
language plpgsql security definer set search_path = public as $$
begin
  delete from public.contributions
  where item_id = p_item_id and reserver_token = p_reserver_token;
  return found;
end $$;

-- ---------- Rechten ----------
revoke all on public.lists, public.items, public.reservations, public.contributions from anon, authenticated;
revoke execute on all functions in schema public from public, anon, authenticated;

grant execute on function
  public.create_list(text, text, text, date, text),
  public.get_list_public(text, uuid),
  public.get_list_owner(text, uuid),
  public.update_list(text, uuid, text, text, text, date, text),
  public.delete_list(text, uuid),
  public.upsert_item(text, uuid, uuid, text, text, text, numeric, smallint, text, numeric),
  public.delete_item(text, uuid, uuid),
  public.reserve_item(uuid, uuid, text),
  public.unreserve_item(uuid, uuid),
  public.pledge_contribution(uuid, uuid, numeric, text),
  public.withdraw_contribution(uuid, uuid)
to anon, authenticated;
