-- Future Community: Dislikes, Namensfarben und angepinnte Beiträge
-- Dieses Setup ergänzt die bestehende Datenbank. Bestehende Inhalte bleiben erhalten.

-- 1) Dislikes
create table if not exists public.dislikes (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.posts(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  constraint dislikes_one_per_user unique (post_id, user_id)
);
alter table public.dislikes enable row level security;
drop policy if exists "dislikes_read_authenticated" on public.dislikes;
create policy "dislikes_read_authenticated" on public.dislikes for select to authenticated using (true);
drop policy if exists "dislikes_insert_own" on public.dislikes;
create policy "dislikes_insert_own" on public.dislikes for insert to authenticated
with check (user_id = auth.uid() and exists (select 1 from public.profiles p where p.id=auth.uid() and p.is_viewer=false and p.is_banned=false));
drop policy if exists "dislikes_delete_own" on public.dislikes;
create policy "dislikes_delete_own" on public.dislikes for delete to authenticated using (user_id=auth.uid());
grant select, insert, delete on public.dislikes to authenticated;

-- 2) Namensfarben und Pin-Felder
alter table public.profiles add column if not exists name_color text;
alter table public.profiles add column if not exists name_color_unlocked boolean not null default false;
alter table public.posts add column if not exists pinned_at timestamptz;
alter table public.posts add column if not exists pinned_by uuid references public.profiles(id) on delete set null;

-- Erlaubte Farben werden serverseitig geprüft, damit keine beliebigen CSS-Werte gespeichert werden.
create or replace function public.buy_profile_name_color(p_color text)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare v_points integer; v_unlocked boolean;
begin
  if p_color not in ('#00d9ff','#ff42bd','#a78bfa','#42e6a4','#ffb020','#ff6b6b','#ffffff') then
    raise exception 'Ungültige Namensfarbe.';
  end if;
  if auth.uid() is null then raise exception 'Nicht angemeldet.'; end if;
  select points,name_color_unlocked into v_points,v_unlocked from public.profiles where id=auth.uid() for update;
  if not found then raise exception 'Profil nicht gefunden.'; end if;
  if not v_unlocked and v_points < 150 then raise exception 'Du brauchst mindestens 150 XP.'; end if;
  update public.profiles set
    points=case when v_unlocked then points else points-150 end,
    name_color=p_color,
    name_color_unlocked=true
  where id=auth.uid();
end; $$;

create or replace function public.chef_set_profile_name_color(p_user_id uuid,p_color text)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if auth.uid() is null or not exists(select 1 from public.profiles where id=auth.uid() and is_admin_chef=true) then
    raise exception 'Nur der Admin-Chef darf Namensfarben ändern.';
  end if;
  if p_color not in ('#00d9ff','#ff42bd','#a78bfa','#42e6a4','#ffb020','#ff6b6b','#ffffff') then
    raise exception 'Ungültige Namensfarbe.';
  end if;
  update public.profiles set name_color=p_color where id=p_user_id;
  if not found then raise exception 'Benutzer nicht gefunden.'; end if;
end; $$;

create or replace function public.chef_set_post_pinned(p_post_id uuid,p_pinned boolean)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if auth.uid() is null or not exists(select 1 from public.profiles where id=auth.uid() and is_admin_chef=true) then
    raise exception 'Nur der Admin-Chef darf Beiträge pinnen.';
  end if;
  update public.posts set pinned_at=case when p_pinned then now() else null end,
    pinned_by=case when p_pinned then auth.uid() else null end
  where id=p_post_id;
  if not found then raise exception 'Beitrag nicht gefunden.'; end if;
end; $$;

revoke all on function public.buy_profile_name_color(text) from public;
revoke all on function public.chef_set_profile_name_color(uuid,text) from public;
revoke all on function public.chef_set_post_pinned(uuid,boolean) from public;
grant execute on function public.buy_profile_name_color(text) to authenticated;
grant execute on function public.chef_set_profile_name_color(uuid,text) to authenticated;
grant execute on function public.chef_set_post_pinned(uuid,boolean) to authenticated;
