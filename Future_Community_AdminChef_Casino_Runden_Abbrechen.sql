-- Future Community: Admin-Chef kann alle aktuell offenen Casino-Runden abbrechen
-- und den jeweiligen ursprünglichen Einsatz vollständig an den Spieler zurückzahlen.
-- Abgeschlossene Runden bleiben unverändert.

create or replace function public.chef_cancel_all_casino_rounds()
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_admin uuid := auth.uid();
  v_round record;
  v_cancelled integer := 0;
  v_refunded bigint := 0;
  v_new_points integer;
begin
  if v_admin is null then
    raise exception 'Bitte anmelden.';
  end if;

  if not exists (
    select 1
      from public.profiles p
     where p.id = v_admin
       and coalesce(p.is_admin_chef, false) = true
  ) then
    raise exception 'Nur der Admin-Chef darf alle Casino-Runden abbrechen.';
  end if;

  -- Gleiche Sperr-Reihenfolge wie beim Start/Abschluss einer Runde:
  -- zuerst Profile (sortiert), danach offene Runden. So werden parallele
  -- Einsätze/Abschlüsse sauber serialisiert und Einsätze nicht doppelt erstattet.
  perform 1
    from public.profiles p
   order by p.id
   for update;

  perform set_config('app.points_change_allowed', 'on', true);

  for v_round in
    select r.id, r.user_id, r.bet
      from public.casino_rounds r
     where r.status = 'open'
     order by r.created_at, r.id
     for update
  loop
    update public.profiles p
       set points = coalesce(p.points, 0) + v_round.bet
     where p.id = v_round.user_id
     returning p.points into v_new_points;

    if not found then
      raise exception 'Profil für eine offene Casino-Runde wurde nicht gefunden. Die Aktion wurde vollständig zurückgerollt.';
    end if;

    update public.casino_rounds r
       set payout = v_round.bet,
           status = 'done',
           finished_at = now(),
           state = coalesce(r.state, '{}'::jsonb) || jsonb_build_object(
             'cancelled_by_admin_chef', true,
             'cancelled_by_admin_chef_at', now(),
             'cancelled_by_admin_chef_id', v_admin
           )
     where r.id = v_round.id
       and r.status = 'open';

    if found then
      v_cancelled := v_cancelled + 1;
      v_refunded := v_refunded + v_round.bet;
    else
      -- Defensive fallback: normalerweise durch FOR UPDATE nicht erreichbar.
      -- Fehler erzwingt Rollback statt einer nicht zugeordneten Erstattung.
      raise exception 'Eine Casino-Runde wurde parallel verändert. Die Aktion wurde vollständig zurückgerollt.';
    end if;
  end loop;

  perform set_config('app.points_change_allowed', 'off', true);

  return jsonb_build_object(
    'success', true,
    'cancelled_rounds', v_cancelled,
    'refunded_xp', v_refunded
  );
end
$function$;

revoke all on function public.chef_cancel_all_casino_rounds() from public, anon;
grant execute on function public.chef_cancel_all_casino_rounds() to authenticated;
