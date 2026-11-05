-- À lancer après 009 dans l'éditeur SQL Supabase. Toutes les écritures sont annulées.
begin;
insert into domeo_private.shifts(id,team_id,client_id,worker_user_id,work_date,starts_at,service,planned_minutes,status,hourly_rate_snapshot)
values ('90000000-0000-4000-8000-000000000009','10000000-0000-4000-8000-000000000001','20000000-0000-4000-8000-000000000001','29cb5564-497a-4ddb-a7de-8449af3e43e0',(statement_timestamp() at time zone 'Europe/Paris')::date,'09:00','TEST pointage fictif',180,'confirmed',34);
set local role authenticated;
do $$
declare p jsonb;r jsonb;r2 jsonb;v integer;
begin
 perform set_config('request.jwt.claim.sub','29cb5564-497a-4ddb-a7de-8449af3e43e0',true);
 p:=jsonb_build_object('action','finish','shift','90000000-0000-4000-8000-000000000009','version',1,'request',gen_random_uuid(),'minutes',999);
 begin perform public.domeo_plan(p);raise exception 'FAIL fin sans début';exception when sqlstate '22023' then null;end;
 p:=jsonb_build_object('action','start','shift','90000000-0000-4000-8000-000000000009','version',1,'request',gen_random_uuid());
 r:=public.domeo_plan(p);r2:=public.domeo_plan(p);
 if r<>r2 then raise exception 'FAIL reprise début';end if;
 begin perform public.domeo_plan(p||jsonb_build_object('request',gen_random_uuid()));raise exception 'FAIL version ancienne';exception when sqlstate '40001' then null;end;
 perform set_config('request.jwt.claim.sub','054ca94c-4792-4184-81ea-9a93ab09570b',true);
 begin perform public.domeo_plan(jsonb_build_object('action','cancel','shift','90000000-0000-4000-8000-000000000009','version',2,'request',gen_random_uuid()));raise exception 'FAIL annulation pointée';exception when sqlstate '22023' then null;end;
end $$;
reset role;
-- Simuler 3 h 30 écoulées sans attendre et sans changer les données durables.
update domeo_private.shifts set actual_started_at=statement_timestamp()-interval '210 minutes' where id='90000000-0000-4000-8000-000000000009';
set local role authenticated;
do $$
declare p jsonb;r jsonb;rowdata jsonb;lo date;hi date;
begin
 perform set_config('request.jwt.claim.sub','29cb5564-497a-4ddb-a7de-8449af3e43e0',true);
 p:=jsonb_build_object('action','finish','shift','90000000-0000-4000-8000-000000000009','version',2,'request',gen_random_uuid(),'minutes',999);
 r:=public.domeo_plan(p);
 if public.domeo_plan(p)<>r then raise exception 'FAIL reprise fin';end if;
 lo:=date_trunc('month',statement_timestamp() at time zone 'Europe/Paris')::date;hi:=(lo+interval '1 month')::date;
 r:=public.domeo_plan(jsonb_build_object('from',lo,'to',hi));
 select x into rowdata from jsonb_array_elements(r->'shifts') x where x->>'id'='90000000-0000-4000-8000-000000000009';
 if rowdata is null or rowdata->>'status'<>'completed' or (rowdata->>'actualMinutes')::int not between 210 and 211 or (rowdata->>'overtimeMinutes')::int not between 30 and 31 or rowdata->>'actualEndedAt' is null then raise exception 'FAIL durée/horaires/statut : %',rowdata;end if;
 if rowdata ? 'amount' then raise exception 'FAIL montant visible intervenante';end if;
end $$;
rollback;
select 'PASS pointage serveur, reprise, version, protection annulation, durée calculée et confidentialité. Données de test annulées.' as resultat;
