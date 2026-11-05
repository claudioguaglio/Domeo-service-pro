-- Extension de 009 : correction réservée à la responsable, avec historique.
begin;
alter table domeo_private.shifts add column if not exists clock_corrections jsonb not null default '[]'::jsonb;

do $migration$
declare src text; body text;
begin
 select pg_get_functiondef(oid),prosrc into src,body from pg_proc where oid='public.domeo_plan(jsonb)'::regprocedure;
 if position('clockCorrections' in body)=0 then
  if md5(trim(regexp_replace(body,'\s+',' ','g')))<>'3f1c5d7256641926d39afbb878571bf9' then raise exception 'Version serveur inattendue : aucune modification appliquée.';end if;
  src:=replace(src,'''actualStartedAt'',sh.actual_started_at','''clockCorrections'',sh.clock_corrections,''actualStartedAt'',sh.actual_started_at');
  execute src;
 end if;
end $migration$;

create or replace function public.domeo_correct_clock(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path='' set statement_timeout='5s' set lock_timeout='2s' as $function$
declare
 m domeo_private.members; s domeo_private.shifts; cmd domeo_private.commands;
 rid uuid; worker_id uuid; fp text; result jsonb; start_local timestamp; end_local timestamp;
 started timestamptz; ended timestamptz; mins integer; extra_mins integer; reason text; entry jsonb;
begin
 if octet_length(p::text)>8000 or coalesce(p->>'action','')<>'correct_clock' then raise exception 'Demande incorrecte.' using errcode='22023';end if;
 select * into m from domeo_private.members where user_id=auth.uid() and active and team_id='10000000-0000-4000-8000-000000000001' for share;
 if not found or m.role<>'manager' then raise exception 'Correction réservée à Carla.' using errcode='42501';end if;
 rid:=(p->>'request')::uuid;
 if rid is null then raise exception 'Identifiant de reprise manquant.' using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended(m.user_id::text||rid::text,0));
 fp:=jsonb_build_array('clock-correction-v1',p-'request')::text;
 select * into cmd from domeo_private.commands where user_id=m.user_id and request_id=rid;
 if found then
  if cmd.payload_hash<>fp then raise exception 'Identifiant déjà utilisé.' using errcode='22023';end if;
  return cmd.result;
 end if;
 select worker_user_id into worker_id from domeo_private.shifts where id=(p->>'shift')::uuid and team_id=m.team_id;
 if not found then raise exception 'Mission inaccessible.' using errcode='42501';end if;
 perform pg_advisory_xact_lock(hashtextextended('domeo-clock:'||m.team_id::text||worker_id::text,0));
 select * into s from domeo_private.shifts where id=(p->>'shift')::uuid and team_id=m.team_id for update;
 if not found then raise exception 'Mission inaccessible.' using errcode='42501';end if;
 if (p->>'version') is null or (p->>'version')::bigint<>s.version then raise exception 'Cette mission a changé. Actualise avant de corriger.' using errcode='40001';end if;
 if s.status not in ('confirmed','completed') then raise exception 'Une mission annulée ou absente ne peut pas être corrigée par pointage.' using errcode='22023';end if;
 reason:=trim(coalesce(p->>'reason',''));
 if length(reason) not between 5 and 1000 then raise exception 'Indique un motif de correction de 5 à 1 000 caractères.' using errcode='22023';end if;
 if coalesce(p->>'started','')!~'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2})?$' or coalesce(p->>'ended','')!~'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2})?$' then raise exception 'Renseigne les dates et heures de début et de fin, heure de Paris.' using errcode='22023';end if;
 start_local:=(p->>'started')::timestamp;end_local:=(p->>'ended')::timestamp;
 started:=start_local at time zone 'Europe/Paris';ended:=end_local at time zone 'Europe/Paris';
 if (started at time zone 'Europe/Paris')<>start_local or (ended at time zone 'Europe/Paris')<>end_local
 or ((started-interval '1 hour') at time zone 'Europe/Paris')=start_local or ((started+interval '1 hour') at time zone 'Europe/Paris')=start_local
 or ((ended-interval '1 hour') at time zone 'Europe/Paris')=end_local or ((ended+interval '1 hour') at time zone 'Europe/Paris')=end_local then raise exception 'Heure ambiguë ou inexistante lors du changement d’heure : contacte le support.' using errcode='22023';end if;
 if start_local::date<>s.work_date or ended<=started or ended-started>interval '24 hours' or ended>statement_timestamp() then raise exception 'Horaires incorrects : début le jour prévu, fin après le début, durée de 24 h maximum et aucune heure future.' using errcode='22023';end if;
 if exists(select 1 from domeo_private.extra_requests where shift_id=s.id and team_id=m.team_id and status in ('pending','approved')) then raise exception 'Traite les suppléments avant de corriger et clôturer la mission.' using errcode='22023';end if;
 -- Le verrou de pointage a été pris avant le verrou de mission, comme pour start.
 if exists(select 1 from domeo_private.shifts x where x.team_id=m.team_id and x.worker_user_id=s.worker_user_id and x.id<>s.id and x.status in ('confirmed','completed') and x.actual_started_at is not null
 and x.actual_started_at<ended and coalesce(x.actual_ended_at,'infinity'::timestamptz)>started) then raise exception 'Ces horaires chevauchent une autre mission pointée.' using errcode='22023';end if;
 mins:=greatest(1,ceil(extract(epoch from (ended-started))/60)::integer);
 select coalesce(sum(actual_minutes),0) into extra_mins from domeo_private.extra_requests where shift_id=s.id and team_id=m.team_id and status='completed';
 if mins<extra_mins then raise exception 'La durée totale doit inclure les suppléments effectués.' using errcode='22023';end if;
 entry:=jsonb_build_object('at',statement_timestamp(),'actor',m.display_name,'actorId',m.user_id,'reason',reason,
 'before',jsonb_build_object('started',s.actual_started_at,'ended',s.actual_ended_at,'minutes',s.actual_minutes,'status',s.status),
 'after',jsonb_build_object('started',started,'ended',ended,'minutes',mins,'status','completed'));
 update domeo_private.shifts set actual_started_at=started,actual_ended_at=ended,actual_minutes=mins,status='completed',clock_corrections=clock_corrections||jsonb_build_array(entry),version=version+1,updated_at=now() where id=s.id;
 insert into domeo_private.audit_events(team_id,actor_id,entity_id,operation) values(m.team_id,m.user_id,s.id,'plan:correct_clock');
 result:=jsonb_build_object('ok',true,'id',s.id);
 insert into domeo_private.commands(user_id,request_id,team_id,operation,payload_hash,result) values(m.user_id,rid,m.team_id,'plan:correct_clock',fp,result);
 return result;
end $function$;
revoke all on function public.domeo_correct_clock(jsonb) from public,anon;
grant execute on function public.domeo_correct_clock(jsonb) to authenticated;
notify pgrst,'reload schema';
commit;
