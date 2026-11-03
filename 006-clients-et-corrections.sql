-- Évolution additive : fiches clients, corrections du planning et tarif conservé par intervention.
begin;
alter table domeo_private.clients add column if not exists email text not null default '';
alter table domeo_private.clients add column if not exists home text not null default '';
alter table domeo_private.clients add column if not exists notes text not null default '';
alter table domeo_private.clients add column if not exists archived boolean not null default false;
alter table domeo_private.shifts add column if not exists hourly_rate_snapshot numeric(10,2);
update domeo_private.shifts s set hourly_rate_snapshot=c.hourly_rate from domeo_private.clients c where c.id=s.client_id and c.team_id=s.team_id and s.hourly_rate_snapshot is null;
alter table domeo_private.shifts alter column hourly_rate_snapshot set not null;
alter table domeo_private.shifts add constraint shift_rate_valid check (hourly_rate_snapshot between 0 and 10000);
create or replace function public.domeo_plan(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path='' set statement_timeout='5s' set lock_timeout='2s' as $$
declare
 m domeo_private.members; s domeo_private.shifts; e domeo_private.extra_requests;
 oldcmd domeo_private.commands; clientrow domeo_private.clients; rate_snapshot numeric;
 a text:=coalesce(p->>'action','read'); rid uuid; entity uuid; v bigint;
 lo date; hi date; pg integer; n integer; fp text; result jsonb;
 sid uuid; cid uuid; wid uuid; dt date; tm time; mins integer; descr text;
 rows jsonb; totals jsonb; clientlist jsonb; workerlist jsonb; cnt bigint;
begin
 if octet_length(p::text)>16000 then raise exception 'Demande trop volumineuse.' using errcode='22023'; end if;
 select * into m from domeo_private.members where user_id=auth.uid() and active
 and team_id='10000000-0000-4000-8000-000000000001' for share;
 if not found then raise exception 'Accès non autorisé.' using errcode='42501'; end if;
 if a='read' then
  lo:=coalesce((p->>'from')::date,date_trunc('month',current_date)::date);
  hi:=coalesce((p->>'to')::date,(lo+interval '1 month')::date);
  pg:=coalesce((p->>'page')::integer,0);
  if hi<=lo or hi-lo>31 or pg<0 or pg>10000 then raise exception 'Choisis une période de 31 jours maximum.' using errcode='22023'; end if;
  select count(*),jsonb_build_object('minutes',coalesce(sum(case when sh.status='completed' then sh.actual_minutes else 0 end),0),
   'completed',count(*) filter(where sh.status='completed')) || case when m.role='manager' then
   jsonb_build_object('amount',coalesce(sum(case when sh.status='completed' then round(sh.actual_minutes*sh.hourly_rate_snapshot/60,2) else 0 end),0)) else '{}'::jsonb end
  into cnt,totals from domeo_private.shifts sh join domeo_private.clients c on c.id=sh.client_id and c.team_id=sh.team_id
  where sh.team_id=m.team_id and sh.work_date>=lo and sh.work_date<hi and (m.role='manager' or sh.worker_user_id=m.user_id);
  select coalesce(jsonb_agg(j order by d,t,id),'[]'::jsonb) into rows from (
   select sh.work_date d,sh.starts_at t,sh.id,jsonb_build_object('id',sh.id,'version',sh.version,'date',sh.work_date,'start',sh.starts_at,
    'service',sh.service,'clientId',c.id,'client',c.name,'workerId',w.user_id,'worker',w.display_name,
    'address',c.address,'phone',c.phone,'home',c.home,'plannedMinutes',sh.planned_minutes,'actualMinutes',sh.actual_minutes,'status',sh.status,'note',sh.completion_note,
    'extras',coalesce((select jsonb_agg(jsonb_build_object('id',x.id,'description',x.description,'status',x.status,
     'estimatedMinutes',x.estimated_minutes,'actualMinutes',x.actual_minutes) order by x.created_at,x.id)
     from domeo_private.extra_requests x where x.team_id=sh.team_id and x.shift_id=sh.id),'[]'::jsonb))
    || case when m.role='manager' then jsonb_build_object('rate',sh.hourly_rate_snapshot,'amount',case when sh.status='completed' then round(sh.actual_minutes*sh.hourly_rate_snapshot/60,2) else 0 end) else '{}'::jsonb end j
   from domeo_private.shifts sh join domeo_private.clients c on c.id=sh.client_id and c.team_id=sh.team_id
   join domeo_private.members w on w.team_id=sh.team_id and w.user_id=sh.worker_user_id
   where sh.team_id=m.team_id and sh.work_date>=lo and sh.work_date<hi and (m.role='manager' or sh.worker_user_id=m.user_id)
   order by sh.work_date,sh.starts_at,sh.id limit 50 offset pg*50
  ) q;
  if m.role='manager' then
   select coalesce(jsonb_agg(jsonb_build_object('id',id,'version',version,'name',name,'category',category,'rate',hourly_rate,'address',address,'phone',phone,'email',email,'home',home,'notes',notes,'archived',archived) order by name,id),'[]'::jsonb)
   into clientlist from domeo_private.clients where team_id=m.team_id;
   select coalesce(jsonb_agg(jsonb_build_object('id',user_id,'name',display_name) order by display_name,user_id),'[]'::jsonb)
   into workerlist from domeo_private.members where team_id=m.team_id and role='worker' and active;
  end if;
  return jsonb_build_object('role',m.role,'name',m.display_name,'shifts',rows,'totals',totals,'count',cnt,'page',pg,'pageSize',50,
   'clients',coalesce(clientlist,'[]'::jsonb),'workers',coalesce(workerlist,'[]'::jsonb));
 end if;
 if a not in ('create_client','update_client','archive_client','restore_client','create_shift','update_shift','cancel','restore','request_extra','approve','refuse','complete_extra','finish','client_absent','worker_absent') then raise exception 'Action inconnue.' using errcode='22023'; end if;
 rid:=(p->>'request')::uuid;
 if rid is null then raise exception 'Identifiant de reprise manquant.' using errcode='22023'; end if;
 perform pg_advisory_xact_lock(hashtextextended(m.user_id::text||rid::text,0));
 fp:=jsonb_build_array('planning-v1',p-'request')::text;
 select * into oldcmd from domeo_private.commands where user_id=m.user_id and request_id=rid;
 if found then
  if oldcmd.payload_hash<>fp then raise exception 'Identifiant déjà utilisé pour un autre enregistrement.' using errcode='22023'; end if;
  return oldcmd.result;
 end if;
 if a in ('create_client','update_client','archive_client','restore_client','create_shift','update_shift','cancel','restore','approve','refuse') and m.role<>'manager' then raise exception 'Action réservée à la responsable.' using errcode='42501'; end if;
 if a in ('request_extra','complete_extra','finish','client_absent','worker_absent') and m.role<>'worker' then raise exception 'Action réservée à l’intervenante.' using errcode='42501'; end if;
 if a in ('create_client','update_client','archive_client','restore_client') then
  if a<>'create_client' then
   select * into clientrow from domeo_private.clients where id=(p->>'client')::uuid and team_id=m.team_id for update;
   if not found then raise exception 'Client inaccessible.' using errcode='42501'; end if;
   if (p->>'version') is null or (p->>'version')::bigint<>clientrow.version then raise exception 'Cette fiche client a changé. Actualise avant de recommencer.' using errcode='40001'; end if;
   entity:=clientrow.id;
  end if;
  if a in ('archive_client','restore_client') then
   if clientrow.archived=(a='archive_client') then raise exception 'Ce client possède déjà ce statut.' using errcode='22023';end if;
   update domeo_private.clients set archived=(a='archive_client'),version=version+1 where id=entity;
  else
  if length(trim(coalesce(p->>'name',''))) not between 1 and 120 or coalesce(p->>'category','') not in ('SAP','PRO')
   or (p->>'rate') is null or (p->>'rate')::numeric not between 0 and 10000
   or length(coalesce(p->>'address',''))>500 or length(coalesce(p->>'phone',''))>50
   or length(coalesce(p->>'email',''))>254 or length(coalesce(p->>'home',''))>200 or length(coalesce(p->>'notes',''))>4000 then raise exception 'Fiche client incorrecte.' using errcode='22023'; end if;
  if a='create_client' then
   insert into domeo_private.clients(team_id,name,category,hourly_rate,address,phone,email,home,notes)
   values(m.team_id,trim(p->>'name'),p->>'category',(p->>'rate')::numeric,coalesce(p->>'address',''),coalesce(p->>'phone',''),coalesce(p->>'email',''),coalesce(p->>'home',''),coalesce(p->>'notes','')) returning id into entity;
  else
   update domeo_private.clients set name=trim(p->>'name'),category=p->>'category',hourly_rate=(p->>'rate')::numeric,address=coalesce(p->>'address',''),phone=coalesce(p->>'phone',''),email=coalesce(p->>'email',''),home=coalesce(p->>'home',''),notes=coalesce(p->>'notes',''),version=version+1 where id=entity;
  end if;
  end if;
 elsif a in ('create_shift','update_shift') then
  if a='update_shift' then
   select * into s from domeo_private.shifts where id=(p->>'shift')::uuid and team_id=m.team_id for update;
   if not found then raise exception 'Intervention inaccessible.' using errcode='42501'; end if;
   if (p->>'version') is null or (p->>'version')::bigint<>s.version then raise exception 'Cette intervention a changé. Actualise avant de recommencer.' using errcode='40001'; end if;
   if s.status<>'confirmed' then raise exception 'Seules les interventions confirmées peuvent être modifiées.' using errcode='22023';end if;
  end if;
  cid:=(p->>'client')::uuid; wid:=(p->>'worker')::uuid; dt:=(p->>'date')::date; tm:=(p->>'start')::time; mins:=(p->>'minutes')::integer;
  descr:=trim(coalesce(p->>'service',''));
  if dt is null or tm is null or mins is null or mins not between 1 and 1440 or length(descr) not between 1 and 200 then raise exception 'Intervention incomplète.' using errcode='22023'; end if;
  select * into clientrow from domeo_private.clients where id=cid and team_id=m.team_id for share;
  if not found then raise exception 'Client inaccessible.' using errcode='42501'; end if;
  if clientrow.archived and (a='create_shift' or cid<>s.client_id) then raise exception 'Ce client est archivé. Rétablis sa fiche avant de créer une intervention.' using errcode='22023';end if;
  perform 1 from domeo_private.members where user_id=wid and team_id=m.team_id and active and role='worker' for share;
  if not found then raise exception 'Intervenante inaccessible.' using errcode='42501'; end if;
  if a='create_shift' then
   insert into domeo_private.shifts(team_id,client_id,worker_user_id,work_date,starts_at,service,planned_minutes,status,hourly_rate_snapshot)
   values(m.team_id,cid,wid,dt,tm,descr,mins,'confirmed',clientrow.hourly_rate) returning id into entity;
  else
   if (cid<>s.client_id or wid<>s.worker_user_id) and exists(select 1 from domeo_private.extra_requests where shift_id=s.id and team_id=m.team_id) then raise exception 'Cette intervention a des suppléments : conserve son client et son intervenante.' using errcode='22023';end if;
   update domeo_private.shifts set client_id=cid,worker_user_id=wid,work_date=dt,starts_at=tm,service=descr,planned_minutes=mins,
    hourly_rate_snapshot=case when cid=s.client_id then s.hourly_rate_snapshot else clientrow.hourly_rate end,version=version+1,updated_at=now() where id=s.id;
   entity:=s.id;
  end if;
 else
  sid:=(p->>'shift')::uuid; v:=(p->>'version')::bigint;
  select * into s from domeo_private.shifts where id=sid and team_id=m.team_id for update;
  if not found or (m.role='worker' and s.worker_user_id<>m.user_id) then raise exception 'Intervention inaccessible.' using errcode='42501'; end if;
  if v is null or v<>s.version then raise exception 'Cette intervention a changé. Actualise avant de recommencer.' using errcode='40001'; end if;
  entity:=s.id;
  if a in ('cancel','restore') then
   if (a='cancel' and s.status<>'confirmed') or (a='restore' and s.status<>'cancelled') then raise exception 'Ce changement de statut est impossible.' using errcode='22023'; end if;
   update domeo_private.shifts set status=case when a='cancel' then 'cancelled' else 'confirmed' end where id=s.id;
  elsif a in ('finish','client_absent','worker_absent') then
   if s.status<>'confirmed' then raise exception 'Cette intervention est déjà clôturée.' using errcode='22023'; end if;
   if length(coalesce(p->>'note',''))>1000 then raise exception 'Le commentaire est trop long.' using errcode='22023'; end if;
   if exists(select 1 from domeo_private.extra_requests where team_id=m.team_id and shift_id=s.id and status in ('pending','approved')) then
    raise exception 'Termine le traitement des suppléments avant de clôturer.' using errcode='22023'; end if;
   if a='finish' then
    mins:=(p->>'minutes')::integer;
    select coalesce(sum(actual_minutes),0) into n from domeo_private.extra_requests where team_id=m.team_id and shift_id=s.id and status='completed';
    if mins is null or mins not between 1 and 1440 or mins<n then raise exception 'Durée totale incorrecte : inclus les suppléments effectués.' using errcode='22023'; end if;
    update domeo_private.shifts set status='completed',actual_minutes=mins,completion_note=coalesce(p->>'note','') where id=s.id;
   else
    if exists(select 1 from domeo_private.extra_requests where team_id=m.team_id and shift_id=s.id and status='completed') then raise exception 'Un supplément a été effectué : vérifie la durée réalisée.' using errcode='22023'; end if;
    if length(trim(coalesce(p->>'note','')))=0 then raise exception 'Indique le motif de l’absence.' using errcode='22023'; end if;
    update domeo_private.shifts set status=a,actual_minutes=null,completion_note=p->>'note' where id=s.id;
   end if;
  elsif a='request_extra' then
   if s.status<>'confirmed' then raise exception 'La prestation est clôturée.' using errcode='22023'; end if;
   mins:=(p->>'minutes')::integer; descr:=trim(coalesce(p->>'description',''));
   if mins is null or mins not between 1 and 480 or length(descr) not between 1 and 4000 then raise exception 'Description ou durée incorrecte.' using errcode='22023'; end if;
   select count(*) into n from domeo_private.extra_requests where team_id=m.team_id and shift_id=s.id;
   if n>=20 then raise exception 'Maximum de 20 demandes atteint pour cette prestation.' using errcode='22023'; end if;
   insert into domeo_private.extra_requests(team_id,shift_id,description,estimated_minutes,status,requested_by)
   values(m.team_id,s.id,descr,mins,'pending',m.user_id);
  else
   if s.status not in ('confirmed','completed') then raise exception 'Prestation indisponible.' using errcode='22023'; end if;
   select * into e from domeo_private.extra_requests where id=(p->>'extra')::uuid and team_id=m.team_id and shift_id=s.id for update;
   if not found then raise exception 'Supplément inaccessible.' using errcode='42501'; end if;
   if a in ('approve','refuse') then
    if e.status<>'pending' then raise exception 'Demande déjà traitée.' using errcode='22023'; end if;
    update domeo_private.extra_requests set status=case when a='approve' then 'approved' else 'refused' end,decided_by=m.user_id,decided_at=now(),version=version+1 where id=e.id;
   else
    mins:=(p->>'minutes')::integer;
    if e.status<>'approved' or mins is null or mins not between 1 and 480 then raise exception 'Supplément non autorisé ou durée incorrecte.' using errcode='22023'; end if;
    update domeo_private.extra_requests set status='completed',actual_minutes=mins,completed_at=now(),version=version+1 where id=e.id;
    if s.status='completed' then update domeo_private.shifts set actual_minutes=actual_minutes+mins where id=s.id; end if;
   end if;
  end if;
  update domeo_private.shifts set version=version+1,updated_at=now() where id=s.id;
 end if;
 insert into domeo_private.audit_events(team_id,actor_id,entity_id,operation) values(m.team_id,m.user_id,entity,'plan:'||a);
 result:=jsonb_build_object('ok',true,'id',entity);
 insert into domeo_private.commands(user_id,request_id,team_id,operation,payload_hash,result) values(m.user_id,rid,m.team_id,'plan:'||a,fp,result);
 return result;
end $$;
revoke all on function public.domeo_plan(jsonb) from public,anon;
grant execute on function public.domeo_plan(jsonb) to authenticated;
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
  || case when m.role='manager' then jsonb_build_object('amount',case when s.status='completed' then round(s.actual_minutes*s.hourly_rate_snapshot/60,2) else 0 end) else '{}'::jsonb end
  order by s.work_date,s.starts_at),'[]'::jsonb)) into result
 from domeo_private.shifts s join domeo_private.clients c on c.id=s.client_id and c.team_id=s.team_id
 join domeo_private.members w on w.team_id=s.team_id and w.user_id=s.worker_user_id
 left join domeo_private.extra_requests e on e.shift_id=s.id and e.team_id=s.team_id and e.id='40000000-0000-4000-8000-000000000001'
 where s.id='30000000-0000-4000-8000-000000000001' and s.team_id=m.team_id and (m.role='manager' or s.worker_user_id=m.user_id);
 return result;
end $$;
revoke all on function domeo_private.trial_snapshot() from public,anon,authenticated;


notify pgrst,'reload schema';
commit;
