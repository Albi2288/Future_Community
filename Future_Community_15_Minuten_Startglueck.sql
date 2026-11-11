-- Future Community: versteckter, moderater Casino-Startbonus
-- Gilt 15 Minuten ab Erstellung des Profils (profiles.created_at).
-- Der Bonus ist serverseitig und wird nicht in der Website angezeigt.
-- Glücksfee bleibt stärker und hat Vorrang.
-- Vor Ausführung bitte ein Datenbank-Backup erstellen.

BEGIN;

-- Interner Zeitfenster-Check. Für normale Benutzer nicht direkt aufrufbar.
CREATE OR REPLACE FUNCTION public.casino_is_new_account_bonus(p_user_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.profiles p
    WHERE p.id = p_user_id
      AND p.created_at IS NOT NULL
      AND p.created_at <= now()
      AND p.created_at > now() - interval '15 minutes'
  );
$$;
REVOKE ALL ON FUNCTION public.casino_is_new_account_bonus(uuid) FROM PUBLIC, anon, authenticated;

-- Coinflip: regulär 49 %, Startbonus 51,5 %, Glücksfee 72 %.
-- Auch mit Startbonus verliert man weiterhin häufig.
CREATE OR REPLACE FUNCTION public.casino_coinflip(p_bet integer, p_choice text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $$
DECLARE
  v_start jsonb;
  v_win boolean;
  v_result text;
  v_payout integer;
  v_points integer;
  v_uid uuid := auth.uid();
  v_chance numeric := 0.49;
BEGIN
  IF p_choice NOT IN ('heads', 'tails') THEN
    RAISE EXCEPTION 'Ungültige Auswahl.';
  END IF;

  IF public.is_luckfee_active(v_uid) THEN
    v_chance := 0.72;
  ELSIF public.casino_is_new_account_bonus(v_uid) THEN
    v_chance := 0.515;
  END IF;

  v_start := public.casino_start_round('coinflip', p_bet, jsonb_build_object('choice', p_choice));
  v_win := random() < v_chance;
  v_result := CASE WHEN v_win THEN p_choice
                   WHEN p_choice = 'heads' THEN 'tails' ELSE 'heads' END;
  v_payout := CASE WHEN v_win THEN p_bet * 2 ELSE 0 END;
  v_points := public.casino_finish_round((v_start ->> 'round_id')::uuid, v_payout);

  RETURN jsonb_build_object('result', v_result, 'won', v_win, 'payout', v_payout, 'new_points', v_points);
END;
$$;

-- Roulette: kleiner zusätzlicher Treffer-Reroll während der ersten 15 Minuten.
-- Glücksfee behält ihren deutlich stärkeren bisherigen 20-%-Reroll.
CREATE OR REPLACE FUNCTION public.casino_roulette(p_bet integer, p_type text, p_value text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $$
DECLARE
  v_red integer[] := array[1,3,5,7,9,12,14,16,18,19,21,23,25,27,30,32,34,36];
  v_num integer;
  v_color text;
  v_mult integer;
  v_win boolean;
  v_start jsonb;
  v_payout integer;
  v_points integer;
  v_uid uuid := auth.uid();
  v_bonus_chance numeric := 0;
BEGIN
  IF p_type = 'color' AND p_value IN ('red','black') THEN v_mult := 2;
  ELSIF p_type = 'parity' AND p_value IN ('even','odd') THEN v_mult := 2;
  ELSIF p_type = 'half' AND p_value IN ('low','high') THEN v_mult := 2;
  ELSIF p_type = 'dozen' AND p_value IN ('1','2','3') THEN v_mult := 3;
  ELSIF p_type = 'number'
    AND (CASE WHEN p_value ~ '^[0-9]{1,2}$' THEN p_value::integer <= 36 ELSE false END) THEN v_mult := 36;
  ELSE
    RAISE EXCEPTION 'Ungültige Roulette-Wette.';
  END IF;

  v_start := public.casino_start_round('roulette', p_bet, jsonb_build_object('type', p_type, 'value', p_value));
  v_num := floor(random() * 37)::integer;

  IF public.is_luckfee_active(v_uid) THEN
    v_bonus_chance := 0.20;
  ELSIF public.casino_is_new_account_bonus(v_uid) THEN
    v_bonus_chance := 0.03;
  END IF;

  IF v_bonus_chance > 0 AND random() < v_bonus_chance THEN
    IF p_type = 'color' THEN
      SELECT n INTO v_num FROM generate_series(1,36) n
      WHERE ((n = ANY(v_red)) = (p_value = 'red')) ORDER BY random() LIMIT 1;
    ELSIF p_type = 'parity' THEN
      SELECT n INTO v_num FROM generate_series(1,36) n
      WHERE (n % 2 = CASE WHEN p_value = 'even' THEN 0 ELSE 1 END)
      ORDER BY random() LIMIT 1;
    ELSIF p_type = 'half' THEN
      v_num := CASE WHEN p_value = 'low'
        THEN floor(random()*18)::integer + 1
        ELSE floor(random()*18)::integer + 19 END;
    ELSIF p_type = 'dozen' THEN
      v_num := (p_value::integer - 1) * 12 + floor(random()*12)::integer + 1;
    ELSE
      v_num := p_value::integer;
    END IF;
  END IF;

  v_color := CASE WHEN v_num = 0 THEN 'green'
                  WHEN v_num = ANY(v_red) THEN 'red' ELSE 'black' END;
  v_win := CASE p_type
    WHEN 'color' THEN v_num <> 0 AND ((v_num = ANY(v_red)) = (p_value = 'red'))
    WHEN 'parity' THEN v_num <> 0 AND (v_num % 2 = CASE WHEN p_value = 'even' THEN 0 ELSE 1 END)
    WHEN 'half' THEN (p_value = 'low' AND v_num BETWEEN 1 AND 18)
                  OR (p_value = 'high' AND v_num BETWEEN 19 AND 36)
    WHEN 'dozen' THEN v_num BETWEEN ((p_value::integer - 1) * 12 + 1) AND (p_value::integer * 12)
    ELSE v_num = p_value::integer
  END;

  v_payout := CASE WHEN v_win THEN p_bet * v_mult ELSE 0 END;
  v_points := public.casino_finish_round((v_start ->> 'round_id')::uuid, v_payout);
  RETURN jsonb_build_object('number', v_num, 'color', v_color, 'won', v_win, 'payout', v_payout, 'new_points', v_points);
END;
$$;

-- Plinko: 3 % kleine Chance auf ein Randfach während des Startbonus.
-- Glücksfee bleibt bei 20 %.
CREATE OR REPLACE FUNCTION public.casino_plinko(p_bet integer, p_risk text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $$
DECLARE
  v_mults numeric[];
  v_path integer[] := '{}';
  v_slot integer := 0;
  v_step integer;
  v_start jsonb;
  v_mult numeric;
  v_payout integer;
  v_points integer;
  v_bonus_chance numeric := 0;
  i integer;
  v_uid uuid := auth.uid();
BEGIN
  v_mults := CASE p_risk
    WHEN 'low' THEN array[5.6,2,1.1,0.9,0.5,0.9,1.1,2,5.6]
    WHEN 'medium' THEN array[10,3,1.2,0.7,0.4,0.7,1.2,3,10]
    WHEN 'high' THEN array[25,4,1.5,0.3,0.2,0.3,1.5,4,25]
    ELSE NULL
  END;
  IF v_mults IS NULL THEN RAISE EXCEPTION 'Unbekannte Risikostufe.'; END IF;

  v_start := public.casino_start_round('plinko', p_bet, jsonb_build_object('risk', p_risk));
  IF public.is_luckfee_active(v_uid) THEN
    v_bonus_chance := 0.20;
  ELSIF public.casino_is_new_account_bonus(v_uid) THEN
    v_bonus_chance := 0.03;
  END IF;

  IF v_bonus_chance > 0 AND random() < v_bonus_chance THEN
    v_slot := CASE WHEN random() < 0.5 THEN 0 ELSE 8 END;
    FOR i IN 1..8 LOOP
      v_step := CASE WHEN v_slot = 0 THEN 0 ELSE 1 END;
      v_path := v_path || v_step;
    END LOOP;
  ELSE
    FOR i IN 1..8 LOOP
      v_step := CASE WHEN random() < 0.5 THEN 0 ELSE 1 END;
      v_path := v_path || v_step;
      v_slot := v_slot + v_step;
    END LOOP;
  END IF;

  v_mult := v_mults[v_slot + 1];
  v_payout := floor(p_bet * v_mult)::integer;
  v_points := public.casino_finish_round((v_start ->> 'round_id')::uuid, v_payout);
  RETURN jsonb_build_object('path', to_jsonb(v_path), 'slot', v_slot, 'multiplier', v_mult, 'payout', v_payout, 'new_points', v_points);
END;
$$;

-- Mines: während der ersten 15 Minuten wird in 25 % der Runden eine Mine weniger platziert.
-- Glücksfee reduziert weiterhin jede Runde um eine Mine.
CREATE OR REPLACE FUNCTION public.casino_mines_start(p_bet integer, p_mines integer)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, pg_temp
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_mines_arr integer[];
  v_start jsonb;
  v_effective integer;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'Bitte anmelden.'; END IF;
  IF p_mines IS NULL OR p_mines < 1 OR p_mines > 20 THEN RAISE EXCEPTION 'Ungültige Minenanzahl.'; END IF;

  PERFORM 1 FROM public.profiles WHERE id = v_uid FOR UPDATE;
  PERFORM 1 FROM public.casino_rounds WHERE user_id = v_uid AND game = 'mines' AND status = 'open';
  IF FOUND THEN RAISE EXCEPTION 'Du hast noch eine laufende Mines-Runde.'; END IF;

  v_effective := p_mines;
  IF public.is_luckfee_active(v_uid) THEN
    v_effective := greatest(1, p_mines - 1);
  ELSIF public.casino_is_new_account_bonus(v_uid) AND random() < 0.25 THEN
    v_effective := greatest(1, p_mines - 1);
  END IF;

  SELECT array_agg(g) INTO v_mines_arr
  FROM (SELECT g FROM generate_series(0,24) g ORDER BY random() LIMIT v_effective) s;

  v_start := public.casino_start_round('mines', p_bet,
    jsonb_build_object('mines', to_jsonb(v_mines_arr), 'mine_count', v_effective, 'revealed', '[]'::jsonb));
  RETURN jsonb_build_object(
    'round_id', v_start ->> 'round_id',
    'new_points', (v_start ->> 'points')::integer,
    'mine_count', v_effective,
    'next_multiplier', public.casino_mines_multiplier(v_effective, 1)
  );
END;
$$;

-- Bestehende Berechtigungen der Casino-RPCs erhalten.
REVOKE ALL ON FUNCTION public.casino_coinflip(integer,text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.casino_roulette(integer,text,text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.casino_plinko(integer,text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.casino_mines_start(integer,integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.casino_coinflip(integer,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.casino_roulette(integer,text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.casino_plinko(integer,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.casino_mines_start(integer,integer) TO authenticated;

COMMIT;
