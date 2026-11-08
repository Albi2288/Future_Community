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
  v_inserted boolean;
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
     SET points = COALESCE(p.points,0) - v_cost
   WHERE p.id = v_uid AND COALESCE(p.points,0) >= v_cost
   RETURNING p.points INTO v_points;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Du hast nicht genügend XP. Benötigt: % XP.', v_cost;
  END IF;

  -- Kein Conflict-Target: item_id ist zugleich ein RETURNS-TABLE-Ausgabeparameter.
  INSERT INTO public.user_profile_items AS upi(user_id,item_id)
  VALUES (v_uid,v_item.id)
  ON CONFLICT DO NOTHING
  RETURNING true INTO v_inserted;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Der Gegenstand wurde bereits vergeben. Bitte erneut versuchen.';
  END IF;

  RETURN QUERY
    SELECT (v_item.sort_order-1)::integer,
           v_item.id,
           v_item.name,
           v_item.rarity,
           v_points;
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

DROP FUNCTION IF EXISTS public.vote_on_post_poll(uuid,integer);
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

-- XP verschenken: beide Kontostände werden in EINER Transaktion geändert.
-- Der Rückgabewert enthält die tatsächlich gespeicherten neuen Kontostände.
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
  v_sender_viewer boolean;
BEGIN
  IF v_sender IS NULL THEN
    RAISE EXCEPTION 'Bitte zuerst anmelden.';
  END IF;
  IF p_recipient_id IS NULL OR p_recipient_id = v_sender THEN
    RAISE EXCEPTION 'Bitte wähle ein anderes Mitglied aus.';
  END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'Der XP-Betrag muss größer als 0 sein.';
  END IF;

  -- Beide Profile immer in derselben Reihenfolge sperren: verhindert parallele
  -- Geschenk-Transaktionen, die sonst einen negativen Kontostand verursachen könnten.
  PERFORM 1
    FROM public.profiles p
   WHERE p.id IN (v_sender, p_recipient_id)
   ORDER BY p.id
   FOR UPDATE;

  SELECT COALESCE(p.points, 0),
         COALESCE(p.is_viewer, false) OR COALESCE(p.is_temp_viewer, false),
         COALESCE(NULLIF(p.display_name, ''), NULLIF(p.username, ''), 'Ein Mitglied')
    INTO v_sender_points, v_sender_viewer, v_sender_name
    FROM public.profiles p
   WHERE p.id = v_sender;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Dein Profil wurde nicht gefunden.';
  END IF;

  PERFORM 1 FROM public.profiles p WHERE p.id = p_recipient_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Der Empfänger wurde nicht gefunden.';
  END IF;
  IF v_sender_viewer THEN
    RAISE EXCEPTION 'Im Zuschauermodus kannst du keine XP verschenken.';
  END IF;
  IF v_sender_points < p_amount THEN
    RAISE EXCEPTION 'Du hast nicht genügend XP. Dein Kontostand beträgt % XP.', v_sender_points;
  END IF;

  UPDATE public.profiles
     SET points = COALESCE(points, 0) - p_amount
   WHERE id = v_sender
     AND COALESCE(points, 0) >= p_amount
   RETURNING points INTO v_sender_points;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Dein XP-Kontostand hat sich geändert. Bitte versuche es erneut.';
  END IF;

  UPDATE public.profiles
     SET points = COALESCE(points, 0) + p_amount
   WHERE id = p_recipient_id
   RETURNING points INTO v_recipient_points;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Der Empfänger wurde nicht gefunden; die XP-Übertragung wurde abgebrochen.';
  END IF;

  INSERT INTO public.notifications(user_id, content, actor_id, target_type, target_id)
  VALUES (
    p_recipient_id,
    v_sender_name || ' hat dir ' || p_amount::text || ' XP geschenkt.',
    v_sender,
    'xp_gift',
    NULL
  );

  RETURN jsonb_build_object(
    'amount', p_amount,
    'sender_points', v_sender_points,
    'recipient_points', v_recipient_points
  );
END;
$$;
REVOKE ALL ON FUNCTION public.gift_community_xp(uuid, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.gift_community_xp(uuid, integer) TO authenticated;

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


-- ============================================================
-- STRIKES-VERWALTUNG + BIS ZU 5 UMFRAGE-ANTWORTMÖGLICHKEITEN
-- ============================================================

-- Jedes Mitglied erhält einen Strike-Zähler (0 bis 3).
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS strikes integer NOT NULL DEFAULT 0;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.profiles'::regclass
      AND conname = 'profiles_strikes_range_check'
  ) THEN
    ALTER TABLE public.profiles
      ADD CONSTRAINT profiles_strikes_range_check CHECK (strikes BETWEEN 0 AND 3);
  END IF;
END $$;

-- Nur Admins/Admin-Chef dürfen einen Strike vergeben oder entfernen.
-- Das Ziel muss ein normales Mitglied/Zuschauer sein; Admin-Konten sind geschützt.
CREATE OR REPLACE FUNCTION public.adjust_member_strikes(
  p_target_id uuid,
  p_delta integer
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_actor public.profiles%ROWTYPE;
  v_target public.profiles%ROWTYPE;
  v_new_count integer;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Nicht angemeldet.';
  END IF;
  IF p_delta NOT IN (-1, 1) THEN
    RAISE EXCEPTION 'Es ist nur +1 oder -1 erlaubt.';
  END IF;

  SELECT * INTO v_actor FROM public.profiles WHERE id = auth.uid() FOR UPDATE;
  IF NOT FOUND OR NOT (COALESCE(v_actor.is_admin,false) OR COALESCE(v_actor.is_admin_chef,false)) THEN
    RAISE EXCEPTION 'Nur Admins dürfen Strikes verwalten.';
  END IF;

  SELECT * INTO v_target FROM public.profiles WHERE id = p_target_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Mitglied nicht gefunden.';
  END IF;
  IF COALESCE(v_target.is_admin,false) OR COALESCE(v_target.is_admin_chef,false) THEN
    RAISE EXCEPTION 'Admin-Konten können keine Strikes erhalten.';
  END IF;

  v_new_count := GREATEST(0, LEAST(3, COALESCE(v_target.strikes,0) + p_delta));
  UPDATE public.profiles SET strikes = v_new_count WHERE id = p_target_id;
  RETURN v_new_count;
END;
$$;

REVOKE ALL ON FUNCTION public.adjust_member_strikes(uuid,integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.adjust_member_strikes(uuid,integer) TO authenticated;

-- Vorhandene automatisch benannte 2-4-Prüfung durch 2-5 ersetzen.
ALTER TABLE public.post_polls DROP CONSTRAINT IF EXISTS post_polls_options_check;
ALTER TABLE public.post_polls DROP CONSTRAINT IF EXISTS post_polls_options_check1;
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.post_polls'::regclass
      AND conname = 'post_polls_options_2_to_5_check'
  ) THEN
    ALTER TABLE public.post_polls
      ADD CONSTRAINT post_polls_options_2_to_5_check
      CHECK (jsonb_typeof(options) = 'array' AND jsonb_array_length(options) BETWEEN 2 AND 5);
  END IF;
END $$;


-- ============================================================
-- Social-Erweiterungen: Freundeslisten, gespeicherte Beiträge,
-- Emoji-Reaktionen und Beitragsmeldungen.
-- ============================================================

-- Akzeptierte Freundschaften dürfen auf öffentlichen Profilen
-- angezeigt werden. Offene/abgelehnte Anfragen bleiben privat.
ALTER TABLE public.friendships ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS friendships_read_accepted_for_profiles ON public.friendships;
CREATE POLICY friendships_read_accepted_for_profiles
  ON public.friendships FOR SELECT TO authenticated
  USING (status = 'accepted');
GRANT SELECT ON public.friendships TO authenticated;

-- Persönliche Merkliste für Beiträge.
CREATE TABLE IF NOT EXISTS public.saved_posts (
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  post_id uuid NOT NULL REFERENCES public.posts(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, post_id)
);
ALTER TABLE public.saved_posts ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS saved_posts_select_own ON public.saved_posts;
CREATE POLICY saved_posts_select_own ON public.saved_posts
  FOR SELECT TO authenticated USING (user_id = auth.uid());
DROP POLICY IF EXISTS saved_posts_insert_own ON public.saved_posts;
CREATE POLICY saved_posts_insert_own ON public.saved_posts
  FOR INSERT TO authenticated WITH CHECK (user_id = auth.uid());
DROP POLICY IF EXISTS saved_posts_delete_own ON public.saved_posts;
CREATE POLICY saved_posts_delete_own ON public.saved_posts
  FOR DELETE TO authenticated USING (user_id = auth.uid());
GRANT SELECT, INSERT, DELETE ON public.saved_posts TO authenticated;

-- Reaktionen für Kommentare, Community-Chat, private Nachrichten
-- und den internen Admin-Gruppenchat.
CREATE TABLE IF NOT EXISTS public.content_reactions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  target_type text NOT NULL CHECK (target_type IN ('comment','community_chat','dm','admin_group')),
  target_id uuid NOT NULL,
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  emoji text NOT NULL CHECK (emoji IN ('❤️','😂','😮','😢','👍')),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (target_type, target_id, user_id, emoji)
);
CREATE INDEX IF NOT EXISTS content_reactions_target_idx
  ON public.content_reactions(target_type, target_id);
ALTER TABLE public.content_reactions ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.can_view_content_reaction(
  p_target_type text,
  p_target_id uuid
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
BEGIN
  IF v_user_id IS NULL THEN RETURN false; END IF;
  IF p_target_type = 'comment' THEN
    RETURN EXISTS (SELECT 1 FROM public.comments c WHERE c.id = p_target_id);
  ELSIF p_target_type = 'community_chat' THEN
    RETURN EXISTS (SELECT 1 FROM public.chat_messages m WHERE m.id = p_target_id);
  ELSIF p_target_type = 'dm' THEN
    RETURN EXISTS (
      SELECT 1 FROM public.direct_messages m
      WHERE m.id = p_target_id
        AND (m.sender_id = v_user_id OR m.receiver_id = v_user_id)
    );
  ELSIF p_target_type = 'admin_group' THEN
    RETURN EXISTS (
      SELECT 1 FROM public.admin_group_messages m
      WHERE m.id = p_target_id
    ) AND EXISTS (
      SELECT 1 FROM public.profiles p
      WHERE p.id = v_user_id
        AND (COALESCE(p.is_admin,false) OR COALESCE(p.is_admin_chef,false))
    );
  END IF;
  RETURN false;
END;
$$;
REVOKE ALL ON FUNCTION public.can_view_content_reaction(text,uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.can_view_content_reaction(text,uuid) TO authenticated;

DROP POLICY IF EXISTS content_reactions_read_accessible ON public.content_reactions;
CREATE POLICY content_reactions_read_accessible ON public.content_reactions
  FOR SELECT TO authenticated
  USING (public.can_view_content_reaction(target_type, target_id));
GRANT SELECT ON public.content_reactions TO authenticated;

CREATE OR REPLACE FUNCTION public.toggle_content_reaction(
  p_target_type text,
  p_target_id uuid,
  p_emoji text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_profile public.profiles%ROWTYPE;
  v_removed boolean := false;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'Bitte anmelden.'; END IF;
  IF p_emoji NOT IN ('❤️','😂','😮','😢','👍') THEN
    RAISE EXCEPTION 'Diese Reaktion ist nicht erlaubt.';
  END IF;
  IF p_target_type NOT IN ('comment','community_chat','dm','admin_group') THEN
    RAISE EXCEPTION 'Dieser Inhaltstyp kann nicht reagiert werden.';
  END IF;
  SELECT * INTO v_profile FROM public.profiles WHERE id = v_user_id;
  IF NOT FOUND OR COALESCE(v_profile.is_banned,false)
     OR COALESCE(v_profile.is_viewer,false)
     OR COALESCE(v_profile.is_temp_viewer,false) THEN
    RAISE EXCEPTION 'Im Zuschauermodus kannst du nicht reagieren.';
  END IF;
  IF NOT public.can_view_content_reaction(p_target_type,p_target_id) THEN
    RAISE EXCEPTION 'Du darfst auf diesen Inhalt nicht reagieren.';
  END IF;

  DELETE FROM public.content_reactions
   WHERE target_type = p_target_type
     AND target_id = p_target_id
     AND user_id = v_user_id
     AND emoji = p_emoji;
  v_removed := FOUND;
  IF NOT v_removed THEN
    INSERT INTO public.content_reactions(target_type,target_id,user_id,emoji)
    VALUES (p_target_type,p_target_id,v_user_id,p_emoji)
    ON CONFLICT (target_type,target_id,user_id,emoji) DO NOTHING;
  END IF;
  RETURN jsonb_build_object('active',NOT v_removed,'emoji',p_emoji);
END;
$$;
REVOKE ALL ON FUNCTION public.toggle_content_reaction(text,uuid,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.toggle_content_reaction(text,uuid,text) TO authenticated;

-- Beitragsmeldungen: ein offener Datensatz pro meldendem Mitglied
-- und Beitrag. Der Text wird als Snapshot erhalten, falls der Beitrag
-- später gelöscht wird.
CREATE TABLE IF NOT EXISTS public.post_reports (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  reporter_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  post_id uuid REFERENCES public.posts(id) ON DELETE SET NULL,
  post_author_id uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  post_title text NOT NULL DEFAULT '',
  post_content text NOT NULL DEFAULT '',
  reason text NOT NULL DEFAULT '',
  status text NOT NULL DEFAULT 'open' CHECK (status IN ('open','reviewed','dismissed')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  resolved_by uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  resolved_at timestamptz,
  UNIQUE (reporter_id, post_id)
);
CREATE INDEX IF NOT EXISTS post_reports_status_created_idx
  ON public.post_reports(status, created_at DESC);
ALTER TABLE public.post_reports ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS post_reports_admin_read ON public.post_reports;
CREATE POLICY post_reports_admin_read ON public.post_reports
  FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.id = auth.uid()
      AND (COALESCE(p.is_admin,false) OR COALESCE(p.is_admin_chef,false))
  ));
GRANT SELECT ON public.post_reports TO authenticated;

CREATE OR REPLACE FUNCTION public.report_community_post(
  p_post_id uuid,
  p_reason text DEFAULT ''
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_profile public.profiles%ROWTYPE;
  v_post public.posts%ROWTYPE;
  v_report_id uuid;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'Bitte anmelden.'; END IF;
  SELECT * INTO v_profile FROM public.profiles WHERE id = v_user_id;
  IF NOT FOUND OR COALESCE(v_profile.is_banned,false)
     OR COALESCE(v_profile.is_viewer,false)
     OR COALESCE(v_profile.is_temp_viewer,false) THEN
    RAISE EXCEPTION 'Im Zuschauermodus kannst du keine Beiträge melden.';
  END IF;
  SELECT * INTO v_post FROM public.posts WHERE id = p_post_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Beitrag nicht gefunden.'; END IF;
  IF v_post.user_id = v_user_id THEN RAISE EXCEPTION 'Eigene Beiträge können nicht gemeldet werden.'; END IF;

  INSERT INTO public.post_reports(
    reporter_id,post_id,post_author_id,post_title,post_content,reason,status,updated_at
  ) VALUES (
    v_user_id,p_post_id,v_post.user_id,COALESCE(v_post.title,''),COALESCE(v_post.content,''),
    LEFT(COALESCE(p_reason,''),500),'open',now()
  )
  ON CONFLICT (reporter_id,post_id) DO UPDATE SET
    post_author_id = EXCLUDED.post_author_id,
    post_title = EXCLUDED.post_title,
    post_content = EXCLUDED.post_content,
    reason = EXCLUDED.reason,
    status = 'open',
    updated_at = now(),
    resolved_by = NULL,
    resolved_at = NULL
  RETURNING id INTO v_report_id;
  RETURN v_report_id;
END;
$$;
REVOKE ALL ON FUNCTION public.report_community_post(uuid,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.report_community_post(uuid,text) TO authenticated;

CREATE OR REPLACE FUNCTION public.resolve_post_report(
  p_report_id uuid,
  p_status text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_profile public.profiles%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Bitte anmelden.'; END IF;
  SELECT * INTO v_profile FROM public.profiles WHERE id = auth.uid();
  IF NOT FOUND OR NOT (COALESCE(v_profile.is_admin,false) OR COALESCE(v_profile.is_admin_chef,false)) THEN
    RAISE EXCEPTION 'Nur Admins dürfen Meldungen bearbeiten.';
  END IF;
  IF p_status NOT IN ('reviewed','dismissed') THEN
    RAISE EXCEPTION 'Ungültiger Meldungsstatus.';
  END IF;
  UPDATE public.post_reports
     SET status = p_status, updated_at = now(), resolved_by = auth.uid(), resolved_at = now()
   WHERE id = p_report_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Meldung nicht gefunden.'; END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.resolve_post_report(uuid,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.resolve_post_report(uuid,text) TO authenticated;

-- Taegliches Gluecksrad: zufaellige Auswahl aus sechs Segmenten.
-- Die 25-XP-Belohnung ist absichtlich zweimal enthalten und hat dadurch
-- eine doppelt so hohe Chance wie die jeweils einmal enthaltenen Belohnungen.
CREATE OR REPLACE FUNCTION public.spin_daily_wheel()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_day date := (now() AT TIME ZONE 'Europe/Berlin')::date;
  v_count integer;
  v_last text;
  v_idx integer;
  v_label text;
  v_points integer := 0;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'Bitte anmelden.'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(v_uid::text || v_day::text, 0));

  SELECT count(*), (array_agg(reward_label ORDER BY created_at DESC))[1]
    INTO v_count, v_last
    FROM public.daily_wheel_spins
   WHERE user_id = v_uid AND spin_date = v_day;

  IF NOT (v_count = 0 OR (v_count = 1 AND v_last = 'Extra-Dreh')) THEN
    RAISE EXCEPTION 'Du hast heute bereits alle verfügbaren Drehungen genutzt.';
  END IF;

  v_idx := floor(random() * 6)::integer;
  v_label := CASE v_idx
    WHEN 0 THEN '10 XP'
    WHEN 1 THEN '25 XP'
    WHEN 2 THEN '50 XP'
    WHEN 3 THEN '100 XP'
    WHEN 4 THEN 'Extra-Dreh'
    ELSE '25 XP'
  END;
  v_points := CASE v_idx
    WHEN 0 THEN 10
    WHEN 1 THEN 25
    WHEN 2 THEN 50
    WHEN 3 THEN 100
    WHEN 5 THEN 25
    ELSE 0
  END;

  IF v_points > 0 THEN
    UPDATE public.profiles
       SET points = COALESCE(points, 0) + v_points
     WHERE id = v_uid;
    IF NOT FOUND THEN RAISE EXCEPTION 'Profil nicht gefunden.'; END IF;
  END IF;

  INSERT INTO public.daily_wheel_spins(user_id, spin_date, segment_index, reward_label)
  VALUES (v_uid, v_day, v_idx, v_label);

  RETURN jsonb_build_object(
    'segment_index', v_idx,
    'reward_label', v_label,
    'points_awarded', v_points
  );
END;
$function$;
REVOKE ALL ON FUNCTION public.spin_daily_wheel() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.spin_daily_wheel() TO authenticated;


-- ============================================================
-- FUTURE COMMUNITY: tägliche Quests, Community-Events, Profilcover
-- ============================================================

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS profile_background_url text;

-- Öffentlich lesbare aktive Events; Änderungen erfolgen ausschließlich über Chef-RPC.
CREATE TABLE IF NOT EXISTS public.community_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  title text NOT NULL,
  description text NOT NULL DEFAULT '',
  event_type text NOT NULL DEFAULT 'xp_multiplier',
  xp_multiplier integer NOT NULL DEFAULT 2 CHECK (xp_multiplier >= 1 AND xp_multiplier <= 5),
  starts_at timestamptz NOT NULL DEFAULT now(),
  ends_at timestamptz NOT NULL,
  is_active boolean NOT NULL DEFAULT true,
  created_by uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS community_events_active_idx
  ON public.community_events(is_active, ends_at DESC);
ALTER TABLE public.community_events ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS community_events_read_active ON public.community_events;
CREATE POLICY community_events_read_active ON public.community_events
  FOR SELECT TO authenticated USING (is_active = true AND ends_at > now());
GRANT SELECT ON public.community_events TO authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.community_events FROM anon, authenticated;

CREATE OR REPLACE FUNCTION public.community_current_xp_multiplier()
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE((
    SELECT e.xp_multiplier
      FROM public.community_events e
     WHERE e.is_active = true
       AND e.event_type = 'xp_multiplier'
       AND e.starts_at <= now()
       AND e.ends_at > now()
     ORDER BY e.created_at DESC
     LIMIT 1
  ), 1)::integer;
$$;
REVOKE ALL ON FUNCTION public.community_current_xp_multiplier() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.community_current_xp_multiplier() TO authenticated;

CREATE OR REPLACE FUNCTION public.chef_set_weekend_xp_event(
  p_enabled boolean,
  p_duration_hours integer DEFAULT 48
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_event public.community_events%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'Bitte anmelden.'; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.profiles p
     WHERE p.id = v_uid AND COALESCE(p.is_admin_chef,false) = true
  ) THEN
    RAISE EXCEPTION 'Nur der Admin-Chef darf Community-Events starten.';
  END IF;

  IF p_enabled THEN
    IF p_duration_hours IS NULL OR p_duration_hours < 1 OR p_duration_hours > 168 THEN
      RAISE EXCEPTION 'Die Eventdauer muss zwischen 1 und 168 Stunden liegen.';
    END IF;
    UPDATE public.community_events SET is_active = false
     WHERE is_active = true AND event_type = 'xp_multiplier';
    INSERT INTO public.community_events(
      title, description, event_type, xp_multiplier, starts_at, ends_at, is_active, created_by
    ) VALUES (
      '2x XP WOCHENENDE!',
      'Das Community-Event ist aktiv: Für unterstützte Community-Aktivitäten und Quests erhältst du doppelte XP!',
      'xp_multiplier', 2, now(), now() + make_interval(hours => p_duration_hours), true, v_uid
    ) RETURNING * INTO v_event;
    RETURN jsonb_build_object('active',true,'id',v_event.id,'title',v_event.title,'ends_at',v_event.ends_at,'xp_multiplier',2);
  ELSE
    UPDATE public.community_events SET is_active = false
     WHERE is_active = true AND event_type = 'xp_multiplier';
    RETURN jsonb_build_object('active',false);
  END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.chef_set_weekend_xp_event(boolean,integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.chef_set_weekend_xp_event(boolean,integer) TO authenticated;

-- Quest-Katalog: pro Mitglied werden täglich drei unterschiedliche Quests ausgewählt.
CREATE TABLE IF NOT EXISTS public.community_quest_catalog (
  quest_key text PRIMARY KEY,
  title text NOT NULL,
  description text NOT NULL,
  goal integer NOT NULL CHECK (goal > 0),
  reward_xp integer NOT NULL CHECK (reward_xp > 0),
  event_key text NOT NULL UNIQUE
);
INSERT INTO public.community_quest_catalog(quest_key,title,description,goal,reward_xp,event_key) VALUES
 ('create_post','Teile etwas mit der Community','Veröffentliche einen neuen Beitrag.',1,20,'create_post'),
 ('write_comment','Sei Teil der Diskussion','Schreibe zwei Kommentare unter Beiträgen.',2,15,'write_comment'),
 ('react_post','Zeige deine Reaktion','Reagiere auf drei verschiedene Beiträge.',3,15,'react_post'),
 ('send_chat','Melde dich im Community-Chat','Schreibe zwei Nachrichten im öffentlichen Chat.',2,15,'send_chat'),
 ('upload_gallery','Teile einen Moment','Lade ein Bild in die Galerie hoch.',1,20,'upload_gallery'),
 ('send_dm','Knüpfe Kontakte','Sende eine private Nachricht.',1,15,'send_dm')
ON CONFLICT (quest_key) DO UPDATE SET
 title=EXCLUDED.title,description=EXCLUDED.description,goal=EXCLUDED.goal,
 reward_xp=EXCLUDED.reward_xp,event_key=EXCLUDED.event_key;
REVOKE ALL ON public.community_quest_catalog FROM PUBLIC, anon, authenticated;

CREATE TABLE IF NOT EXISTS public.community_daily_quest_progress (
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  quest_date date NOT NULL,
  quest_key text NOT NULL REFERENCES public.community_quest_catalog(quest_key) ON DELETE CASCADE,
  title text NOT NULL,
  description text NOT NULL,
  goal integer NOT NULL,
  progress integer NOT NULL DEFAULT 0,
  reward_xp integer NOT NULL,
  awarded_xp integer NOT NULL DEFAULT 0,
  completed_at timestamptz,
  PRIMARY KEY(user_id,quest_date,quest_key)
);
CREATE INDEX IF NOT EXISTS community_daily_quest_user_date_idx
  ON public.community_daily_quest_progress(user_id,quest_date);
ALTER TABLE public.community_daily_quest_progress ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS community_daily_quest_read_own ON public.community_daily_quest_progress;
CREATE POLICY community_daily_quest_read_own ON public.community_daily_quest_progress
  FOR SELECT TO authenticated USING (user_id = auth.uid());
GRANT SELECT ON public.community_daily_quest_progress TO authenticated;
REVOKE INSERT, UPDATE, DELETE ON public.community_daily_quest_progress FROM PUBLIC, anon, authenticated;

CREATE TABLE IF NOT EXISTS public.community_quest_activity_log (
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  quest_date date NOT NULL,
  event_key text NOT NULL,
  activity_ref text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY(user_id,quest_date,event_key,activity_ref)
);
ALTER TABLE public.community_quest_activity_log ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.community_quest_activity_log FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.award_community_xp(p_user_id uuid,p_base_xp integer)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_award integer;
BEGIN
  IF p_user_id IS NULL OR p_base_xp IS NULL OR p_base_xp <= 0 THEN RETURN 0; END IF;
  v_award := p_base_xp * public.community_current_xp_multiplier();
  UPDATE public.profiles
     SET points = COALESCE(points,0) + v_award
   WHERE id = p_user_id
     AND COALESCE(is_viewer,false) = false
     AND COALESCE(is_temp_viewer,false) = false;
  IF NOT FOUND THEN RETURN 0; END IF;
  RETURN v_award;
END;
$$;
REVOKE ALL ON FUNCTION public.award_community_xp(uuid,integer) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.ensure_daily_community_quests(p_user_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_day date := (now() AT TIME ZONE 'Europe/Berlin')::date;
BEGIN
  INSERT INTO public.community_daily_quest_progress(
    user_id,quest_date,quest_key,title,description,goal,progress,reward_xp
  )
  SELECT p_user_id,v_day,c.quest_key,c.title,c.description,c.goal,0,c.reward_xp
    FROM public.community_quest_catalog c
   ORDER BY md5(p_user_id::text || v_day::text || c.quest_key)
   LIMIT 3
  ON CONFLICT(user_id,quest_date,quest_key) DO NOTHING;
END;
$$;
REVOKE ALL ON FUNCTION public.ensure_daily_community_quests(uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.get_daily_community_quests()
RETURNS TABLE(
  quest_key text,title text,description text,goal integer,progress integer,
  reward_xp integer,awarded_xp integer,completed_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_day date := (now() AT TIME ZONE 'Europe/Berlin')::date;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'Bitte anmelden.'; END IF;
  PERFORM public.ensure_daily_community_quests(v_uid);
  RETURN QUERY
    SELECT q.quest_key,q.title,q.description,q.goal,q.progress,q.reward_xp,q.awarded_xp,q.completed_at
      FROM public.community_daily_quest_progress q
     WHERE q.user_id=v_uid AND q.quest_date=v_day
     ORDER BY q.quest_key;
END;
$$;
REVOKE ALL ON FUNCTION public.get_daily_community_quests() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_daily_community_quests() TO authenticated;

-- Gemeinsamer Trigger: Aktivität zählt höchstens einmal je Tag und Ziel.
CREATE OR REPLACE FUNCTION public.track_community_activity_for_quests()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_row jsonb := to_jsonb(NEW);
  v_uid uuid;
  v_ref text;
  v_event_key text := TG_ARGV[0];
  v_base_xp integer := COALESCE(NULLIF(TG_ARGV[1],''),'0')::integer;
  v_day date := (now() AT TIME ZONE 'Europe/Berlin')::date;
  v_rows integer;
  v_progress integer;
  v_goal integer;
  v_reward integer;
  v_awarded integer;
BEGIN
  v_uid := COALESCE(NULLIF(v_row->>'user_id',''),NULLIF(v_row->>'sender_id',''))::uuid;
  IF v_event_key = 'react_post' THEN
    v_ref := COALESCE(NULLIF(v_row->>'post_id',''),NULLIF(v_row->>'id',''),md5(v_row::text));
  ELSE
    v_ref := COALESCE(NULLIF(v_row->>'id',''),NULLIF(v_row->>'created_at',''),md5(v_row::text));
  END IF;
  IF v_uid IS NULL OR v_event_key IS NULL THEN RETURN NEW; END IF;

  PERFORM public.ensure_daily_community_quests(v_uid);
  IF v_base_xp > 0 THEN
    PERFORM public.award_community_xp(v_uid,v_base_xp);
  END IF;

  INSERT INTO public.community_quest_activity_log(user_id,quest_date,event_key,activity_ref)
  VALUES(v_uid,v_day,v_event_key,v_ref)
  ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows = 0 THEN RETURN NEW; END IF;

  UPDATE public.community_daily_quest_progress q
     SET progress = LEAST(q.goal,q.progress+1),
         completed_at = CASE WHEN q.progress+1 >= q.goal THEN now() ELSE NULL END
   WHERE q.user_id=v_uid AND q.quest_date=v_day AND q.quest_key=v_event_key
     AND q.completed_at IS NULL
  RETURNING q.progress,q.goal,q.reward_xp INTO v_progress,v_goal,v_reward;

  IF FOUND AND v_progress >= v_goal THEN
    v_awarded := public.award_community_xp(v_uid,v_reward);
    UPDATE public.community_daily_quest_progress
       SET awarded_xp = v_awarded
     WHERE user_id=v_uid AND quest_date=v_day AND quest_key=v_event_key;
    INSERT INTO public.notifications(user_id,content)
    VALUES(v_uid,'Tägliche Quest abgeschlossen: +' || v_awarded || ' XP erhalten!');
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.track_community_activity_for_quests() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS community_quest_posts_insert ON public.posts;
CREATE TRIGGER community_quest_posts_insert AFTER INSERT ON public.posts
FOR EACH ROW EXECUTE FUNCTION public.track_community_activity_for_quests('create_post','10');
DROP TRIGGER IF EXISTS community_quest_comments_insert ON public.comments;
CREATE TRIGGER community_quest_comments_insert AFTER INSERT ON public.comments
FOR EACH ROW EXECUTE FUNCTION public.track_community_activity_for_quests('write_comment','2');
DROP TRIGGER IF EXISTS community_quest_likes_insert ON public.likes;
CREATE TRIGGER community_quest_likes_insert AFTER INSERT ON public.likes
FOR EACH ROW EXECUTE FUNCTION public.track_community_activity_for_quests('react_post','0');
DROP TRIGGER IF EXISTS community_quest_chat_insert ON public.chat_messages;
CREATE TRIGGER community_quest_chat_insert AFTER INSERT ON public.chat_messages
FOR EACH ROW EXECUTE FUNCTION public.track_community_activity_for_quests('send_chat','1');
DROP TRIGGER IF EXISTS community_quest_gallery_insert ON public.gallery;
CREATE TRIGGER community_quest_gallery_insert AFTER INSERT ON public.gallery
FOR EACH ROW EXECUTE FUNCTION public.track_community_activity_for_quests('upload_gallery','5');
DROP TRIGGER IF EXISTS community_quest_dm_insert ON public.direct_messages;
CREATE TRIGGER community_quest_dm_insert AFTER INSERT ON public.direct_messages
FOR EACH ROW EXECUTE FUNCTION public.track_community_activity_for_quests('send_dm','1');

-- Event-Multiplikator auch auf die XP-Belohnungen der Umfragen anwenden.
CREATE OR REPLACE FUNCTION public.vote_on_post_poll(
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
  v_xp_award integer := 0;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'Bitte zuerst anmelden.'; END IF;
  SELECT COALESCE(p.is_viewer,false),COALESCE(p.is_temp_viewer,false),COALESCE(p.points,0)
    INTO v_is_viewer,v_is_temp_viewer,v_points
    FROM public.profiles p WHERE p.id=v_uid FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Profil nicht gefunden.'; END IF;
  IF v_is_viewer OR v_is_temp_viewer THEN RAISE EXCEPTION 'Im Zuschauermodus kannst du nicht abstimmen.'; END IF;
  SELECT pp.options INTO v_options FROM public.post_polls pp WHERE pp.id=p_poll_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Diese Umfrage existiert nicht mehr.'; END IF;
  IF p_option_index IS NULL OR p_option_index < 0 OR p_option_index >= jsonb_array_length(v_options) THEN
    RAISE EXCEPTION 'Ungültige Antwortmöglichkeit.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.post_poll_votes pv WHERE pv.poll_id=p_poll_id AND pv.user_id=v_uid) THEN
    v_awarded := true;
    v_xp_award := 5 * public.community_current_xp_multiplier();
    UPDATE public.profiles SET points=COALESCE(points,0)+v_xp_award WHERE id=v_uid RETURNING points INTO v_points;
  END IF;
  INSERT INTO public.post_poll_votes(poll_id,user_id,option_index)
  VALUES(p_poll_id,v_uid,p_option_index)
  ON CONFLICT(poll_id,user_id) DO UPDATE SET option_index=EXCLUDED.option_index,created_at=now();
  SELECT count(*)::integer INTO v_count FROM public.post_poll_votes pv WHERE pv.poll_id=p_poll_id;
  RETURN jsonb_build_object('vote_count',v_count,'awarded_xp',v_awarded,'xp_award',v_xp_award,'new_points',v_points);
END;
$$;
REVOKE ALL ON FUNCTION public.vote_on_post_poll(uuid,integer) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.vote_on_post_poll(uuid,integer) TO authenticated;

-- Auch das tägliche Glücksrad berücksichtigt ein aktives 2x-XP-Event.
CREATE OR REPLACE FUNCTION public.spin_daily_wheel()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_day date := (now() AT TIME ZONE 'Europe/Berlin')::date;
  v_count integer;
  v_last text;
  v_idx integer;
  v_label text;
  v_points integer := 0;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'Bitte anmelden.'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(v_uid::text || v_day::text, 0));
  SELECT count(*), (array_agg(reward_label ORDER BY created_at DESC))[1]
    INTO v_count, v_last FROM public.daily_wheel_spins
   WHERE user_id = v_uid AND spin_date = v_day;
  IF NOT (v_count = 0 OR (v_count = 1 AND v_last = 'Extra-Dreh')) THEN
    RAISE EXCEPTION 'Du hast heute bereits alle verfügbaren Drehungen genutzt.';
  END IF;
  v_idx := floor(random() * 6)::integer;
  v_label := CASE v_idx WHEN 0 THEN '10 XP' WHEN 1 THEN '25 XP' WHEN 2 THEN '50 XP'
    WHEN 3 THEN '100 XP' WHEN 4 THEN 'Extra-Dreh' ELSE '25 XP' END;
  v_points := CASE v_idx WHEN 0 THEN 10 WHEN 1 THEN 25 WHEN 2 THEN 50 WHEN 3 THEN 100 WHEN 5 THEN 25 ELSE 0 END;
  IF v_points > 0 THEN
    v_points := v_points * public.community_current_xp_multiplier();
    UPDATE public.profiles SET points=COALESCE(points,0)+v_points WHERE id=v_uid;
    IF NOT FOUND THEN RAISE EXCEPTION 'Profil nicht gefunden.'; END IF;
  END IF;
  INSERT INTO public.daily_wheel_spins(user_id,spin_date,segment_index,reward_label)
  VALUES(v_uid,v_day,v_idx,v_label);
  RETURN jsonb_build_object('segment_index',v_idx,'reward_label',v_label,
    'points_awarded',v_points,'xp_multiplier',public.community_current_xp_multiplier());
END;
$function$;
REVOKE ALL ON FUNCTION public.spin_daily_wheel() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.spin_daily_wheel() TO authenticated;
