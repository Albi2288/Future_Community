-- Future Community: max. 2 Accounts pro Browser-Kennung + einzelne Kommentar-Loeschung
-- Im Supabase SQL Editor als Projekt-Administrator ausfuehren.

-- 1) Browser-Geraetekennung am Profil speichern.
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS device_id text;

-- 2) Direkte Manipulation der Geraetezuordnung durch normale Clients verhindern.
CREATE OR REPLACE FUNCTION public.guard_profile_device_id()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  linked_count integer;
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.device_id IS NOT NULL THEN
      RAISE EXCEPTION 'device_id darf nur ueber claim_device_account gesetzt werden';
    END IF;
    RETURN NEW;
  END IF;

  IF OLD.device_id IS NOT NULL AND NEW.device_id IS DISTINCT FROM OLD.device_id THEN
    RAISE EXCEPTION 'Eine bestehende Geraetezuordnung kann nicht geaendert werden';
  END IF;

  IF NEW.device_id IS NOT NULL AND NEW.device_id IS DISTINCT FROM OLD.device_id THEN
    IF current_setting('app.claiming_device_account', true) IS DISTINCT FROM 'on' THEN
      RAISE EXCEPTION 'device_id darf nur ueber claim_device_account gesetzt werden';
    END IF;
    SELECT count(*) INTO linked_count
      FROM public.profiles
      WHERE device_id = NEW.device_id AND id <> NEW.id;
    IF linked_count >= 2 THEN
      RAISE EXCEPTION 'Mit diesem Browser sind bereits zwei Accounts verknuepft';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS profiles_guard_device_id ON public.profiles;
CREATE TRIGGER profiles_guard_device_id
BEFORE INSERT OR UPDATE OF device_id ON public.profiles
FOR EACH ROW EXECUTE FUNCTION public.guard_profile_device_id();

-- 3) Atomare Registrierung der Kennung am aktuell angemeldeten Account.
CREATE OR REPLACE FUNCTION public.claim_device_account(p_device_id text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  current_device text;
  linked_count integer;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Anmeldung erforderlich';
  END IF;
  IF p_device_id IS NULL OR length(p_device_id) < 16 OR length(p_device_id) > 100 THEN
    RAISE EXCEPTION 'Ungueltige Browser-Geraetekennung';
  END IF;

  -- Sperrt parallele Registrierungen mit derselben Kennung, damit die Grenze
  -- auch bei gleichzeitigem Registrieren nicht ueberschritten wird.
  PERFORM pg_advisory_xact_lock(hashtext(p_device_id));

  SELECT device_id INTO current_device
    FROM public.profiles
    WHERE id = auth.uid()
    FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Profil wurde nicht gefunden';
  END IF;

  -- Ein bereits zugeordnetes Konto darf sich auch von einem anderen Geraet anmelden.
  IF current_device IS NOT NULL THEN
    RETURN jsonb_build_object('success', true, 'already_linked', true);
  END IF;

  SELECT count(*) INTO linked_count
    FROM public.profiles
    WHERE device_id = p_device_id;
  IF linked_count >= 2 THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Mit diesem Browser sind bereits zwei Accounts verknuepft.'
    );
  END IF;

  PERFORM set_config('app.claiming_device_account', 'on', true);
  UPDATE public.profiles SET device_id = p_device_id WHERE id = auth.uid();
  RETURN jsonb_build_object('success', true, 'already_linked', false);
END;
$$;

REVOKE ALL ON FUNCTION public.claim_device_account(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.claim_device_account(text) TO authenticated;

-- 4) Nur der Admin-Chef darf die Zuordnungen samt Usernames ansehen.
CREATE OR REPLACE FUNCTION public.admin_list_device_accounts()
RETURNS TABLE(device_id text, account_count bigint, usernames text[])
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = auth.uid() AND is_admin_chef = true
  ) THEN
    RAISE EXCEPTION 'Nur der Admin-Chef darf Geraetezuordnungen einsehen';
  END IF;

  RETURN QUERY
  SELECT p.device_id, count(*)::bigint, array_agg(p.username ORDER BY p.username)
  FROM public.profiles p
  WHERE p.device_id IS NOT NULL
  GROUP BY p.device_id
  ORDER BY count(*) DESC, p.device_id;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_list_device_accounts() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_list_device_accounts() TO authenticated;

-- 5) Einzelne Kommentare duerfen vom Verfasser oder von Admins geloescht werden.
DROP POLICY IF EXISTS comments_delete_own_or_admin ON public.comments;
CREATE POLICY comments_delete_own_or_admin
ON public.comments
FOR DELETE
TO authenticated
USING (
  auth.uid() = user_id
  OR EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.id = auth.uid()
      AND (p.is_admin = true OR p.is_admin_chef = true)
  )
);
