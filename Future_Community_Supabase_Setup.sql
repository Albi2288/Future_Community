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


-- ============================================================
-- Future Community: Profilgegenstände und zwei XP-Glücksräder
-- Idempotent erweiterbar: vorhandene Profile/XP bleiben erhalten.
-- XP-Quelle ist ausdrücklich public.profiles.points.
-- ============================================================

CREATE TABLE IF NOT EXISTS public.profile_item_catalog (
  id text PRIMARY KEY,
  name text NOT NULL,
  description text NOT NULL DEFAULT '',
  kind text NOT NULL CHECK (kind IN ('frame','badge','effect')),
  rarity text NOT NULL DEFAULT 'Besonders',
  wheel_type text NOT NULL CHECK (wheel_type IN ('premium','legendary')),
  icon text NOT NULL DEFAULT '✦',
  sort_order integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO public.profile_item_catalog
  (id,name,description,kind,rarity,wheel_type,icon,sort_order)
VALUES
  ('premium_neon_frame','Neon-Rahmen','Ein leuchtender türkis-violetter Rahmen für dein Profil.','frame','Besonders','premium','🟦',1),
  ('premium_cyber_badge','Cyber-Badge','Ein futuristisches Cyber-Abzeichen.','badge','Besonders','premium','🤖',2),
  ('premium_glitch_effect','Glitch-Effekt','Ein digitaler Glitch-Effekt für dein Profil.','effect','Besonders','premium','⚡',3),
  ('premium_crystal_frame','Kristall-Rahmen','Ein schimmernder Rahmen mit Kristalloptik.','frame','Besonders','premium','💠',4),
  ('premium_nova_badge','Nova-Badge','Ein strahlendes Nova-Abzeichen.','badge','Besonders','premium','🌟',5),
  ('premium_pulse_effect','Pulse-Effekt','Ein pulsierender Lichtakzent.','effect','Besonders','premium','💫',6),
  ('legendary_phantom_frame','Phantom-Rahmen','Ein geheimnisvoller, besonders seltener Profilrahmen.','frame','Legendär','legendary','👻',1),
  ('legendary_gold_crown','Goldkrone-Badge','Ein exklusives goldenes Kronen-Abzeichen.','badge','Legendär','legendary','👑',2),
  ('legendary_singularity_effect','Singularity-Effekt','Ein kosmischer Effekt rund um dein Profil.','effect','Legendär','legendary','🪐',3),
  ('legendary_void_frame','Void-Rahmen','Ein seltener Rahmen aus der Void-Serie.','frame','Legendär','legendary','🌌',4),
  ('legendary_galaxy_badge','Galaxy-Badge','Ein legendäres Galaxie-Abzeichen.','badge','Legendär','legendary','🌠',5),
  ('legendary_mythic_effect','Mythic-Effekt','Ein mythischer Effekt für dein Profil.','effect','Legendär','legendary','🔮',6)
ON CONFLICT (id) DO UPDATE SET
  name=EXCLUDED.name,
  description=EXCLUDED.description,
  kind=EXCLUDED.kind,
  rarity=EXCLUDED.rarity,
  wheel_type=EXCLUDED.wheel_type,
  icon=EXCLUDED.icon,
  sort_order=EXCLUDED.sort_order;

CREATE TABLE IF NOT EXISTS public.user_profile_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  item_id text NOT NULL REFERENCES public.profile_item_catalog(id) ON DELETE CASCADE,
  is_equipped boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(user_id,item_id)
);

CREATE INDEX IF NOT EXISTS user_profile_items_user_idx
  ON public.user_profile_items(user_id);
CREATE INDEX IF NOT EXISTS user_profile_items_equipped_idx
  ON public.user_profile_items(user_id,is_equipped);

ALTER TABLE public.profile_item_catalog ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_profile_items ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS profile_item_catalog_authenticated_read ON public.profile_item_catalog;
CREATE POLICY profile_item_catalog_authenticated_read
  ON public.profile_item_catalog FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS user_profile_items_authenticated_read ON public.user_profile_items;
CREATE POLICY user_profile_items_authenticated_read
  ON public.user_profile_items FOR SELECT TO authenticated USING (true);

REVOKE INSERT, UPDATE, DELETE ON public.profile_item_catalog FROM anon, authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.user_profile_items FROM anon, authenticated;
GRANT SELECT ON public.profile_item_catalog TO authenticated;
GRANT SELECT ON public.user_profile_items TO authenticated;

-- Sicherer Dreh: Kostenabzug, Auswahl eines noch nicht besessenen Gegenstands
-- und Inventar-Eintrag erfolgen in einer einzigen Datenbanktransaktion.
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

  -- Profil sperren, damit parallele Drehungen keine XP doppelt ausgeben.
  SELECT points INTO v_points
    FROM public.profiles
   WHERE id = v_uid
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Profil nicht gefunden.';
  END IF;

  SELECT c.* INTO v_item
    FROM public.profile_item_catalog c
   WHERE c.wheel_type = p_wheel_type
     AND NOT EXISTS (
       SELECT 1 FROM public.user_profile_items ui
        WHERE ui.user_id = v_uid AND ui.item_id = c.id
     )
   ORDER BY random()
   LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Du besitzt bereits alle Gegenstände dieses Glücksrads.';
  END IF;

  UPDATE public.profiles
     SET points = COALESCE(points,0) - v_cost
   WHERE id = v_uid AND COALESCE(points,0) >= v_cost
   RETURNING points INTO v_points;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Du hast nicht genügend XP. Benötigt: % XP.', v_cost;
  END IF;

  INSERT INTO public.user_profile_items(user_id,item_id)
  VALUES (v_uid,v_item.id)
  ON CONFLICT (user_id,item_id) DO NOTHING;

  RETURN QUERY SELECT (v_item.sort_order-1)::integer, v_item.id, v_item.name, v_item.rarity, v_points;
END;
$$;

REVOKE ALL ON FUNCTION public.spin_profile_item_wheel(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.spin_profile_item_wheel(text) TO authenticated;

-- Nutzer können nur eigene Gegenstände ausrüsten/ablegen.
-- Pro Gegenstandskategorie (Rahmen/Badge/Effekt) ist jeweils ein Slot aktiv.
CREATE OR REPLACE FUNCTION public.equip_profile_item(p_item_id text,p_equip boolean)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_kind text;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'Bitte zuerst anmelden.'; END IF;

  SELECT c.kind INTO v_kind
    FROM public.user_profile_items ui
    JOIN public.profile_item_catalog c ON c.id=ui.item_id
   WHERE ui.user_id=v_uid AND ui.item_id=p_item_id;

  IF NOT FOUND THEN RAISE EXCEPTION 'Du besitzt diesen Gegenstand nicht.'; END IF;

  IF p_equip THEN
    UPDATE public.user_profile_items ui
       SET is_equipped=false
      FROM public.profile_item_catalog c
     WHERE ui.user_id=v_uid AND ui.item_id=c.id
       AND c.kind=v_kind;
    UPDATE public.user_profile_items
       SET is_equipped=true
     WHERE user_id=v_uid AND item_id=p_item_id;
  ELSE
    UPDATE public.user_profile_items
       SET is_equipped=false
     WHERE user_id=v_uid AND item_id=p_item_id;
  END IF;

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.equip_profile_item(text,boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.equip_profile_item(text,boolean) TO authenticated;

-- Ausschließlich Admin-Chef kann Gegenstände an andere Accounts vergeben
-- oder entfernen. Die Rolle wird direkt in profiles geprüft.
CREATE OR REPLACE FUNCTION public.chef_manage_profile_item(
  p_user_id uuid,
  p_item_id text,
  p_action text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'Bitte zuerst anmelden.'; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.profiles p
     WHERE p.id=v_uid AND COALESCE(p.is_admin_chef,false)=true
  ) THEN
    RAISE EXCEPTION 'Nur der Admin-Chef darf Profilgegenstände verwalten.';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id=p_user_id) THEN
    RAISE EXCEPTION 'Mitglied nicht gefunden.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.profile_item_catalog WHERE id=p_item_id) THEN
    RAISE EXCEPTION 'Profilgegenstand nicht gefunden.';
  END IF;

  IF p_action='grant' THEN
    INSERT INTO public.user_profile_items(user_id,item_id)
    VALUES (p_user_id,p_item_id)
    ON CONFLICT (user_id,item_id) DO NOTHING;
  ELSIF p_action='remove' THEN
    DELETE FROM public.user_profile_items
     WHERE user_id=p_user_id AND item_id=p_item_id;
  ELSE
    RAISE EXCEPTION 'Ungültige Aktion.';
  END IF;

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.chef_manage_profile_item(uuid,text,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.chef_manage_profile_item(uuid,text,text) TO authenticated;

-- @all in News-Beiträgen. Die vorhandene Chat-Funktion
-- notify_all_mention(uuid) bleibt unverändert erhalten.
CREATE OR REPLACE FUNCTION public.notify_all_post_mention(p_target_id uuid)
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
  IF v_uid IS NULL THEN RAISE EXCEPTION 'Bitte zuerst anmelden.'; END IF;

  SELECT COALESCE(NULLIF(p.display_name,''),NULLIF(p.username,''),'Ein Admin')
    INTO v_actor_name
    FROM public.profiles p
   WHERE p.id=v_uid
     AND (COALESCE(p.is_admin,false)=true OR COALESCE(p.is_admin_chef,false)=true);

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Nur Admins und der Admin-Chef dürfen @all verwenden.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.posts p
     WHERE p.id=p_target_id
       AND p.user_id=v_uid
       AND p.content ~* '(^|[^[:alnum:]_])@all([^[:alnum:]_]|$)'
  ) THEN
    RAISE EXCEPTION 'Der News-Beitrag enthält keine gültige @all-Erwähnung.';
  END IF;

  INSERT INTO public.notifications (user_id,content,actor_id,target_type,target_id)
  SELECT p.id,v_actor_name || ' hat alle Mitglieder in einem News-Beitrag erwähnt.',
         v_uid,'post',p_target_id
    FROM public.profiles p
   WHERE p.id<>v_uid;

  GET DIAGNOSTICS v_inserted=ROW_COUNT;
  RETURN v_inserted;
END;
$$;

REVOKE ALL ON FUNCTION public.notify_all_post_mention(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.notify_all_post_mention(uuid) TO authenticated;


-- ============================================================
-- News-Umfragen: jeder schreibberechtigte Account kann Umfragen
-- erstellen; Mitglieder können abstimmen und ihre Stimme ändern.
-- ============================================================
CREATE TABLE IF NOT EXISTS public.post_polls (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  post_id uuid NOT NULL UNIQUE REFERENCES public.posts(id) ON DELETE CASCADE,
  created_by uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  question text NOT NULL CHECK (length(trim(question)) BETWEEN 1 AND 180),
  options jsonb NOT NULL CHECK (
    jsonb_typeof(options) = 'array'
    AND jsonb_array_length(options) BETWEEN 2 AND 4
  ),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.post_poll_votes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  poll_id uuid NOT NULL REFERENCES public.post_polls(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  option_index integer NOT NULL CHECK (option_index >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (poll_id,user_id)
);

CREATE INDEX IF NOT EXISTS post_poll_votes_poll_idx
  ON public.post_poll_votes(poll_id);

ALTER TABLE public.post_polls ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.post_poll_votes ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS post_polls_authenticated_read ON public.post_polls;
CREATE POLICY post_polls_authenticated_read
  ON public.post_polls FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS post_polls_owner_insert ON public.post_polls;
CREATE POLICY post_polls_owner_insert
  ON public.post_polls FOR INSERT TO authenticated
  WITH CHECK (
    created_by = auth.uid()
    AND EXISTS (
      SELECT 1 FROM public.posts p
       WHERE p.id = post_id AND p.user_id = auth.uid()
    )
  );

DROP POLICY IF EXISTS post_poll_votes_authenticated_read ON public.post_poll_votes;
CREATE POLICY post_poll_votes_authenticated_read
  ON public.post_poll_votes FOR SELECT TO authenticated USING (true);

REVOKE INSERT, UPDATE, DELETE ON public.post_polls FROM anon, authenticated;
GRANT SELECT ON public.post_polls TO authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.post_poll_votes FROM anon, authenticated;
GRANT SELECT ON public.post_poll_votes TO authenticated;
-- INSERT auf post_polls wird nur für den Post-Eigentümer erlaubt.
GRANT INSERT ON public.post_polls TO authenticated;

CREATE OR REPLACE FUNCTION public.vote_on_post_poll(
  p_poll_id uuid,
  p_option_index integer
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_options jsonb;
  v_count integer;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'Bitte zuerst anmelden.'; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.profiles p
     WHERE p.id = v_uid
       AND COALESCE(p.is_viewer,false) = false
       AND COALESCE(p.is_temp_viewer,false) = false
  ) THEN
    RAISE EXCEPTION 'Im Zuschauermodus kannst du nicht abstimmen.';
  END IF;

  SELECT options INTO v_options
    FROM public.post_polls
   WHERE id = p_poll_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Diese Umfrage existiert nicht mehr.'; END IF;

  IF p_option_index < 0 OR p_option_index >= jsonb_array_length(v_options) THEN
    RAISE EXCEPTION 'Ungültige Antwortmöglichkeit.';
  END IF;

  INSERT INTO public.post_poll_votes(poll_id,user_id,option_index)
  VALUES (p_poll_id,v_uid,p_option_index)
  ON CONFLICT (poll_id,user_id)
  DO UPDATE SET option_index = EXCLUDED.option_index, created_at = now();

  SELECT count(*)::integer INTO v_count
    FROM public.post_poll_votes WHERE poll_id = p_poll_id;
  RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION public.vote_on_post_poll(uuid,integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.vote_on_post_poll(uuid,integer) TO authenticated;

-- ============================================================
-- Private Nachrichten: explizite Lesebestätigung.
-- Die vorhandene read-Spalte wird weiterverwendet.
-- ============================================================
ALTER TABLE public.direct_messages
  ADD COLUMN IF NOT EXISTS read boolean NOT NULL DEFAULT false;

CREATE INDEX IF NOT EXISTS direct_messages_receiver_read_idx
  ON public.direct_messages(receiver_id,read,created_at DESC);

-- Nur Empfänger dürfen den Lesestatus ihrer eingehenden Nachrichten ändern.
ALTER TABLE public.direct_messages ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS direct_messages_receiver_mark_read ON public.direct_messages;
CREATE POLICY direct_messages_receiver_mark_read
  ON public.direct_messages FOR UPDATE TO authenticated
  USING (receiver_id = auth.uid())
  WITH CHECK (receiver_id = auth.uid());

-- ============================================================
-- Admin-Chef: die 10 zuletzt gelöschten News-Beiträge protokollieren.
-- Die Erfassung beginnt ab Installation dieses SQL-Setups.
-- ============================================================
CREATE TABLE IF NOT EXISTS public.deleted_posts_audit (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  post_id uuid,
  post_title text,
  post_content text,
  author_id uuid,
  author_username text,
  author_display_name text,
  deleted_by uuid,
  deleted_at timestamptz NOT NULL DEFAULT now(),
  original_post jsonb
);

CREATE INDEX IF NOT EXISTS deleted_posts_audit_deleted_at_idx
  ON public.deleted_posts_audit(deleted_at DESC);

ALTER TABLE public.deleted_posts_audit ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS deleted_posts_audit_chef_read ON public.deleted_posts_audit;
CREATE POLICY deleted_posts_audit_chef_read
  ON public.deleted_posts_audit FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.profiles p
       WHERE p.id = auth.uid() AND COALESCE(p.is_admin_chef,false) = true
    )
  );

REVOKE INSERT, UPDATE, DELETE ON public.deleted_posts_audit FROM anon, authenticated;
GRANT SELECT ON public.deleted_posts_audit TO authenticated;

CREATE OR REPLACE FUNCTION public.audit_deleted_news_post()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_username text;
  v_display_name text;
BEGIN
  SELECT p.username,p.display_name
    INTO v_username,v_display_name
    FROM public.profiles p
   WHERE p.id = OLD.user_id;

  INSERT INTO public.deleted_posts_audit (
    post_id,post_title,post_content,author_id,author_username,
    author_display_name,deleted_by,deleted_at,original_post
  ) VALUES (
    OLD.id,OLD.title,OLD.content,OLD.user_id,v_username,
    v_display_name,auth.uid(),now(),to_jsonb(OLD)
  );
  RETURN OLD;
END;
$$;

DROP TRIGGER IF EXISTS posts_audit_delete ON public.posts;
CREATE TRIGGER posts_audit_delete
  BEFORE DELETE ON public.posts
  FOR EACH ROW EXECUTE FUNCTION public.audit_deleted_news_post();

-- ============================================================
-- Future Community: XP verschenken, Umfrage-Bonus, Updates-Panel
-- und Cosmetic-Marktplatz.
-- Alle XP- und Gegenstandstransfers laufen serverseitig atomar.
-- Dieses Zusatzsetup ist wiederholt ausführbar.
-- ============================================================

-- Das Updates-Panel verwendet dieselbe zentrale Einstellungszeile wie die Regeln.
ALTER TABLE public.community_settings
  ADD COLUMN IF NOT EXISTS updates text;

-- Pro Mitglied und Umfrage gibt es maximal einmalig 5 XP.
-- Beim späteren Ändern der Stimme werden keine weiteren XP vergeben.
DROP FUNCTION IF EXISTS public.vote_on_post_poll(uuid,integer);
CREATE FUNCTION public.vote_on_post_poll(
  p_poll_id uuid,
  p_option_index integer
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_options jsonb;
  v_count integer;
  v_awarded boolean := false;
  v_points integer;
  v_is_viewer boolean;
  v_is_temp_viewer boolean;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'Bitte zuerst anmelden.'; END IF;

  SELECT COALESCE(p.is_viewer,false),COALESCE(p.is_temp_viewer,false),COALESCE(p.points,0)
    INTO v_is_viewer,v_is_temp_viewer,v_points
    FROM public.profiles p
   WHERE p.id=v_uid
   FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Profil nicht gefunden.'; END IF;
  IF v_is_viewer OR v_is_temp_viewer THEN
    RAISE EXCEPTION 'Im Zuschauermodus kannst du nicht abstimmen.';
  END IF;

  SELECT pp.options INTO v_options
    FROM public.post_polls pp
   WHERE pp.id=p_poll_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Diese Umfrage existiert nicht mehr.'; END IF;
  IF p_option_index IS NULL OR p_option_index < 0 OR p_option_index >= jsonb_array_length(v_options) THEN
    RAISE EXCEPTION 'Ungültige Antwortmöglichkeit.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.post_poll_votes pv
     WHERE pv.poll_id=p_poll_id AND pv.user_id=v_uid
  ) THEN
    v_awarded := true;
    UPDATE public.profiles
       SET points=COALESCE(points,0)+5
     WHERE id=v_uid
     RETURNING points INTO v_points;
  END IF;

  INSERT INTO public.post_poll_votes(poll_id,user_id,option_index)
  VALUES (p_poll_id,v_uid,p_option_index)
  ON CONFLICT (poll_id,user_id)
  DO UPDATE SET option_index=EXCLUDED.option_index,created_at=now();

  SELECT count(*)::integer INTO v_count
    FROM public.post_poll_votes pv WHERE pv.poll_id=p_poll_id;

  RETURN jsonb_build_object(
    'vote_count',v_count,
    'awarded_xp',v_awarded,
    'xp_award',CASE WHEN v_awarded THEN 5 ELSE 0 END,
    'new_points',v_points
  );
END;
$$;
REVOKE ALL ON FUNCTION public.vote_on_post_poll(uuid,integer) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.vote_on_post_poll(uuid,integer) TO authenticated;

-- XP verschenken: Abzug, Gutschrift und Benachrichtigung sind eine Transaktion.
CREATE OR REPLACE FUNCTION public.gift_community_xp(
  p_recipient_id uuid,
  p_amount integer
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_sender uuid := auth.uid();
  v_sender_points integer;
  v_recipient_points integer;
  v_sender_name text;
  v_recipient_viewer boolean;
  v_sender_viewer boolean;
BEGIN
  IF v_sender IS NULL THEN RAISE EXCEPTION 'Bitte zuerst anmelden.'; END IF;
  IF p_recipient_id IS NULL OR p_recipient_id=v_sender THEN
    RAISE EXCEPTION 'Bitte wähle ein anderes Mitglied aus.';
  END IF;
  IF p_amount IS NULL OR p_amount<=0 THEN
    RAISE EXCEPTION 'Der XP-Betrag muss größer als 0 sein.';
  END IF;

  -- Einheitliche Sperrreihenfolge verhindert Deadlocks bei gleichzeitigen Geschenken.
  PERFORM 1 FROM public.profiles p
   WHERE p.id IN (v_sender,p_recipient_id)
   ORDER BY p.id
   FOR UPDATE;

  SELECT COALESCE(p.points,0),COALESCE(p.is_viewer,false) OR COALESCE(p.is_temp_viewer,false),
         COALESCE(NULLIF(p.display_name,''),NULLIF(p.username,''),'Ein Mitglied')
    INTO v_sender_points,v_sender_viewer,v_sender_name
    FROM public.profiles p WHERE p.id=v_sender;
  IF NOT FOUND THEN RAISE EXCEPTION 'Dein Profil wurde nicht gefunden.'; END IF;
  SELECT COALESCE(p.points,0),COALESCE(p.is_viewer,false) OR COALESCE(p.is_temp_viewer,false)
    INTO v_recipient_points,v_recipient_viewer
    FROM public.profiles p WHERE p.id=p_recipient_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Der Empfänger wurde nicht gefunden.'; END IF;
  IF v_sender_viewer THEN RAISE EXCEPTION 'Im Zuschauermodus kannst du keine XP verschenken.'; END IF;
  IF v_sender_points<p_amount THEN RAISE EXCEPTION 'Du hast nicht genügend XP. Dein Kontostand beträgt % XP.',v_sender_points; END IF;

  UPDATE public.profiles SET points=COALESCE(points,0)-p_amount WHERE id=v_sender
    RETURNING points INTO v_sender_points;
  UPDATE public.profiles SET points=COALESCE(points,0)+p_amount WHERE id=p_recipient_id
    RETURNING points INTO v_recipient_points;

  INSERT INTO public.notifications(user_id,content,actor_id,target_type,target_id)
  VALUES (p_recipient_id,v_sender_name||' hat dir '||p_amount::text||' XP geschenkt.',v_sender,'xp_gift',NULL);

  RETURN jsonb_build_object('amount',p_amount,'sender_points',v_sender_points,'recipient_points',v_recipient_points);
END;
$$;
REVOKE ALL ON FUNCTION public.gift_community_xp(uuid,integer) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.gift_community_xp(uuid,integer) TO authenticated;

-- Cosmetic-Marktplatz: Gegenstände werden nur angeboten, wenn der Verkäufer
-- sie besitzt. Käufe übertragen Gegenstand und XP atomar; kein negativer Stand.
CREATE TABLE IF NOT EXISTS public.cosmetic_market_listings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  seller_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  item_id text NOT NULL REFERENCES public.profile_item_catalog(id) ON DELETE RESTRICT,
  price integer NOT NULL CHECK (price>0),
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active','sold','cancelled')),
  buyer_id uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  sold_at timestamptz,
  cancelled_at timestamptz
);
CREATE INDEX IF NOT EXISTS cosmetic_market_active_created_idx
  ON public.cosmetic_market_listings(status,created_at DESC);
CREATE UNIQUE INDEX IF NOT EXISTS cosmetic_market_one_active_listing_per_seller_item
  ON public.cosmetic_market_listings(seller_id,item_id) WHERE status='active';
ALTER TABLE public.cosmetic_market_listings ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS cosmetic_market_listings_authenticated_read ON public.cosmetic_market_listings;
CREATE POLICY cosmetic_market_listings_authenticated_read
  ON public.cosmetic_market_listings FOR SELECT TO authenticated USING (true);
REVOKE INSERT,UPDATE,DELETE ON public.cosmetic_market_listings FROM anon,authenticated;
GRANT SELECT ON public.cosmetic_market_listings TO authenticated;

CREATE OR REPLACE FUNCTION public.create_cosmetic_market_listing(
  p_item_id text,
  p_price integer
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_listing_id uuid;
  v_viewer boolean;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'Bitte zuerst anmelden.'; END IF;
  IF p_price IS NULL OR p_price<=0 THEN RAISE EXCEPTION 'Der Preis muss größer als 0 XP sein.'; END IF;
  SELECT COALESCE(is_viewer,false) OR COALESCE(is_temp_viewer,false)
    INTO v_viewer FROM public.profiles WHERE id=v_uid FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Profil nicht gefunden.'; END IF;
  IF v_viewer THEN RAISE EXCEPTION 'Im Zuschauermodus kannst du keine Gegenstände anbieten.'; END IF;

  PERFORM 1 FROM public.user_profile_items ui
   WHERE ui.user_id=v_uid AND ui.item_id=p_item_id
   FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Du besitzt diesen Gegenstand nicht.'; END IF;
  IF EXISTS (SELECT 1 FROM public.cosmetic_market_listings l
              WHERE l.seller_id=v_uid AND l.item_id=p_item_id AND l.status='active') THEN
    RAISE EXCEPTION 'Dieser Gegenstand wird bereits angeboten.';
  END IF;

  UPDATE public.user_profile_items SET is_equipped=false
   WHERE user_id=v_uid AND item_id=p_item_id;
  INSERT INTO public.cosmetic_market_listings(seller_id,item_id,price)
  VALUES(v_uid,p_item_id,p_price) RETURNING id INTO v_listing_id;
  RETURN v_listing_id;
END;
$$;
REVOKE ALL ON FUNCTION public.create_cosmetic_market_listing(text,integer) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.create_cosmetic_market_listing(text,integer) TO authenticated;

CREATE OR REPLACE FUNCTION public.cancel_cosmetic_market_listing(p_listing_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'Bitte zuerst anmelden.'; END IF;
  UPDATE public.cosmetic_market_listings
     SET status='cancelled',cancelled_at=now()
   WHERE id=p_listing_id AND seller_id=v_uid AND status='active';
  IF NOT FOUND THEN RAISE EXCEPTION 'Das Angebot ist nicht mehr aktiv oder gehört dir nicht.'; END IF;
  RETURN true;
END;
$$;
REVOKE ALL ON FUNCTION public.cancel_cosmetic_market_listing(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.cancel_cosmetic_market_listing(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.buy_cosmetic_market_listing(p_listing_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_buyer uuid := auth.uid();
  v_seller uuid;
  v_item_id text;
  v_price integer;
  v_status text;
  v_item_name text;
  v_item public.profile_item_catalog%ROWTYPE;
  v_buyer_points integer;
  v_seller_points integer;
  v_buyer_viewer boolean;
  v_seller_name text;
BEGIN
  IF v_buyer IS NULL THEN RAISE EXCEPTION 'Bitte zuerst anmelden.'; END IF;
  SELECT l.seller_id,l.item_id,l.price,l.status
    INTO v_seller,v_item_id,v_price,v_status
    FROM public.cosmetic_market_listings l
   WHERE l.id=p_listing_id
   FOR UPDATE;
  IF NOT FOUND OR v_status<>'active' THEN RAISE EXCEPTION 'Dieses Angebot ist nicht mehr verfügbar.'; END IF;
  IF v_seller=v_buyer THEN RAISE EXCEPTION 'Du kannst dein eigenes Angebot nicht kaufen.'; END IF;

  PERFORM 1 FROM public.profiles p
   WHERE p.id IN (v_buyer,v_seller)
   ORDER BY p.id
   FOR UPDATE;
  SELECT COALESCE(p.points,0),COALESCE(p.is_viewer,false) OR COALESCE(p.is_temp_viewer,false)
    INTO v_buyer_points,v_buyer_viewer FROM public.profiles p WHERE p.id=v_buyer;
  IF NOT FOUND THEN RAISE EXCEPTION 'Käuferprofil nicht gefunden.'; END IF;
  IF v_buyer_viewer THEN RAISE EXCEPTION 'Im Zuschauermodus kannst du keine Gegenstände kaufen.'; END IF;
  SELECT COALESCE(p.points,0),COALESCE(NULLIF(p.display_name,''),NULLIF(p.username,''),'Ein Mitglied')
    INTO v_seller_points,v_seller_name FROM public.profiles p WHERE p.id=v_seller;
  IF NOT FOUND THEN RAISE EXCEPTION 'Verkäuferprofil nicht gefunden.'; END IF;
  IF v_buyer_points<v_price THEN RAISE EXCEPTION 'Du hast nicht genügend XP. Benötigt: % XP.',v_price; END IF;

  SELECT c.* INTO v_item FROM public.profile_item_catalog c WHERE c.id=v_item_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Dieser Cosmetic-Gegenstand existiert nicht mehr.'; END IF;
  IF EXISTS (SELECT 1 FROM public.user_profile_items ui WHERE ui.user_id=v_buyer AND ui.item_id=v_item_id) THEN
    RAISE EXCEPTION 'Du besitzt diesen Gegenstand bereits.';
  END IF;
  PERFORM 1 FROM public.user_profile_items ui
   WHERE ui.user_id=v_seller AND ui.item_id=v_item_id
   FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Der Verkäufer besitzt den angebotenen Gegenstand nicht mehr.'; END IF;

  UPDATE public.profiles SET points=COALESCE(points,0)-v_price
   WHERE id=v_buyer AND COALESCE(points,0)>=v_price
   RETURNING points INTO v_buyer_points;
  IF NOT FOUND THEN RAISE EXCEPTION 'Nicht genügend XP. Dein Kontostand wurde nicht verändert.'; END IF;
  UPDATE public.profiles SET points=COALESCE(points,0)+v_price
   WHERE id=v_seller RETURNING points INTO v_seller_points;

  DELETE FROM public.user_profile_items WHERE user_id=v_seller AND item_id=v_item_id;
  INSERT INTO public.user_profile_items(user_id,item_id,is_equipped)
  VALUES(v_buyer,v_item_id,false);
  UPDATE public.cosmetic_market_listings
     SET status='sold',buyer_id=v_buyer,sold_at=now()
   WHERE id=p_listing_id AND status='active';
  IF NOT FOUND THEN RAISE EXCEPTION 'Das Angebot wurde zwischenzeitlich verkauft.'; END IF;

  INSERT INTO public.notifications(user_id,content,actor_id,target_type,target_id)
  VALUES(v_seller,'Dein Cosmetic „'||v_item.name||'“ wurde für '||v_price::text||' XP verkauft. Die XP wurden dir gutgeschrieben.',v_buyer,'market_sale',p_listing_id);

  RETURN jsonb_build_object(
    'item_id',v_item_id,
    'item_name',v_item.name,
    'price',v_price,
    'seller_id',v_seller,
    'buyer_points',v_buyer_points,
    'seller_points',v_seller_points
  );
END;
$$;
REVOKE ALL ON FUNCTION public.buy_cosmetic_market_listing(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.buy_cosmetic_market_listing(uuid) TO authenticated;

-- Ein angebotener Gegenstand kann nicht parallel wieder ausgerüstet werden.
CREATE OR REPLACE FUNCTION public.equip_profile_item(p_item_id text,p_equip boolean)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_kind text;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'Bitte zuerst anmelden.'; END IF;
  SELECT c.kind INTO v_kind
    FROM public.user_profile_items ui
    JOIN public.profile_item_catalog c ON c.id=ui.item_id
   WHERE ui.user_id=v_uid AND ui.item_id=p_item_id
   FOR UPDATE OF ui;
  IF NOT FOUND THEN RAISE EXCEPTION 'Du besitzt diesen Gegenstand nicht.'; END IF;
  IF p_equip AND EXISTS (
    SELECT 1 FROM public.cosmetic_market_listings l
     WHERE l.seller_id=v_uid AND l.item_id=p_item_id AND l.status='active'
  ) THEN
    RAISE EXCEPTION 'Dieser Gegenstand ist auf dem Markt angeboten. Ziehe das Angebot zuerst zurück.';
  END IF;
  IF p_equip THEN
    UPDATE public.user_profile_items ui
       SET is_equipped=false
      FROM public.profile_item_catalog c
     WHERE ui.user_id=v_uid AND ui.item_id=c.id AND c.kind=v_kind;
    UPDATE public.user_profile_items SET is_equipped=true
     WHERE user_id=v_uid AND item_id=p_item_id;
  ELSE
    UPDATE public.user_profile_items SET is_equipped=false
     WHERE user_id=v_uid AND item_id=p_item_id;
  END IF;
  RETURN true;
END;
$$;
REVOKE ALL ON FUNCTION public.equip_profile_item(text,boolean) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.equip_profile_item(text,boolean) TO authenticated;
