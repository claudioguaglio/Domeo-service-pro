-- Limiter l’ancienne API à sa seule prestation fictive.
begin;
create or replace function domeo_private.trial_snapshot() returns jsonb
language plpgsql security definer set search_path='' as $$
declare m domeo_private.members; result jsonb;
begin
 select * into m from domeo_private.members where user_id=auth.uid() and active and team_id='10000000-0000-4000-8000-000000000001';
 if not found then raise exception 'Accès à cet essai non autorisé.' using errcode='42501'; end if;
 select jsonb_build_object('role',m.role,'name',m.display_name,'shifts',coalesce(jsonb_agg(
  jsonb_build_object('id',s.id,'version',s.version,'date',s.work_date,'start',s.starts_at,'service',s.service,
   'client',c.name,'worker',w.display_name,'plannedMinutes',s.planned_minutes,'actualMinutes',s.actual_minutes,'status',s.status,
   'extra',jsonb_build_object('id',e.id,'description',e.description,'status',e.status,'estimatedMinutes',e.estimated_minutes,'actualMinutes',e.actual_minutes))
  || case when m.role='manager' then jsonb_build_object('amount',case when s.status='completed' then round(s.actual_minutes*c.hourly_rate/60,2) else 0 end) else '{}'::jsonb end
  order by s.work_date,s.starts_at),'[]'::jsonb)) into result
 from domeo_private.shifts s join domeo_private.clients c on c.id=s.client_id and c.team_id=s.team_id
 join domeo_private.members w on w.team_id=s.team_id and w.user_id=s.worker_user_id
 left join domeo_private.extra_requests e on e.shift_id=s.id and e.team_id=s.team_id and e.id='40000000-0000-4000-8000-000000000001'
 where s.id='30000000-0000-4000-8000-000000000001' and s.team_id=m.team_id and (m.role='manager' or s.worker_user_id=m.user_id);
 return result;
end $$;
revoke all on function domeo_private.trial_snapshot() from public,anon,authenticated;

create or replace function public.domeo_trial(p_action text default 'read',p_shift uuid default null,p_version bigint default null,p_request uuid default null,p_minutes integer default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare m domeo_private.members; s domeo_private.shifts; e domeo_private.extra_requests; cmd domeo_private.commands; fingerprint text; response jsonb; total_extra integer;
begin
 select * into m from domeo_private.members where user_id=auth.uid() and active and team_id='10000000-0000-4000-8000-000000000001' for share;
 if not found then raise exception 'Accès à cet essai non autorisé.' using errcode='42501'; end if;
 if p_action='read' then return domeo_private.trial_snapshot(); end if;
 if p_action is null or p_action not in ('approve','refuse','complete_extra','finish') or p_request is null or p_shift is null or p_version is null then raise exception 'Commande incomplète.' using errcode='22023'; end if;
 -- Sérialiser les nouvelles tentatives d'une même commande avant le contrôle de version.
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text||p_request::text,0));
 fingerprint:=jsonb_build_array(p_action,p_shift,p_version,p_minutes)::text;
 select * into cmd from domeo_private.commands where user_id=m.user_id and request_id=p_request;
 if found then
  if cmd.payload_hash<>fingerprint then raise exception 'Identifiant de commande déjà utilisé.' using errcode='22023'; end if;
  return domeo_private.trial_snapshot();
 end if;
 select * into s from domeo_private.shifts where id=p_shift and id='30000000-0000-4000-8000-000000000001' and team_id=m.team_id for update;
 if not found or (m.role='worker' and s.worker_user_id<>m.user_id) then raise exception 'Intervention inaccessible.' using errcode='42501'; end if;
 if s.version<>p_version then raise exception 'Cette intervention a changé. Actualise avant de réessayer.' using errcode='40001'; end if;
 if s.status not in ('confirmed','completed') then raise exception 'Intervention indisponible.' using errcode='22023'; end if;
 select * into e from domeo_private.extra_requests where shift_id=s.id and team_id=m.team_id and id='40000000-0000-4000-8000-000000000001' for update;
 if p_action in ('approve','refuse') then
  if m.role<>'manager' then raise exception 'Décision réservée à la responsable.' using errcode='42501'; end if;
  if e.id is null or e.status<>'pending' then raise exception 'Cette demande a déjà reçu une décision.' using errcode='22023'; end if;
  update domeo_private.extra_requests set status=case when p_action='approve' then 'approved' else 'refused' end,decided_by=m.user_id,decided_at=now(),version=version+1 where id=e.id;
 elsif p_action='complete_extra' then
  if m.role<>'worker' then raise exception 'Action réservée à l’intervenante attribuée.' using errcode='42501'; end if;
  if e.id is null or e.status<>'approved' or p_minutes is null or p_minutes not between 1 and 480 then raise exception 'Supplément non autorisé ou durée incorrecte.' using errcode='22023'; end if;
  update domeo_private.extra_requests set status='completed',actual_minutes=p_minutes,completed_at=now(),version=version+1 where id=e.id;
  -- Si la mission était déjà terminée, ajouter ce nouveau supplément une seule fois.
  if s.status='completed' then update domeo_private.shifts set actual_minutes=actual_minutes+p_minutes where id=s.id; end if;
 else
  if m.role<>'worker' then raise exception 'Action réservée à l’intervenante attribuée.' using errcode='42501'; end if;
  if s.status<>'confirmed' or p_minutes is null or p_minutes not between 1 and 1440 then raise exception 'Mission déjà terminée ou durée incorrecte.' using errcode='22023'; end if;
  select coalesce(sum(actual_minutes),0) into total_extra from domeo_private.extra_requests where shift_id=s.id and status='completed';
  if p_minutes<total_extra then raise exception 'La durée totale doit inclure le supplément effectué.' using errcode='22023'; end if;
  update domeo_private.shifts set status='completed',actual_minutes=p_minutes where id=s.id;
 end if;
 update domeo_private.shifts set version=version+1,updated_at=now() where id=s.id;
 insert into domeo_private.audit_events(team_id,actor_id,entity_id,operation) values(m.team_id,m.user_id,s.id,p_action);
 response:=domeo_private.trial_snapshot();
 insert into domeo_private.commands(user_id,request_id,team_id,operation,payload_hash,result) values(m.user_id,p_request,m.team_id,p_action,fingerprint,jsonb_build_object('ok',true));
 return response;
end $$;
revoke all on function public.domeo_trial(text,uuid,bigint,uuid,integer) from public,anon,authenticated;

grant execute on function public.domeo_trial(text,uuid,bigint,uuid,integer) to authenticated;
notify pgrst,'reload schema';
commit;
