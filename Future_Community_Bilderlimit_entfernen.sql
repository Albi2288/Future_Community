-- Future Community: Kontobezogenes Bilderlimit vollständig entfernen
-- Entfernt ausschließlich das gemeinsame 3-Bilder-Limit für News und Galerie.
-- Storage-Bucket, Upload-Berechtigungen und Bildkomprimierung bleiben erhalten.

begin;

-- Die beiden Trigger verhindern bisher weitere Bild-Uploads ab dem Limit.
drop trigger if exists trg_posts_community_image_limit on public.posts;
drop trigger if exists trg_gallery_community_image_limit on public.gallery;

-- Die Triggerfunktion wird nach dem Entfernen der Trigger nicht mehr benötigt.
drop function if exists public.enforce_community_image_limit();

commit;

-- Hinweis:
-- Das Upload-Limit pro Datei im Supabase-Storage-Bucket (z. B. 2 MB) bleibt bestehen.
-- Es ist kein Kontolimit, sondern eine technische Maximalgröße pro einzelner Datei.
-- Die Website komprimiert News- und Galerie-Bilder weiterhin automatisch auf ungefähr 100 KB.
