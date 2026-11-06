-- Future Community: @all-Erwähnung im öffentlichen Chat
-- Admins und Admin-Chef können @all verwenden. Alle anderen Mitglieder
-- erhalten eine klickbare Benachrichtigung zur betreffenden Chatnachricht.
-- Kann mehrfach ausgeführt werden.

-- Die Zusatzspalten werden bei Bedarf ebenfalls angelegt.
ALTER TABLE public.notifications
  ADD COLUMN IF NOT EXISTS actor_id uuid REFERENCES public.profiles(id) ON DELETE SET NULL;
ALTER TABLE public.notifications
  ADD COLUMN IF NOT EXISTS target_type text;
ALTER TABLE public.notifications
  ADD COLUMN IF NOT EXISTS target_id uuid;
CREATE INDEX IF NOT EXISTS notifications_user_created_at_idx
  ON public.notifications(user_id, created_at DESC);

CREATE OR REPLACE FUNCTION public.notify_all_mention(p_target_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_actor_name text;
  v_inserted integer := 0;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Bitte zuerst anmelden.';
  END IF;

  SELECT COALESCE(NULLIF(p.display_name, ''), NULLIF(p.username, ''), 'Ein Admin')
    INTO v_actor_name
    FROM public.profiles p
   WHERE p.id = v_uid
     AND (COALESCE(p.is_admin, false) = true OR COALESCE(p.is_admin_chef, false) = true);

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Nur Admins und der Admin-Chef dürfen @all verwenden.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
      FROM public.chat_messages cm
     WHERE cm.id = p_target_id
       AND cm.user_id = v_uid
       AND cm.content ~* '(^|[^[:alnum:]_])@all([^[:alnum:]_]|$)'
  ) THEN
    RAISE EXCEPTION 'Die Chatnachricht enthält keine gültige @all-Erwähnung.';
  END IF;

  INSERT INTO public.notifications (user_id, content, actor_id, target_type, target_id)
  SELECT p.id, v_actor_name || ' hat alle Mitglieder erwähnt.', v_uid, 'public_chat', p_target_id
    FROM public.profiles p
   WHERE p.id <> v_uid;

  GET DIAGNOSTICS v_inserted = ROW_COUNT;
  RETURN v_inserted;
END;
$$;

REVOKE ALL ON FUNCTION public.notify_all_mention(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.notify_all_mention(uuid) TO authenticated;
