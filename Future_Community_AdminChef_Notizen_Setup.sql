-- Future Community: private Admin-Chef-Notizen zu Benutzerkonten
-- Nur Profile mit is_admin_chef = true dürfen diese Tabelle lesen oder verändern.

create table if not exists public.admin_chef_user_notes (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  note text not null default '',
  updated_by uuid references public.profiles(id) on delete set null,
  updated_at timestamptz not null default now()
);

alter table public.admin_chef_user_notes enable row level security;

drop policy if exists "admin_chef_notes_select" on public.admin_chef_user_notes;
create policy "admin_chef_notes_select"
on public.admin_chef_user_notes
for select
to authenticated
using (
  exists (
    select 1
    from public.profiles p
    where p.id = auth.uid()
      and p.is_admin_chef = true
  )
);

drop policy if exists "admin_chef_notes_insert" on public.admin_chef_user_notes;
create policy "admin_chef_notes_insert"
on public.admin_chef_user_notes
for insert
to authenticated
with check (
  updated_by = auth.uid()
  and exists (
    select 1
    from public.profiles p
    where p.id = auth.uid()
      and p.is_admin_chef = true
  )
);

drop policy if exists "admin_chef_notes_update" on public.admin_chef_user_notes;
create policy "admin_chef_notes_update"
on public.admin_chef_user_notes
for update
to authenticated
using (
  exists (
    select 1
    from public.profiles p
    where p.id = auth.uid()
      and p.is_admin_chef = true
  )
)
with check (
  updated_by = auth.uid()
  and exists (
    select 1
    from public.profiles p
    where p.id = auth.uid()
      and p.is_admin_chef = true
  )
);

drop policy if exists "admin_chef_notes_delete" on public.admin_chef_user_notes;
create policy "admin_chef_notes_delete"
on public.admin_chef_user_notes
for delete
to authenticated
using (
  exists (
    select 1
    from public.profiles p
    where p.id = auth.uid()
      and p.is_admin_chef = true
  )
);

grant select, insert, update, delete
on public.admin_chef_user_notes
to authenticated;


-- Aktualisiert den Zeitstempel bei jeder Änderung automatisch.
create or replace function public.set_admin_chef_user_notes_updated_at()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists admin_chef_user_notes_updated_at
on public.admin_chef_user_notes;

create trigger admin_chef_user_notes_updated_at
before update on public.admin_chef_user_notes
for each row
execute function public.set_admin_chef_user_notes_updated_at();
