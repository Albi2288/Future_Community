-- Future Community: blaue Verifizierungs-Haken und Admin-Chef-Namensverwaltung
-- Einmal im Supabase SQL Editor ausführen.

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS is_verified boolean NOT NULL DEFAULT false;

-- Admins und Admin-Chef dürfen Verifizierungs-Haken vergeben oder entfernen.
CREATE OR REPLACE FUNCTION public.admin_set_verified(
  p_user_id uuid,
  p_verified boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_is_admin boolean;
  v_is_admin_chef boolean;
BEGIN
  SELECT COALESCE(is_admin, false), COALESCE(is_admin_chef, false)
    INTO v_is_admin, v_is_admin_chef
  FROM public.profiles
  WHERE id = auth.uid();

  IF NOT FOUND OR NOT (v_is_admin OR v_is_admin_chef) THEN
    RAISE EXCEPTION 'Nur Administratoren dürfen Verifizierungen verwalten.';
  END IF;

  UPDATE public.profiles
     SET is_verified = COALESCE(p_verified, false)
   WHERE id = p_user_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Account nicht gefunden.';
  END IF;

  RETURN jsonb_build_object('success', true, 'is_verified', COALESCE(p_verified, false));
END;
$$;

-- Ausschließlich der Admin-Chef darf die öffentlichen Anzeigenamen ändern.
-- Der Login-Benutzername (username) wird absichtlich nicht verändert.
CREATE OR REPLACE FUNCTION public.chef_set_display_name(
  p_user_id uuid,
  p_display_name text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_is_admin_chef boolean;
  v_name text;
BEGIN
  SELECT COALESCE(is_admin_chef, false)
    INTO v_is_admin_chef
  FROM public.profiles
  WHERE id = auth.uid();

  IF NOT FOUND OR NOT v_is_admin_chef THEN
    RAISE EXCEPTION 'Nur der Admin-Chef darf Anzeigenamen ändern.';
  END IF;

  v_name := btrim(COALESCE(p_display_name, ''));
  IF v_name = '' THEN
    RAISE EXCEPTION 'Der Anzeigename darf nicht leer sein.';
  END IF;
  IF char_length(v_name) > 40 THEN
    RAISE EXCEPTION 'Der Anzeigename darf maximal 40 Zeichen lang sein.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.profiles p
    WHERE p.id <> p_user_id
      AND lower(btrim(COALESCE(p.display_name, ''))) = lower(v_name)
  ) THEN
    RAISE EXCEPTION 'Dieser Anzeigename ist bereits vergeben.';
  END IF;

  UPDATE public.profiles
     SET display_name = v_name
   WHERE id = p_user_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Account nicht gefunden.';
  END IF;

  RETURN jsonb_build_object('success', true, 'display_name', v_name);
END;
$$;

REVOKE ALL ON FUNCTION public.admin_set_verified(uuid, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.chef_set_display_name(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_set_verified(uuid, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.chef_set_display_name(uuid, text) TO authenticated;
