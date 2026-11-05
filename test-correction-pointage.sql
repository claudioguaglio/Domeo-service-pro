begin;
insert into domeo_private.shifts(id,team_id,client_id,worker_user_id,work_date,starts_at,service,planned_minutes,status,hourly_rate_snapshot,actual_started_at)
values('91000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000001','20000000-0000-4000-8000-000000000001','29cb5564-497a-4ddb-a7de-8449af3e43e0','2026-10-01','09:00','TEST oubli de fin',180,'confirmed',34,'2026-10-01T07:00:00Z'),
('91000000-0000-4000-8000-000000000002','10000000-0000-4000-8000-000000000001','20000000-0000-4000-8000-000000000001','29cb5564-497a-4ddb-a7de-8449af3e43e0','2026-10-02','09:00','TEST supplément en attente',180,'confirmed',34,null),
('91000000-0000-4000-8000-000000000003','10000000-0000-4000-8000-000000000001','20000000-0000-4000-8000-000000000001','29cb5564-497a-4ddb-a7de-8449af3e43e0','2026-10-01','10:00','TEST chevauchement',180,'confirmed',34,null);
insert into domeo_private.extra_requests(team_id,shift_id,description,estimated_minutes,status,requested_by)
values('10000000-0000-4000-8000-000000000001','91000000-0000-4000-8000-000000000002','TEST en attente',30,'pending','29cb5564-497a-4ddb-a7de-8449af3e43e0');
set local role authenticated;
do $test$
declare p jsonb;r jsonb;data jsonb;sh jsonb;
begin
 p:=jsonb_build_object('action','correct_clock','shift','91000000-0000-4000-8000-000000000001','version',1,'request',gen_random_uuid(),'started','2026-10-01T09:00:00','ended','2026-10-01T12:30:00','reason','Oubli de fin vérifié avec Emma.');
 perform set_config('request.jwt.claim.sub','29cb5564-497a-4ddb-a7de-8449af3e43e0',true);
 begin perform public.domeo_correct_clock(p);raise exception 'FAIL droit intervenante';exception when sqlstate '42501' then null;end;
 perform set_config('request.jwt.claim.sub','054ca94c-4792-4184-81ea-9a93ab09570b',true);
 begin perform public.domeo_correct_clock(p||jsonb_build_object('reason',''));raise exception 'FAIL motif vide';exception when sqlstate '22023' then null;end;
 begin perform public.domeo_correct_clock(p||jsonb_build_object('ended','2026-10-01T08:00:00'));raise exception 'FAIL fin avant début';exception when sqlstate '22023' then null;end;
 begin perform public.domeo_correct_clock(p||jsonb_build_object('ended','2026-10-03T12:30:00'));raise exception 'FAIL plus de 24h';exception when sqlstate '22023' then null;end;
 r:=public.domeo_correct_clock(p);
 if public.domeo_correct_clock(p)<>r then raise exception 'FAIL reprise';end if;
 begin perform public.domeo_correct_clock(p||jsonb_build_object('reason','Autre motif'));raise exception 'FAIL identifiant réutilisé';exception when sqlstate '22023' then null;end;
 begin perform public.domeo_correct_clock(p||jsonb_build_object('request',gen_random_uuid()));raise exception 'FAIL version ancienne';exception when sqlstate '40001' then null;end;
 data:=public.domeo_plan('{"from":"2026-10-01","to":"2026-11-01"}');
 select x into sh from jsonb_array_elements(data->'shifts') x where x->>'id'=p->>'shift';
 if sh->>'status'<>'completed' or (sh->>'actualMinutes')::int<>210 or (sh->>'amount')::numeric<>119 or jsonb_array_length(sh->'clockCorrections')<>1 or sh->'clockCorrections'->0->>'actor'<>'Carla (test)' then raise exception 'FAIL bilan ou historique : %',sh;end if;
 perform public.domeo_correct_clock(p||jsonb_build_object('shift','91000000-0000-4000-8000-000000000001','version',2,'request',gen_random_uuid(),'ended','2026-10-01T12:00:00','reason','Correction seconde vérifiée.'));
 begin perform public.domeo_correct_clock(p||jsonb_build_object('shift','91000000-0000-4000-8000-000000000003','request',gen_random_uuid(),'started','2026-10-01T11:00:00','ended','2026-10-01T13:00:00'));raise exception 'FAIL chevauchement';exception when sqlstate '22023' then null;end;
 begin perform public.domeo_correct_clock(p||jsonb_build_object('shift','91000000-0000-4000-8000-000000000002','request',gen_random_uuid(),'started','2026-10-02T09:00:00','ended','2026-10-02T12:30:00'));raise exception 'FAIL supplément en attente';exception when sqlstate '22023' then null;end;
 perform set_config('request.jwt.claim.sub','29cb5564-497a-4ddb-a7de-8449af3e43e0',true);
 data:=public.domeo_plan('{"from":"2026-10-01","to":"2026-11-01"}');
 select x into sh from jsonb_array_elements(data->'shifts') x where x->>'id'=p->>'shift';
 if sh ? 'amount' or sh ? 'rate' or (sh->>'actualMinutes')::int<>180 or jsonb_array_length(sh->'clockCorrections')<>2 or (sh->'clockCorrections'->1->'before'->>'minutes')::int<>210 then raise exception 'FAIL historique complet ou confidentialité';end if;
end $test$;
rollback;
select 'PASS corrections : droits, motif, dates, version, reprise, chevauchement, suppléments, bilan et historique. Tests annulés.' as resultat;
