-- Future Community: Chat-Antworten, Regelbestätigung, Gerätesperren und Glücksfee
-- Vor Ausführung bitte ein Datenbank-Backup erstellen.

-- 1) WhatsApp-artige Antworten in allen Chatbereichen
ALTER TABLE public.chat_messages ADD COLUMN IF NOT EXISTS reply_to_id uuid;
ALTER TABLE public.admin_group_messages ADD COLUMN IF NOT EXISTS reply_to_id uuid;
ALTER TABLE public.direct_messages ADD COLUMN IF NOT EXISTS reply_to_id uuid;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='chat_messages_reply_to_id_fkey') THEN
    ALTER TABLE public.chat_messages ADD CONSTRAINT chat_messages_reply_to_id_fkey
      FOREIGN KEY (reply_to_id) REFERENCES public.chat_messages(id) ON DELETE SET NULL;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='admin_group_messages_reply_to_id_fkey') THEN
    ALTER TABLE public.admin_group_messages ADD CONSTRAINT admin_group_messages_reply_to_id_fkey
      FOREIGN KEY (reply_to_id) REFERENCES public.admin_group_messages(id) ON DELETE SET NULL;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='direct_messages_reply_to_id_fkey') THEN
    ALTER TABLE public.direct_messages ADD CONSTRAINT direct_messages_reply_to_id_fkey
      FOREIGN KEY (reply_to_id) REFERENCES public.direct_messages(id) ON DELETE SET NULL;
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS chat_messages_reply_to_idx ON public.chat_messages(reply_to_id);
CREATE INDEX IF NOT EXISTS admin_group_messages_reply_to_idx ON public.admin_group_messages(reply_to_id);
CREATE INDEX IF NOT EXISTS direct_messages_reply_to_idx ON public.direct_messages(reply_to_id);

-- 2) Einmalige Bestätigung der Community-Regeln
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS accepted_rules_at timestamptz;

CREATE OR REPLACE FUNCTION public.accept_community_rules()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public
AS $$
DECLARE v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'Bitte anmelden.'; END IF;
  UPDATE public.profiles SET accepted_rules_at = now() WHERE id = v_uid;
  IF NOT FOUND THEN RAISE EXCEPTION 'Profil nicht gefunden.'; END IF;
  RETURN jsonb_build_object('success',true,'accepted_at',now());
END;
$$;
REVOKE ALL ON FUNCTION public.accept_community_rules() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.accept_community_rules() TO authenticated;

-- 3) Geräteverwaltung
CREATE TABLE IF NOT EXISTS public.device_blocks (
  device_id text PRIMARY KEY,
  blocked boolean NOT NULL DEFAULT true,
  reason text,
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid
);
CREATE TABLE IF NOT EXISTS public.device_settings (
  id boolean PRIMARY KEY DEFAULT true CHECK (id),
  account_limit integer NOT NULL DEFAULT 2 CHECK (account_limit BETWEEN 1 AND 20),
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid
);
INSERT INTO public.device_settings(id,account_limit) VALUES(true,2)
ON CONFLICT(id) DO NOTHING;

ALTER TABLE public.device_blocks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.device_settings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.device_blocks, public.device_settings FROM anon, authenticated;

CREATE OR REPLACE FUNCTION public.check_device_login(p_device_id text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO public
AS $$
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Anmeldung erforderlich.'; END IF;
  IF p_device_id IS NULL OR length(p_device_id)<16 OR length(p_device_id)>100 THEN
    RAISE EXCEPTION 'Ungültige Gerätekennung.';
  END IF;
  IF EXISTS(SELECT 1 FROM public.device_blocks WHERE device_id=p_device_id AND blocked=true) THEN
    RAISE EXCEPTION 'Dieses Gerät ist durch den Admin-Chef gesperrt.';
  END IF;
  RETURN jsonb_build_object('allowed',true);
END;
$$;
REVOKE ALL ON FUNCTION public.check_device_login(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.check_device_login(text) TO authenticated;

CREATE OR REPLACE FUNCTION public.claim_device_account(p_device_id text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO public
AS $$
DECLARE v_current text; v_count integer; v_limit integer;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Anmeldung erforderlich.'; END IF;
  IF p_device_id IS NULL OR length(p_device_id)<16 OR length(p_device_id)>100 THEN
    RAISE EXCEPTION 'Ungültige Browser-Gerätekennung.';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtext(p_device_id));
  IF EXISTS(SELECT 1 FROM public.device_blocks WHERE device_id=p_device_id AND blocked=true) THEN
    RAISE EXCEPTION 'Dieses Gerät ist durch den Admin-Chef gesperrt.';
  END IF;
  SELECT device_id INTO v_current FROM public.profiles WHERE id=auth.uid() FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Profil wurde nicht gefunden.'; END IF;
  IF v_current IS NOT NULL THEN
    IF EXISTS(SELECT 1 FROM public.device_blocks WHERE device_id=v_current AND blocked=true) THEN
      RAISE EXCEPTION 'Das mit deinem Konto verknüpfte Gerät ist gesperrt.';
    END IF;
    RETURN jsonb_build_object('success',true,'already_linked',true);
  END IF;
  SELECT count(*) INTO v_count FROM public.profiles WHERE device_id=p_device_id;
  SELECT account_limit INTO v_limit FROM public.device_settings WHERE id=true;
  v_limit := coalesce(v_limit,2);
  IF v_count >= v_limit THEN
    RETURN jsonb_build_object('success',false,'message','Die Kontenbegrenzung für dieses Gerät wurde erreicht ('||v_limit||').');
  END IF;
  PERFORM set_config('app.claiming_device_account','on',true);
  UPDATE public.profiles SET device_id=p_device_id WHERE id=auth.uid();
  RETURN jsonb_build_object('success',true,'already_linked',false);
END;
$$;
REVOKE ALL ON FUNCTION public.claim_device_account(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.claim_device_account(text) TO authenticated;

CREATE OR REPLACE FUNCTION public.chef_set_device_block(p_device_id text,p_blocked boolean)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO public
AS $$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=auth.uid() AND is_admin_chef=true) THEN
    RAISE EXCEPTION 'Nur der Admin-Chef darf Geräte sperren.';
  END IF;
  IF p_device_id IS NULL OR length(p_device_id)<16 OR length(p_device_id)>100 THEN
    RAISE EXCEPTION 'Ungültige Gerätekennung.';
  END IF;
  INSERT INTO public.device_blocks(device_id,blocked,updated_at,updated_by)
  VALUES(p_device_id,coalesce(p_blocked,true),now(),auth.uid())
  ON CONFLICT(device_id) DO UPDATE SET blocked=excluded.blocked,updated_at=now(),updated_by=auth.uid();
  RETURN jsonb_build_object('success',true,'blocked',p_blocked);
END;
$$;

CREATE OR REPLACE FUNCTION public.chef_set_device_account_limit(p_limit integer)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO public
AS $$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=auth.uid() AND is_admin_chef=true) THEN
    RAISE EXCEPTION 'Nur der Admin-Chef darf das Kontenlimit ändern.';
  END IF;
  IF p_limit IS NULL OR p_limit<1 OR p_limit>20 THEN RAISE EXCEPTION 'Das Limit muss zwischen 1 und 20 liegen.'; END IF;
  INSERT INTO public.device_settings(id,account_limit,updated_at,updated_by)
  VALUES(true,p_limit,now(),auth.uid())
  ON CONFLICT(id) DO UPDATE SET account_limit=excluded.account_limit,updated_at=now(),updated_by=auth.uid();
  RETURN jsonb_build_object('success',true,'account_limit',p_limit);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_list_device_blocks()
RETURNS TABLE(device_id text,blocked boolean,reason text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO public
AS $$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=auth.uid() AND is_admin_chef=true) THEN
    RAISE EXCEPTION 'Nur der Admin-Chef darf Gerätesperren einsehen.';
  END IF;
  RETURN QUERY SELECT b.device_id,b.blocked,b.reason FROM public.device_blocks b ORDER BY b.updated_at DESC;
END;
$$;

REVOKE ALL ON FUNCTION public.chef_set_device_block(text,boolean) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.chef_set_device_account_limit(integer) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.admin_list_device_blocks() FROM PUBLIC,anon;

CREATE OR REPLACE FUNCTION public.admin_get_device_account_limit()
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO public
AS $$
DECLARE v_limit integer;
BEGIN
  IF NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=auth.uid() AND is_admin_chef=true) THEN
    RAISE EXCEPTION 'Nur der Admin-Chef darf das Kontenlimit einsehen.';
  END IF;
  SELECT account_limit INTO v_limit FROM public.device_settings WHERE id=true;
  RETURN coalesce(v_limit,2);
END;
$$;
REVOKE ALL ON FUNCTION public.admin_get_device_account_limit() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_get_device_account_limit() TO authenticated;

GRANT EXECUTE ON FUNCTION public.chef_set_device_block(text,boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.chef_set_device_account_limit(integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_list_device_blocks() TO authenticated;

-- 4) Geheimes Glücksfee-Event
CREATE TABLE IF NOT EXISTS public.casino_luckfee_events(
  id bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  selected_user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  starts_at timestamptz NOT NULL DEFAULT now(),
  ends_at timestamptz NOT NULL,
  created_by uuid REFERENCES public.profiles(id),
  stopped_at timestamptz
);
CREATE INDEX IF NOT EXISTS casino_luckfee_active_idx
  ON public.casino_luckfee_events(ends_at DESC) WHERE stopped_at IS NULL;
ALTER TABLE public.casino_luckfee_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.casino_luckfee_events FROM anon,authenticated;

CREATE OR REPLACE FUNCTION public.is_luckfee_active(p_user_id uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO public
AS $$
  SELECT EXISTS(
    SELECT 1 FROM public.casino_luckfee_events e
    WHERE e.selected_user_id=p_user_id AND e.stopped_at IS NULL
      AND e.starts_at<=now() AND e.ends_at>now()
  );
$$;
REVOKE ALL ON FUNCTION public.is_luckfee_active(uuid) FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.chef_start_luckfee(p_user_id uuid,p_hours integer DEFAULT 3)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO public
AS $$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=auth.uid() AND is_admin_chef=true) THEN
    RAISE EXCEPTION 'Nur der Admin-Chef darf die Glücksfee starten.';
  END IF;
  IF p_user_id IS NULL OR NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=p_user_id) THEN
    RAISE EXCEPTION 'Bitte eine gültige Person auswählen.';
  END IF;
  IF p_hours IS NULL OR p_hours<1 OR p_hours>24 THEN
    RAISE EXCEPTION 'Die Laufzeit muss zwischen 1 und 24 Stunden liegen.';
  END IF;
  UPDATE public.casino_luckfee_events SET stopped_at=now()
   WHERE stopped_at IS NULL AND ends_at>now();
  INSERT INTO public.casino_luckfee_events(selected_user_id,starts_at,ends_at,created_by)
  VALUES(p_user_id,now(),now()+make_interval(hours=>p_hours),auth.uid());
  RETURN jsonb_build_object('success',true,'ends_at',now()+make_interval(hours=>p_hours));
END;
$$;

CREATE OR REPLACE FUNCTION public.chef_stop_luckfee()
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO public
AS $$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM public.profiles WHERE id=auth.uid() AND is_admin_chef=true) THEN
    RAISE EXCEPTION 'Nur der Admin-Chef darf die Glücksfee beenden.';
  END IF;
  UPDATE public.casino_luckfee_events SET stopped_at=now()
   WHERE stopped_at IS NULL AND ends_at>now();
  RETURN jsonb_build_object('success',true);
END;
$$;
REVOKE ALL ON FUNCTION public.chef_start_luckfee(uuid,integer) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.chef_stop_luckfee() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.chef_start_luckfee(uuid,integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.chef_stop_luckfee() TO authenticated;

-- Coinflip: Standardchance 49 %, Glücksfee 72 % für die ausgewählte Person
CREATE OR REPLACE FUNCTION public.casino_coinflip(p_bet integer,p_choice text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO public,pg_temp
AS $$
DECLARE v_start jsonb; v_win boolean; v_result text; v_payout integer; v_points integer; v_uid uuid:=auth.uid(); v_chance numeric:=0.49;
BEGIN
  IF p_choice NOT IN ('heads','tails') THEN RAISE EXCEPTION 'Ungültige Auswahl.'; END IF;
  IF public.is_luckfee_active(v_uid) THEN v_chance:=0.72; END IF;
  v_start:=public.casino_start_round('coinflip',p_bet,jsonb_build_object('choice',p_choice));
  v_win:=random()<v_chance;
  v_result:=CASE WHEN v_win THEN p_choice WHEN p_choice='heads' THEN 'tails' ELSE 'heads' END;
  v_payout:=CASE WHEN v_win THEN p_bet*2 ELSE 0 END;
  v_points:=public.casino_finish_round((v_start->>'round_id')::uuid,v_payout);
  RETURN jsonb_build_object('result',v_result,'won',v_win,'payout',v_payout,'new_points',v_points);
END $$;

-- Roulette: bei Glücksfee besteht eine zusätzliche serverseitige Chance auf ein passendes Ergebnis.
CREATE OR REPLACE FUNCTION public.casino_roulette(p_bet integer,p_type text,p_value text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO public,pg_temp
AS $$
DECLARE
 v_red integer[]:=array[1,3,5,7,9,12,14,16,18,19,21,23,25,27,30,32,34,36];
 v_num integer;v_color text;v_mult integer;v_win boolean;v_start jsonb;v_payout integer;v_points integer;v_uid uuid:=auth.uid();v_bonus boolean:=false;
BEGIN
 IF p_type='color' AND p_value IN('red','black') THEN v_mult:=2;
 ELSIF p_type='parity' AND p_value IN('even','odd') THEN v_mult:=2;
 ELSIF p_type='half' AND p_value IN('low','high') THEN v_mult:=2;
 ELSIF p_type='dozen' AND p_value IN('1','2','3') THEN v_mult:=3;
 ELSIF p_type='number' AND (CASE WHEN p_value~'^[0-9]{1,2}$' THEN p_value::integer<=36 ELSE false END) THEN v_mult:=36;
 ELSE RAISE EXCEPTION 'Ungültige Roulette-Wette.'; END IF;
 v_start:=public.casino_start_round('roulette',p_bet,jsonb_build_object('type',p_type,'value',p_value));
 v_num:=floor(random()*37)::integer;
 IF public.is_luckfee_active(v_uid) AND random()<0.20 THEN
   v_bonus:=true;
   IF p_type='color' THEN
     SELECT n INTO v_num FROM generate_series(1,36) n WHERE ((n=ANY(v_red))=(p_value='red')) ORDER BY random() LIMIT 1;
   ELSIF p_type='parity' THEN
     SELECT n INTO v_num FROM generate_series(1,36) n WHERE (n%2=CASE WHEN p_value='even' THEN 0 ELSE 1 END) ORDER BY random() LIMIT 1;
   ELSIF p_type='half' THEN
     v_num:=CASE WHEN p_value='low' THEN floor(random()*18)::integer+1 ELSE floor(random()*18)::integer+19 END;
   ELSIF p_type='dozen' THEN
     v_num:=(p_value::integer-1)*12+floor(random()*12)::integer+1;
   ELSE v_num:=p_value::integer; END IF;
 END IF;
 v_color:=CASE WHEN v_num=0 THEN 'green' WHEN v_num=ANY(v_red) THEN 'red' ELSE 'black' END;
 v_win:=CASE p_type
   WHEN 'color' THEN v_num<>0 AND ((v_num=ANY(v_red))=(p_value='red'))
   WHEN 'parity' THEN v_num<>0 AND (v_num%2=CASE WHEN p_value='even' THEN 0 ELSE 1 END)
   WHEN 'half' THEN (p_value='low' AND v_num BETWEEN 1 AND 18) OR (p_value='high' AND v_num BETWEEN 19 AND 36)
   WHEN 'dozen' THEN v_num BETWEEN ((p_value::integer-1)*12+1) AND (p_value::integer*12)
   ELSE v_num=p_value::integer END;
 v_payout:=CASE WHEN v_win THEN p_bet*v_mult ELSE 0 END;
 v_points:=public.casino_finish_round((v_start->>'round_id')::uuid,v_payout);
 RETURN jsonb_build_object('number',v_num,'color',v_color,'won',v_win,'payout',v_payout,'new_points',v_points);
END $$;

-- Plinko: bei Glücksfee wird mit 20 % Bonuschance ein Randfach mit höherem Multiplikator getroffen.
CREATE OR REPLACE FUNCTION public.casino_plinko(p_bet integer,p_risk text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO public,pg_temp
AS $$
DECLARE
 v_mults numeric[];v_path integer[]:='{}';v_slot integer:=0;v_step integer;v_start jsonb;v_mult numeric;v_payout integer;v_points integer;i integer;v_uid uuid:=auth.uid();
BEGIN
 v_mults:=CASE p_risk WHEN 'low' THEN array[5.6,2,1.1,0.9,0.5,0.9,1.1,2,5.6]
 WHEN 'medium' THEN array[10,3,1.2,0.7,0.4,0.7,1.2,3,10]
 WHEN 'high' THEN array[25,4,1.5,0.3,0.2,0.3,1.5,4,25] ELSE NULL END;
 IF v_mults IS NULL THEN RAISE EXCEPTION 'Unbekannte Risikostufe.'; END IF;
 v_start:=public.casino_start_round('plinko',p_bet,jsonb_build_object('risk',p_risk));
 IF public.is_luckfee_active(v_uid) AND random()<0.20 THEN
   v_slot:=CASE WHEN random()<0.5 THEN 0 ELSE 8 END;
   FOR i IN 1..8 LOOP v_step:=CASE WHEN v_slot=0 THEN 0 ELSE 1 END;v_path:=v_path||v_step;END LOOP;
 ELSE
   FOR i IN 1..8 LOOP v_step:=CASE WHEN random()<0.5 THEN 0 ELSE 1 END;v_path:=v_path||v_step;v_slot:=v_slot+v_step;END LOOP;
 END IF;
 v_mult:=v_mults[v_slot+1];v_payout:=floor(p_bet*v_mult)::integer;
 v_points:=public.casino_finish_round((v_start->>'round_id')::uuid,v_payout);
 RETURN jsonb_build_object('path',to_jsonb(v_path),'slot',v_slot,'multiplier',v_mult,'payout',v_payout,'new_points',v_points);
END $$;

-- Mines: Glücksfee reduziert für die Eventperson die tatsächliche Minenzahl um eine (mindestens eine bleibt).
CREATE OR REPLACE FUNCTION public.casino_mines_start(p_bet integer,p_mines integer)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO public,pg_temp
AS $$
DECLARE v_uid uuid:=auth.uid();v_mines_arr integer[];v_start jsonb;v_effective integer;
BEGIN
 IF v_uid IS NULL THEN RAISE EXCEPTION 'Bitte anmelden.'; END IF;
 IF p_mines IS NULL OR p_mines<1 OR p_mines>20 THEN RAISE EXCEPTION 'Ungültige Minenanzahl.'; END IF;
 PERFORM 1 FROM public.profiles WHERE id=v_uid FOR UPDATE;
 PERFORM 1 FROM public.casino_rounds WHERE user_id=v_uid AND game='mines' AND status='open';
 IF FOUND THEN RAISE EXCEPTION 'Du hast noch eine laufende Mines-Runde.'; END IF;
 v_effective:=CASE WHEN public.is_luckfee_active(v_uid) THEN greatest(1,p_mines-1) ELSE p_mines END;
 SELECT array_agg(g) INTO v_mines_arr FROM (SELECT g FROM generate_series(0,24) g ORDER BY random() LIMIT v_effective) s;
 v_start:=public.casino_start_round('mines',p_bet,jsonb_build_object('mines',to_jsonb(v_mines_arr),'mine_count',v_effective,'revealed','[]'::jsonb));
 RETURN jsonb_build_object('round_id',v_start->>'round_id','new_points',(v_start->>'points')::integer,'mine_count',v_effective,
 'next_multiplier',public.casino_mines_multiplier(v_effective,1));
END $$;

-- RPC-Berechtigungen der bestehenden Casino-Funktionen bleiben auf authenticated begrenzt.
REVOKE ALL ON FUNCTION public.casino_coinflip(integer,text) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.casino_roulette(integer,text,text) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.casino_plinko(integer,text) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.casino_mines_start(integer,integer) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.casino_coinflip(integer,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.casino_roulette(integer,text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.casino_plinko(integer,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.casino_mines_start(integer,integer) TO authenticated;
