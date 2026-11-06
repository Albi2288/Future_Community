-- Future Community: Supabase Storage fuer Bilder
-- Im Supabase SQL Editor als Projekt-Owner ausfuehren.
-- Erstellt einen oeffentlichen Bucket; Uploads und Loeschungen sind nur
-- fuer angemeldete Nutzer gemaess den untenstehenden Regeln erlaubt.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'future-community-images',
  'future-community-images',
  true,
  10485760,
  array['image/jpeg','image/png','image/webp','image/gif']
)
on conflict (id) do update
set public = excluded.public,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

-- Oeffentliche Anzeige der Bilder: Bei einem Public-Bucket koennen Besucher
-- die Bilddateien ueber die Public-URL ansehen.
-- Upload nur in den persoenlichen Ordner: <auth.uid()>/...
drop policy if exists "FC images upload own folder" on storage.objects;
create policy "FC images upload own folder"
on storage.objects for insert
to authenticated
with check (
  bucket_id = 'future-community-images'
  and (storage.foldername(name))[1] = auth.uid()::text
  and exists (
    select 1
    from public.profiles p
    where p.id = auth.uid()
      and p.is_viewer = false
      and p.is_banned = false
      and p.is_community_banned = false
  )
);

-- Nutzer duerfen eigene Dateien loeschen. Admins/Admin-Chef duerfen moderieren.
drop policy if exists "FC images delete own or admin" on storage.objects;
create policy "FC images delete own or admin"
on storage.objects for delete
to authenticated
using (
  bucket_id = 'future-community-images'
  and (
    (storage.foldername(name))[1] = auth.uid()::text
    or exists (
      select 1
      from public.profiles p
      where p.id = auth.uid()
        and (p.is_admin = true or p.is_admin_chef = true)
    )
  )
);
