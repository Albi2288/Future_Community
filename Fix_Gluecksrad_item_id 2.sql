-- Future Community: Fix für „column reference item_id is ambiguous"
-- Im Supabase SQL Editor ausführen. Behebt die Funktion für beide XP-Räder.
-- Die Rückgabespalten bleiben unverändert, damit die bestehende HTML-Datei passt.

CREATE OR REPLACE FUNCTION public.spin_profile_item_wheel(p_wheel_type text)
RETURNS TABLE(segment_index integer,item_id text,item_name text,item_rarity text,new_points integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_cost integer;
  v_item public.profile_item_catalog%ROWTYPE;
  v_points integer;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Bitte zuerst anmelden.';
  END IF;

  IF p_wheel_type = 'premium' THEN
    v_cost := 200;
  ELSIF p_wheel_type = 'legendary' THEN
    v_cost := 500;
  ELSE
    RAISE EXCEPTION 'Unbekannter Glücksrad-Typ.';
  END IF;

  SELECT p.points INTO v_points
    FROM public.profiles AS p
   WHERE p.id = v_uid
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Profil nicht gefunden.';
  END IF;

  SELECT c.* INTO v_item
    FROM public.profile_item_catalog AS c
   WHERE c.wheel_type = p_wheel_type
     AND NOT EXISTS (
       SELECT 1
         FROM public.user_profile_items AS ui
        WHERE ui.user_id = v_uid
          AND ui.item_id = c.id
     )
   ORDER BY random()
   LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Du besitzt bereits alle Gegenstände dieses Glücksrads.';
  END IF;

  UPDATE public.profiles AS p
     SET points = COALESCE(p.points, 0) - v_cost
   WHERE p.id = v_uid
     AND COALESCE(p.points, 0) >= v_cost
   RETURNING p.points INTO v_points;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Du hast nicht genügend XP. Benötigt: % XP.', v_cost;
  END IF;

  INSERT INTO public.user_profile_items(user_id,item_id)
  VALUES (v_uid,v_item.id)
  -- Absichtlich ohne Spaltenlisten-Conflict-Target, weil item_id oben
  -- zugleich als RETURNS-TABLE-Ausgabeparameter deklariert ist.
  ON CONFLICT DO NOTHING;

  RETURN QUERY
    SELECT (v_item.sort_order - 1)::integer,
           v_item.id,
           v_item.name,
           v_item.rarity,
           v_points;
END;
$$;

REVOKE ALL ON FUNCTION public.spin_profile_item_wheel(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.spin_profile_item_wheel(text) TO authenticated;
