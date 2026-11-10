-- =====================================================================
-- Future Community: Supabase-Bildspeicher + aktuelle Community-Funktionen
-- Bilder werden direkt in Supabase Storage gespeichert (kein DBByte-Upload).
-- News + Galerie zusammen: maximal 3 Bilder pro Mitglied; Admins ausgenommen.
-- Beiträge: unbegrenzt pro Tag, aber nur 1 Beitrag pro 60 Sekunden.
-- Casino: kein tägliches Verlustlimit; Einsatz min. 10 / max. 500 XP.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Supabase Storage für alle Community-Bilder
-- Bucket: future-community-images (öffentlich lesbare Bild-URLs)
-- Upload/Änderung/Löschung: nur angemeldete Nutzer im eigenen Benutzerordner.
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'future-community-images',
  'future-community-images',
  true,
  2097152,
  array['image/jpeg','image/png','image/webp']
)
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "Future Community image uploads own folder" on storage.objects;
create policy "Future Community image uploads own folder"
on storage.objects for insert to authenticated
with check (
  bucket_id = 'future-community-images'
  and (storage.foldername(name))[1] = auth.uid()::text
);

drop policy if exists "Future Community image updates own folder" on storage.objects;
create policy "Future Community image updates own folder"
on storage.objects for update to authenticated
using (
  bucket_id = 'future-community-images'
  and (storage.foldername(name))[1] = auth.uid()::text
)
with check (
  bucket_id = 'future-community-images'
  and (storage.foldername(name))[1] = auth.uid()::text
);

drop policy if exists "Future Community image deletes own folder" on storage.objects;
create policy "Future Community image deletes own folder"
on storage.objects for delete to authenticated
using (
  bucket_id = 'future-community-images'
  and (storage.foldername(name))[1] = auth.uid()::text
);

-- ---------------------------------------------------------------------
-- 3-Bilder-Limit für News und Galerie zusammen
-- ---------------------------------------------------------------------
-- Triggerfunktion zählt News-Bilder und Galerie-Bilder gemeinsam.
create or replace function public.enforce_community_image_limit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer := 0;
  v_is_admin boolean := false;
begin
  if new.image_url is null or new.image_url = '' then
    return new;
  end if;

  -- Ein bereits vorhandenes Bild desselben Datensatzes belegt keinen zusätzlichen Slot.
  if tg_op = 'UPDATE' and old.image_url is not null and old.user_id = new.user_id then
    return new;
  end if;

  perform pg_advisory_xact_lock(hashtextextended(new.user_id::text, 0));

  select coalesce(p.is_admin, false) or coalesce(p.is_admin_chef, false)
    into v_is_admin
  from public.profiles p
  where p.id = new.user_id;

  if coalesce(v_is_admin, false) then
    return new;
  end if;

  if tg_table_name = 'posts' then
    if tg_op = 'UPDATE' then
      select count(*) into v_count
      from public.posts p
      where p.user_id = new.user_id and p.image_url is not null and p.image_url <> '' and p.id <> new.id;
    else
      select count(*) into v_count
      from public.posts p
      where p.user_id = new.user_id and p.image_url is not null and p.image_url <> '';
    end if;

    v_count := v_count + (
      select count(*) from public.gallery g where g.user_id = new.user_id
    );
  elsif tg_table_name = 'gallery' then
    if tg_op = 'UPDATE' then
      select count(*) into v_count
      from public.gallery g
      where g.user_id = new.user_id and g.id <> new.id;
    else
      select count(*) into v_count
      from public.gallery g
      where g.user_id = new.user_id;
    end if;

    v_count := v_count + (
      select count(*) from public.posts p
      where p.user_id = new.user_id and p.image_url is not null and p.image_url <> ''
    );
  end if;

  if v_count >= 3 then
    raise exception using
      errcode = '23514',
      message = 'IMAGE_LIMIT_REACHED: Pro Mitglied sind insgesamt maximal 3 Bilder in News und Galerie erlaubt.';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_posts_community_image_limit on public.posts;
create trigger trg_posts_community_image_limit
before insert or update of image_url, user_id on public.posts
for each row execute function public.enforce_community_image_limit();

drop trigger if exists trg_gallery_community_image_limit on public.gallery;
create trigger trg_gallery_community_image_limit
before insert or update of image_url, user_id on public.gallery
for each row execute function public.enforce_community_image_limit();



-- =====================================================================
-- Future Community: neue Funktionen
--   1) Doppelte XP in den ersten 24 Stunden nach der Registrierung
--   2) Unbegrenzt viele Beiträge, aber maximal 1 pro Minute
--   3) Passwort zurücksetzen auf dem Erstellungsgerät (Datenbankteil)
--   4) Casino: Coin Flip, Roulette, Plinko, Mines
--
-- Im Supabase SQL-Editor ausführen. Das Skript ist mehrfach ausführbar.
-- Voraussetzung: guard_profile_update enthält schon die Ausnahme
-- "app.points_change_allowed" (aus der Glücksrad-Korrektur).
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1) Doppelte XP am ersten Tag
--    Die bestehende Multiplikator-Funktion bekommt einen Faktor 2 für
--    Konten, die jünger als 24 Stunden sind. Ein aktives 2x-Event wird
--    damit multipliziert (Event + erster Tag = 4x).
-- ---------------------------------------------------------------------
create or replace function public.community_current_xp_multiplier()
 returns integer
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  select (
    coalesce((
      select e.xp_multiplier
        from public.community_events e
       where e.is_active = true
         and e.event_type = 'xp_multiplier'
         and e.starts_at <= now()
         and e.ends_at > now()
       order by e.created_at desc
       limit 1
    ), 1)
    * case when exists (
        select 1 from public.profiles p
         where p.id = auth.uid()
           and p.created_at > now() - interval '24 hours'
      ) then 2 else 1 end
  )::integer;
$function$;


-- ---------------------------------------------------------------------
-- ---------------------------------------------------------------------
-- 2) Beitragslimit: unbegrenzt pro Tag, maximal ein Beitrag pro 60 Sekunden
--    Serverseitige Sperre; parallele Inserts werden pro Benutzer serialisiert.
-- ---------------------------------------------------------------------
drop trigger if exists limit_daily_posts_trigger on public.posts;
drop trigger if exists trg_posts_one_per_minute on public.posts;
drop function if exists public.limit_daily_posts();
drop function if exists public.my_post_quota();
drop table if exists public.post_daily_counts;

create or replace function public.enforce_post_one_per_minute()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare
  v_last_post timestamptz;
begin
  if new.user_id is null then
    raise exception 'Benutzer konnte nicht ermittelt werden.';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(new.user_id::text, 1));

  select p.created_at
    into v_last_post
  from public.posts p
  where p.user_id = new.user_id
    and p.created_at > now() - interval '60 seconds'
  order by p.created_at desc
  limit 1;

  if v_last_post is not null then
    raise exception using
      errcode = '23514',
      message = 'POST_COOLDOWN: Du kannst nur einen Beitrag pro Minute veröffentlichen.';
  end if;

  return new;
end
$function$;

create trigger trg_posts_one_per_minute
  before insert on public.posts
  for each row execute function public.enforce_post_one_per_minute();


-- 3) Passwort zurücksetzen (Datenbankteil)
--    Beim Anmelden auf dem Erstellungsgerät wird ein zufälliges Geheimnis
--    des Browsers hinterlegt (nur als SHA-256-Hash). Die Edge Function
--    "reset-password" prüft dieses Geheimnis. Die device_id allein reicht
--    NICHT, weil sie für andere Mitglieder lesbar sein kann.
-- ---------------------------------------------------------------------
create table if not exists public.password_reset_devices (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  secret_hash text not null,
  updated_at timestamptz not null default now()
);
alter table public.password_reset_devices enable row level security;
revoke all on public.password_reset_devices from anon, authenticated;

create or replace function public.register_password_reset_device(p_device_id text, p_secret text)
 returns boolean
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare
  v_uid uuid := auth.uid();
  v_dev text;
begin
  if v_uid is null then raise exception 'Bitte anmelden.'; end if;
  if p_secret is null or length(p_secret) < 32 then raise exception 'Ungültiges Geheimnis.'; end if;

  select p.device_id::text into v_dev from public.profiles p where p.id = v_uid;
  -- Nur das Gerät, das bei der Registrierung mit dem Konto verknüpft wurde
  if v_dev is null or v_dev is distinct from p_device_id then
    return false;
  end if;

  insert into public.password_reset_devices (user_id, secret_hash)
  values (v_uid, encode(sha256(convert_to(p_secret, 'UTF8')), 'hex'))
  on conflict (user_id) do update
    set secret_hash = excluded.secret_hash, updated_at = now();
  return true;
end
$function$;


-- ---------------------------------------------------------------------
-- 4) Casino
--    Alles läuft serverseitig. Die Tabelle casino_rounds ist für Clients
--    gesperrt, weil dort bei Mines die Minen-Positionen stehen.
-- ---------------------------------------------------------------------
create table if not exists public.casino_rounds (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  game text not null,
  bet integer not null check (bet > 0),
  payout integer not null default 0 check (payout >= 0),
  status text not null default 'open' check (status in ('open', 'done')),
  state jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  finished_at timestamptz
);
create index if not exists casino_rounds_user_idx on public.casino_rounds (user_id, created_at desc);
alter table public.casino_rounds enable row level security;
revoke all on public.casino_rounds from anon, authenticated;

-- Einstellungen: hier kannst du Einsatzgrenzen und Tageslimit ändern
create or replace function public.casino_cfg()
 returns jsonb
 language sql
 immutable
as $function$
  select '{"min_bet":10,"max_bet":500}'::jsonb;
$function$;

-- Interner Helfer: Einsatz prüfen, abbuchen, Runde anlegen
create or replace function public.casino_start_round(p_game text, p_bet integer, p_state jsonb default '{}'::jsonb)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare
  v_uid uuid := auth.uid();
  v_min integer := (public.casino_cfg() ->> 'min_bet')::integer;
  v_max integer := (public.casino_cfg() ->> 'max_bet')::integer;
  v_prof public.profiles%rowtype;
  v_round uuid;
  v_new integer;
begin
  if v_uid is null then raise exception 'Bitte anmelden.'; end if;
  if p_bet is null or p_bet < v_min or p_bet > v_max then
    raise exception 'Der Einsatz muss zwischen % und % XP liegen.', v_min, v_max;
  end if;

  select * into v_prof from public.profiles where id = v_uid for update;
  if not found then raise exception 'Profil nicht gefunden.'; end if;
  if coalesce(v_prof.is_banned, false) or coalesce(v_prof.is_viewer, false)
     or coalesce(v_prof.is_temp_viewer, false) or coalesce(v_prof.is_community_banned, false) then
    raise exception 'Im Zuschauermodus oder mit gesperrtem Konto kannst du nicht spielen.';
  end if;
  if coalesce(v_prof.points, 0) < p_bet then
    raise exception 'Du hast nicht genügend XP.';
  end if;

  perform set_config('app.points_change_allowed', 'on', true);
  update public.profiles p
     set points = coalesce(p.points, 0) - p_bet
   where p.id = v_uid and coalesce(p.points, 0) >= p_bet
   returning p.points into v_new;
  if not found then
    raise exception 'Der Einsatz konnte nicht abgebucht werden.';
  end if;
  perform set_config('app.points_change_allowed', 'off', true);
  if v_new is distinct from coalesce(v_prof.points, 0) - p_bet then
    raise exception 'Abbuchung wurde vom Schutzmechanismus blockiert. Es wurde nichts gespielt.';
  end if;

  insert into public.casino_rounds (user_id, game, bet, state)
  values (v_uid, p_game, p_bet, coalesce(p_state, '{}'::jsonb))
  returning id into v_round;

  return jsonb_build_object('round_id', v_round, 'points', v_new);
end
$function$;

-- Interner Helfer: Runde beenden und Auszahlung gutschreiben
create or replace function public.casino_finish_round(p_round uuid, p_payout integer)
 returns integer
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare
  v_uid uuid := auth.uid();
  v_old integer;
  v_new integer;
  v_status text;
begin
  select coalesce(p.points, 0) into v_old from public.profiles p where p.id = v_uid for update;
  select r.status into v_status from public.casino_rounds r
   where r.id = p_round and r.user_id = v_uid for update;
  if v_status is distinct from 'open' then
    raise exception 'Runde nicht gefunden oder bereits beendet.';
  end if;

  if p_payout > 0 then
    perform set_config('app.points_change_allowed', 'on', true);
    update public.profiles p
       set points = coalesce(p.points, 0) + p_payout
     where p.id = v_uid
     returning p.points into v_new;
    if not found then
      raise exception 'Der Gewinn konnte nicht gutgeschrieben werden.';
    end if;
    perform set_config('app.points_change_allowed', 'off', true);
    if v_new is distinct from v_old + p_payout then
      raise exception 'Gutschrift wurde vom Schutzmechanismus blockiert.';
    end if;
  else
    v_new := v_old;
  end if;

  update public.casino_rounds
     set payout = p_payout, status = 'done', finished_at = now()
   where id = p_round;
  return v_new;
end
$function$;

-- Mines: Multiplikator nach p_safe sicheren Feldern (Hausvorteil 3 %)
create or replace function public.casino_mines_multiplier(p_mines integer, p_safe integer)
 returns numeric
 language plpgsql
 immutable
as $function$
declare
  v numeric := 1;
  i integer;
begin
  for i in 0 .. p_safe - 1 loop
    v := v * (25 - i)::numeric / (25 - p_mines - i);
  end loop;
  return round(v * 0.97, 2);
end
$function$;

-- Coin Flip: 49 % Gewinnchance, Auszahlung 2x
create or replace function public.casino_coinflip(p_bet integer, p_choice text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare
  v_start jsonb;
  v_win boolean;
  v_result text;
  v_payout integer;
  v_points integer;
begin
  if p_choice not in ('heads', 'tails') then raise exception 'Ungültige Auswahl.'; end if;
  v_start := public.casino_start_round('coinflip', p_bet, jsonb_build_object('choice', p_choice));
  v_win := random() < 0.49;
  v_result := case when v_win then p_choice when p_choice = 'heads' then 'tails' else 'heads' end;
  v_payout := case when v_win then p_bet * 2 else 0 end;
  v_points := public.casino_finish_round((v_start ->> 'round_id')::uuid, v_payout);
  return jsonb_build_object('result', v_result, 'won', v_win, 'payout', v_payout, 'new_points', v_points);
end
$function$;

-- Roulette: europäisch (0-36)
create or replace function public.casino_roulette(p_bet integer, p_type text, p_value text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare
  v_red integer[] := array[1,3,5,7,9,12,14,16,18,19,21,23,25,27,30,32,34,36];
  v_num integer;
  v_color text;
  v_mult integer;
  v_win boolean;
  v_start jsonb;
  v_payout integer;
  v_points integer;
begin
  if p_type = 'color' and p_value in ('red', 'black') then v_mult := 2;
  elsif p_type = 'parity' and p_value in ('even', 'odd') then v_mult := 2;
  elsif p_type = 'half' and p_value in ('low', 'high') then v_mult := 2;
  elsif p_type = 'dozen' and p_value in ('1', '2', '3') then v_mult := 3;
  elsif p_type = 'number'
        and (case when p_value ~ '^[0-9]{1,2}$' then p_value::integer <= 36 else false end) then v_mult := 36;
  else
    raise exception 'Ungültige Roulette-Wette.';
  end if;

  v_start := public.casino_start_round('roulette', p_bet, jsonb_build_object('type', p_type, 'value', p_value));

  v_num := floor(random() * 37)::integer;
  v_color := case when v_num = 0 then 'green' when v_num = any(v_red) then 'red' else 'black' end;
  v_win := case p_type
    when 'color'  then v_num <> 0 and ((v_num = any(v_red)) = (p_value = 'red'))
    when 'parity' then v_num <> 0 and (v_num % 2 = case when p_value = 'even' then 0 else 1 end)
    when 'half'   then (p_value = 'low' and v_num between 1 and 18) or (p_value = 'high' and v_num between 19 and 36)
    when 'dozen'  then v_num between ((p_value::integer - 1) * 12 + 1) and (p_value::integer * 12)
    else v_num = p_value::integer
  end;
  v_payout := case when v_win then p_bet * v_mult else 0 end;
  v_points := public.casino_finish_round((v_start ->> 'round_id')::uuid, v_payout);

  return jsonb_build_object('number', v_num, 'color', v_color, 'won', v_win,
                            'payout', v_payout, 'new_points', v_points);
end
$function$;

-- Plinko: 8 Reihen, drei Risikostufen (Auszahlung ca. 94-96 %)
-- Wenn du die Multiplikatoren änderst, auch PLINKO_MULTS in der index.html anpassen.
create or replace function public.casino_plinko(p_bet integer, p_risk text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare
  v_mults numeric[];
  v_path integer[] := '{}';
  v_slot integer := 0;
  v_step integer;
  v_start jsonb;
  v_mult numeric;
  v_payout integer;
  v_points integer;
  i integer;
begin
  v_mults := case p_risk
    when 'low'    then array[5.6, 2, 1.1, 0.9, 0.5, 0.9, 1.1, 2, 5.6]
    when 'medium' then array[10, 3, 1.2, 0.7, 0.4, 0.7, 1.2, 3, 10]
    when 'high'   then array[25, 4, 1.5, 0.3, 0.2, 0.3, 1.5, 4, 25]
    else null
  end;
  if v_mults is null then raise exception 'Unbekannte Risikostufe.'; end if;

  v_start := public.casino_start_round('plinko', p_bet, jsonb_build_object('risk', p_risk));

  for i in 1 .. 8 loop
    v_step := case when random() < 0.5 then 0 else 1 end;
    v_path := v_path || v_step;
    v_slot := v_slot + v_step;
  end loop;

  v_mult := v_mults[v_slot + 1];
  v_payout := floor(p_bet * v_mult)::integer;
  v_points := public.casino_finish_round((v_start ->> 'round_id')::uuid, v_payout);

  return jsonb_build_object('path', to_jsonb(v_path), 'slot', v_slot, 'multiplier', v_mult,
                            'payout', v_payout, 'new_points', v_points);
end
$function$;

-- Mines: Runde starten
create or replace function public.casino_mines_start(p_bet integer, p_mines integer)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare
  v_uid uuid := auth.uid();
  v_mines integer[];
  v_start jsonb;
begin
  if v_uid is null then raise exception 'Bitte anmelden.'; end if;
  if p_mines is null or p_mines < 1 or p_mines > 20 then raise exception 'Ungültige Minenanzahl.'; end if;

  perform 1 from public.profiles where id = v_uid for update;
  perform 1 from public.casino_rounds where user_id = v_uid and game = 'mines' and status = 'open';
  if found then
    raise exception 'Du hast noch eine laufende Mines-Runde.';
  end if;

  select array_agg(g) into v_mines
    from (select g from generate_series(0, 24) g order by random() limit p_mines) s;

  v_start := public.casino_start_round('mines', p_bet,
    jsonb_build_object('mines', to_jsonb(v_mines), 'mine_count', p_mines, 'revealed', '[]'::jsonb));

  return jsonb_build_object('round_id', v_start ->> 'round_id',
                            'new_points', (v_start ->> 'points')::integer,
                            'mine_count', p_mines,
                            'next_multiplier', public.casino_mines_multiplier(p_mines, 1));
end
$function$;

-- Mines: Feld aufdecken
create or replace function public.casino_mines_reveal(p_round uuid, p_tile integer)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare
  v_uid uuid := auth.uid();
  v_round public.casino_rounds%rowtype;
  v_mines integer[];
  v_revealed integer[];
  v_count integer;
  v_safe integer;
  v_mult numeric;
  v_next numeric;
  v_payout integer;
  v_points integer;
begin
  if v_uid is null then raise exception 'Bitte anmelden.'; end if;
  if p_tile is null or p_tile < 0 or p_tile > 24 then raise exception 'Ungültiges Feld.'; end if;

  perform 1 from public.profiles where id = v_uid for update;
  select * into v_round from public.casino_rounds r
   where r.id = p_round and r.user_id = v_uid and r.game = 'mines' and r.status = 'open'
   for update;
  if not found then raise exception 'Keine laufende Mines-Runde gefunden.'; end if;

  v_mines := array(select (jsonb_array_elements_text(v_round.state -> 'mines'))::integer);
  v_revealed := array(select (jsonb_array_elements_text(v_round.state -> 'revealed'))::integer);
  v_count := (v_round.state ->> 'mine_count')::integer;

  if p_tile = any(v_revealed) then raise exception 'Dieses Feld ist bereits aufgedeckt.'; end if;

  if p_tile = any(v_mines) then
    update public.casino_rounds
       set status = 'done', payout = 0, finished_at = now(),
           state = state || jsonb_build_object('lost_tile', p_tile)
     where id = p_round;
    select coalesce(p.points, 0) into v_points from public.profiles p where p.id = v_uid;
    return jsonb_build_object('hit_mine', true, 'mines', to_jsonb(v_mines),
                              'revealed', to_jsonb(v_revealed), 'tile', p_tile,
                              'payout', 0, 'new_points', v_points);
  end if;

  v_revealed := v_revealed || p_tile;
  v_safe := cardinality(v_revealed);
  v_mult := public.casino_mines_multiplier(v_count, v_safe);
  update public.casino_rounds
     set state = jsonb_set(state, '{revealed}', to_jsonb(v_revealed))
   where id = p_round;

  -- Alle sicheren Felder gefunden: automatisch auszahlen
  if v_safe >= 25 - v_count then
    v_payout := floor(v_round.bet * v_mult)::integer;
    v_points := public.casino_finish_round(p_round, v_payout);
    return jsonb_build_object('hit_mine', false, 'cashed_out', true, 'tile', p_tile,
                              'revealed', to_jsonb(v_revealed), 'mines', to_jsonb(v_mines),
                              'multiplier', v_mult, 'payout', v_payout, 'new_points', v_points);
  end if;

  v_next := public.casino_mines_multiplier(v_count, v_safe + 1);
  return jsonb_build_object('hit_mine', false, 'cashed_out', false, 'tile', p_tile,
                            'revealed', to_jsonb(v_revealed), 'multiplier', v_mult,
                            'next_multiplier', v_next,
                            'potential_payout', floor(v_round.bet * v_mult)::integer);
end
$function$;

-- Mines: auszahlen
create or replace function public.casino_mines_cashout(p_round uuid)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare
  v_uid uuid := auth.uid();
  v_round public.casino_rounds%rowtype;
  v_mines integer[];
  v_revealed integer[];
  v_count integer;
  v_mult numeric;
  v_payout integer;
  v_points integer;
begin
  if v_uid is null then raise exception 'Bitte anmelden.'; end if;

  perform 1 from public.profiles where id = v_uid for update;
  select * into v_round from public.casino_rounds r
   where r.id = p_round and r.user_id = v_uid and r.game = 'mines' and r.status = 'open'
   for update;
  if not found then raise exception 'Keine laufende Mines-Runde gefunden.'; end if;

  v_mines := array(select (jsonb_array_elements_text(v_round.state -> 'mines'))::integer);
  v_revealed := array(select (jsonb_array_elements_text(v_round.state -> 'revealed'))::integer);
  v_count := (v_round.state ->> 'mine_count')::integer;
  if cardinality(v_revealed) < 1 then
    raise exception 'Decke mindestens ein Feld auf, bevor du auszahlst.';
  end if;

  v_mult := public.casino_mines_multiplier(v_count, cardinality(v_revealed));
  v_payout := floor(v_round.bet * v_mult)::integer;
  v_points := public.casino_finish_round(p_round, v_payout);

  return jsonb_build_object('payout', v_payout, 'multiplier', v_mult,
                            'mines', to_jsonb(v_mines), 'revealed', to_jsonb(v_revealed),
                            'new_points', v_points);
end
$function$;

-- Mines: laufende Runde wiederherstellen (ohne Minen-Positionen)
create or replace function public.casino_mines_active()
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare
  v_uid uuid := auth.uid();
  v_round public.casino_rounds%rowtype;
  v_revealed integer[];
  v_count integer;
  v_mult numeric;
begin
  if v_uid is null then raise exception 'Bitte anmelden.'; end if;
  select * into v_round from public.casino_rounds r
   where r.user_id = v_uid and r.game = 'mines' and r.status = 'open'
   order by r.created_at desc limit 1;
  if not found then return null; end if;

  v_revealed := array(select (jsonb_array_elements_text(v_round.state -> 'revealed'))::integer);
  v_count := (v_round.state ->> 'mine_count')::integer;
  v_mult := public.casino_mines_multiplier(v_count, cardinality(v_revealed));

  return jsonb_build_object(
    'round_id', v_round.id, 'bet', v_round.bet, 'mine_count', v_count,
    'revealed', to_jsonb(v_revealed), 'multiplier', v_mult,
    'next_multiplier', case when cardinality(v_revealed) < 25 - v_count
                            then public.casino_mines_multiplier(v_count, cardinality(v_revealed) + 1) end,
    'potential_payout', floor(v_round.bet * v_mult)::integer);
end
$function$;

-- Status für die Oberfläche: Einsatzgrenzen und letzte Spiele
create or replace function public.casino_status()
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Bitte anmelden.'; end if;

  return public.casino_cfg() || jsonb_build_object(
    'recent', coalesce((
      select jsonb_agg(to_jsonb(x))
        from (select r.game, r.bet, r.payout, r.created_at
                from public.casino_rounds r
               where r.user_id = v_uid and r.status = 'done'
               order by r.created_at desc limit 8) x
    ), '[]'::jsonb));
end
$function$;


-- ---------------------------------------------------------------------
-- Berechtigungen: Helfer sind intern, alles andere nur für Angemeldete
-- ---------------------------------------------------------------------
revoke execute on function
  public.casino_cfg(),
  public.casino_start_round(text, integer, jsonb),
  public.casino_finish_round(uuid, integer),
  public.casino_mines_multiplier(integer, integer)
  from public, anon, authenticated;

revoke execute on function
  public.casino_coinflip(integer, text),
  public.casino_roulette(integer, text, text),
  public.casino_plinko(integer, text),
  public.casino_mines_start(integer, integer),
  public.casino_mines_reveal(uuid, integer),
  public.casino_mines_cashout(uuid),
  public.casino_mines_active(),
  public.casino_status(),
  public.register_password_reset_device(text, text)
  from public, anon;

grant execute on function
  public.casino_coinflip(integer, text),
  public.casino_roulette(integer, text, text),
  public.casino_plinko(integer, text),
  public.casino_mines_start(integer, integer),
  public.casino_mines_reveal(uuid, integer),
  public.casino_mines_cashout(uuid),
  public.casino_mines_active(),
  public.casino_status(),
  public.register_password_reset_device(text, text)
  to authenticated;


-- ---------------------------------------------------------------------
-- Kontrolle: alle Zeilen müssen "true" zeigen
-- ---------------------------------------------------------------------
select proname,
       (prosrc like '%casino%' or prosrc like '%password_reset_devices%'
        or prosrc like '%24 hours%') as vorhanden
from pg_proc
where pronamespace = 'public'::regnamespace
  and proname in ('community_current_xp_multiplier','enforce_post_one_per_minute',
                  'register_password_reset_device','casino_start_round','casino_finish_round',
                  'casino_coinflip','casino_roulette','casino_plinko','casino_mines_start',
                  'casino_mines_reveal','casino_mines_cashout','casino_mines_active','casino_status')
order by proname;