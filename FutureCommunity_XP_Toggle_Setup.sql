-- Future Community: globaler XP-Schalter (1x / 2x)
-- Im Supabase SQL Editor einmal vollständig ausführen.
-- Der Status bleibt dauerhaft gespeichert, bis der Admin-Chef ihn wieder umstellt.

begin;

-- 1) Persistente globale Einstellung
create table if not exists public.community_xp_settings (
  singleton boolean primary key default true check (singleton is true),
  xp_multiplier integer not null default 1 check (xp_multiplier in (1, 2)),
  updated_by uuid null references public.profiles(id) on delete set null,
  updated_at timestamptz not null default now()
);

insert into public.community_xp_settings (singleton, xp_multiplier)
values (true, 1)
on conflict (singleton) do nothing;

alter table public.community_xp_settings enable row level security;
revoke all on table public.community_xp_settings from anon, authenticated;

-- 2) Lesefunktion für den Status im Frontend
create or replace function public.get_global_xp_multiplier()
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select s.xp_multiplier
       from public.community_xp_settings s
      where s.singleton = true),
    1
  );
$$;

revoke all on function public.get_global_xp_multiplier() from public, anon;
grant execute on function public.get_global_xp_multiplier() to authenticated;

-- 3) Nur der Admin-Chef darf zwischen 1x und 2x umschalten
create or replace function public.chef_set_global_xp_multiplier(p_multiplier integer)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_result integer;
begin
  if v_uid is null then
    raise exception 'Bitte zuerst anmelden.';
  end if;

  if p_multiplier not in (1, 2) then
    raise exception 'Erlaubt sind nur 1 oder 2.';
  end if;

  if not exists (
    select 1
      from public.profiles p
     where p.id = v_uid
       and coalesce(p.is_admin_chef, false) = true
  ) then
    raise exception 'Nur der Admin-Chef darf den globalen XP-Multiplikator ändern.';
  end if;

  insert into public.community_xp_settings
    (singleton, xp_multiplier, updated_by, updated_at)
  values
    (true, p_multiplier, v_uid, now())
  on conflict (singleton) do update
    set xp_multiplier = excluded.xp_multiplier,
        updated_by = excluded.updated_by,
        updated_at = now()
  returning xp_multiplier into v_result;

  return v_result;
end;
$$;

revoke all on function public.chef_set_global_xp_multiplier(integer) from public, anon;
grant execute on function public.chef_set_global_xp_multiplier(integer) to authenticated;

-- 4) Einheitliche XP-Vergabe für Posts, Kommentare, öffentliche und private Nachrichten
create or replace function public.award_activity_points()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  target_user uuid;
  points_to_add integer;
  v_multiplier integer := 1;
begin
  if tg_table_name = 'posts' then
    target_user := new.user_id;
    points_to_add := 10;
  elsif tg_table_name = 'comments' then
    target_user := new.user_id;
    points_to_add := 2;
  elsif tg_table_name = 'public_messages' then
    target_user := new.user_id;
    points_to_add := 1;
  elsif tg_table_name = 'messages' then
    target_user := new.sender_id;
    points_to_add := 1;
  else
    return new;
  end if;

  select coalesce(s.xp_multiplier, 1)
    into v_multiplier
    from public.community_xp_settings s
   where s.singleton = true;

  update public.profiles
     set points = coalesce(points, 0) + (points_to_add * coalesce(v_multiplier, 1))
   where id = target_user;

  return new;
end;
$function$;

-- Chat-Nachrichten verwenden separat award_points('1').
create or replace function public.award_points()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_multiplier integer := 1;
  v_base_points integer;
begin
  v_base_points := tg_argv[0]::integer;

  select coalesce(s.xp_multiplier, 1)
    into v_multiplier
    from public.community_xp_settings s
   where s.singleton = true;

  update public.profiles
     set points = coalesce(points, 0) + (v_base_points * coalesce(v_multiplier, 1))
   where id = new.user_id;

  return new;
end;
$function$;

-- 5) Doppelte Trigger beseitigen: Posts und Kommentare erhalten nur noch
--    award_activity_points(), das den globalen Multiplikator berücksichtigt.
drop trigger if exists fc_points_posts on public.posts;
drop trigger if exists fc_points_comments on public.comments;

-- 6) Tägliches Glücksrad: XP-Gewinne werden ebenfalls mit 1x/2x multipliziert.
create or replace function public.spin_daily_wheel()
returns jsonb
language plpgsql
security definer
set search_path = 'public', 'auth'
as $function$
declare
  v_uid uuid := auth.uid();
  v_day date := (now() at time zone 'Europe/Berlin')::date;
  v_count integer;
  v_last text;
  v_idx integer;
  v_label text;
  v_base_points integer := 0;
  v_points integer := 0;
  v_multiplier integer := 1;
begin
  if v_uid is null then
    raise exception 'Bitte anmelden.';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(v_uid::text || v_day::text, 0));

  select count(*), (array_agg(reward_label order by created_at desc))[1]
    into v_count, v_last
    from public.daily_wheel_spins
   where user_id = v_uid and spin_date = v_day;

  if not (v_count = 0 or (v_count = 1 and v_last = 'Extra-Dreh')) then
    raise exception 'Du hast heute bereits alle verfügbaren Drehungen genutzt.';
  end if;

  v_idx := floor(random() * 6)::integer;
  v_label := case v_idx
    when 0 then '10 XP'
    when 1 then '25 XP'
    when 2 then '50 XP'
    when 3 then '100 XP'
    when 4 then 'Extra-Dreh'
    else '25 XP'
  end;

  v_base_points := case v_idx
    when 0 then 10
    when 1 then 25
    when 2 then 50
    when 3 then 100
    when 5 then 25
    else 0
  end;

  select coalesce(s.xp_multiplier, 1)
    into v_multiplier
    from public.community_xp_settings s
   where s.singleton = true;

  v_points := v_base_points * coalesce(v_multiplier, 1);

  if v_points > 0 then
    update public.profiles
       set points = coalesce(points, 0) + v_points
     where id = v_uid;
    if not found then
      raise exception 'Profil nicht gefunden.';
    end if;
  end if;

  insert into public.daily_wheel_spins(user_id, spin_date, segment_index, reward_label)
  values (v_uid, v_day, v_idx, v_label);

  return jsonb_build_object(
    'segment_index', v_idx,
    'reward_label', v_label,
    'points_awarded', v_points,
    'base_points_awarded', v_base_points,
    'xp_multiplier', coalesce(v_multiplier, 1)
  );
end;
$function$;

-- 7) Erste Stimme in einer Umfrage: +5 XP, bei aktivem Schalter +10 XP.
create or replace function public.vote_on_post_poll(p_poll_id uuid, p_option_index integer)
returns jsonb
language plpgsql
security definer
set search_path = 'public', 'pg_temp'
as $function$
declare
  v_uid uuid := auth.uid();
  v_options jsonb;
  v_count integer;
  v_awarded boolean := false;
  v_points integer;
  v_is_viewer boolean;
  v_is_temp_viewer boolean;
  v_multiplier integer := 1;
  v_xp_award integer := 0;
begin
  if v_uid is null then
    raise exception 'Bitte zuerst anmelden.';
  end if;

  select coalesce(p.is_viewer,false),
         coalesce(p.is_temp_viewer,false),
         coalesce(p.points,0)
    into v_is_viewer, v_is_temp_viewer, v_points
    from public.profiles p
   where p.id = v_uid
   for update;

  if not found then
    raise exception 'Profil nicht gefunden.';
  end if;

  if v_is_viewer or v_is_temp_viewer then
    raise exception 'Im Zuschauermodus kannst du nicht abstimmen.';
  end if;

  select pp.options into v_options
    from public.post_polls pp
   where pp.id = p_poll_id;

  if not found then
    raise exception 'Diese Umfrage existiert nicht mehr.';
  end if;

  if p_option_index is null
     or p_option_index < 0
     or p_option_index >= jsonb_array_length(v_options) then
    raise exception 'Ungültige Antwortmöglichkeit.';
  end if;

  if not exists (
    select 1
      from public.post_poll_votes pv
     where pv.poll_id = p_poll_id
       and pv.user_id = v_uid
  ) then
    v_awarded := true;

    select coalesce(s.xp_multiplier, 1)
      into v_multiplier
      from public.community_xp_settings s
     where s.singleton = true;

    v_xp_award := 5 * coalesce(v_multiplier, 1);

    update public.profiles
       set points = coalesce(points,0) + v_xp_award
     where id = v_uid
     returning points into v_points;
  end if;

  insert into public.post_poll_votes(poll_id,user_id,option_index)
  values (p_poll_id,v_uid,p_option_index)
  on conflict (poll_id,user_id)
  do update set option_index = excluded.option_index, created_at = now();

  select count(*)::integer
    into v_count
    from public.post_poll_votes pv
   where pv.poll_id = p_poll_id;

  return jsonb_build_object(
    'vote_count', v_count,
    'awarded_xp', v_awarded,
    'xp_award', v_xp_award,
    'new_points', v_points,
    'xp_multiplier', coalesce(v_multiplier, 1)
  );
end;
$function$;

commit;
