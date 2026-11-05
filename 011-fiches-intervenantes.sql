-- Fiches privées : aucun compte créé, aucune invitation envoyée.
begin;
create table if not exists domeo_private.worker_profiles (
 id uuid primary key default gen_random_uuid(),team_id uuid not null references domeo_private.teams(id),user_id uuid,
 name text not null check(length(trim(name)) between 1 and 120),
 email text not null default '' check(length(email)<=254),phone text not null default '' check(length(phone)<=50),
 kind text not null default 'unspecified' check(kind in ('unspecified','employee','independent')),
 notes text not null default '' check(length(notes)<=4000),version bigint not null default 1,
 created_at timestamptz not null default now(),updated_at timestamptz not null default now(),
 unique(team_id,user_id),foreign key(team_id,user_id) references domeo_private.members(team_id,user_id)
);
create unique index if not exists worker_profiles_email_unique on domeo_private.worker_profiles(team_id,lower(email)) where email<>'';
alter table domeo_private.worker_profiles enable row level security;
revoke all on domeo_private.worker_profiles from public,anon,authenticated;
insert into domeo_private.worker_profiles(team_id,user_id,name)
select team_id,user_id,display_name from domeo_private.members where role='worker' on conflict(team_id,user_id) do nothing;

-- Enrichir uniquement la lecture du planning existant, sans remplacer sa logique.
do $migration$
declare src text;anchor text;
begin
 select pg_get_functiondef('public.domeo_plan(jsonb)'::regprocedure) into src;
 if position('workerProfiles' in src)=0 then
  if (select md5(trim(regexp_replace(prosrc,'\s+',' ','g'))) from pg_proc where oid='public.domeo_plan(jsonb)'::regprocedure)<>'001f560d62dcef2a185ec99ff1f080f3' then raise exception 'Version du planning différente de la sauvegarde : installation annulée.';end if;
  if position('clockCorrections' in src)=0 then raise exception 'Installe la migration 010 avant 011.';end if;
  anchor:='return jsonb_build_object(''role'',m.role';
  if position(anchor in src)=0 then raise exception 'Lecture du planning inattendue : installation annulée.';end if;
  src:=replace(src,anchor,$patch$return jsonb_build_object('workerProfiles',case when m.role='manager' then
   coalesce((select jsonb_agg(j order by name,id) from (
    select wp.name,wp.id,jsonb_build_object('id',wp.id,'userId',wp.user_id,'name',wp.name,'email',wp.email,'phone',wp.phone,'kind',wp.kind,'notes',wp.notes,'version',wp.version,
     'active',coalesce(wm.active,false),'openMissions',(select count(*) from domeo_private.shifts x where x.team_id=m.team_id and x.worker_user_id=wp.user_id and x.status='confirmed')) j
    from domeo_private.worker_profiles wp left join domeo_private.members wm on wm.team_id=wp.team_id and wm.user_id=wp.user_id
    where wp.team_id=m.team_id order by wp.name,wp.id limit 500) q),'[]'::jsonb) else '[]'::jsonb end) || jsonb_build_object('role',m.role$patch$);
  src:=replace(src,'and (m.role=''manager'' or sh.worker_user_id=m.user_id)',
   'and (m.role=''manager'' or sh.worker_user_id=m.user_id) and (nullif(p->>''worker'','''') is null or sh.worker_user_id=(p->>''worker'')::uuid)');
  src:=replace(src,'where sh.team_id=m.team_id and sh.work_date>=lo and sh.work_date<hi group by c.id,c.name,c.category',
   'where sh.team_id=m.team_id and sh.work_date>=lo and sh.work_date<hi and (nullif(p->>''worker'','''') is null or sh.worker_user_id=(p->>''worker'')::uuid) group by c.id,c.name,c.category');
  anchor:='elsif a in (''cancel'',''restore'') then';
  if position(anchor in src)=0 then raise exception 'Commande de rétablissement inattendue : installation annulée.';end if;
  src:=replace(src,anchor,$patch$elsif a in ('cancel','restore') then
   if a='restore' then
    perform 1 from domeo_private.members where team_id=m.team_id and user_id=s.worker_user_id and active and role='worker' for share;
    if not found then raise exception 'Réactive cette intervenante avant de rétablir la mission.' using errcode='22023';end if;
   end if;$patch$);
  execute src;
 end if;
end $migration$;

create or replace function public.domeo_workers(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path='' set statement_timeout='5s' set lock_timeout='2s' as $function$
declare m domeo_private.members; target domeo_private.members; w domeo_private.worker_profiles; cmd domeo_private.commands;
 a text:=p->>'action';rid uuid;fp text;result jsonb;entity uuid;nm text;em text;ph text;k text;nt text;
begin
 if octet_length(p::text)>10000 or a is null or a not in ('create_worker','update_worker','activate_worker','deactivate_worker') then raise exception 'Demande incorrecte.' using errcode='22023';end if;
 select * into m from domeo_private.members where user_id=auth.uid() and active and team_id='10000000-0000-4000-8000-000000000001' for share;
 if not found or m.role<>'manager' then raise exception 'Gestion réservée à Carla.' using errcode='42501';end if;
 rid:=(p->>'request')::uuid;if rid is null then raise exception 'Identifiant de reprise manquant.' using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended(m.user_id::text||rid::text,0));
 fp:=jsonb_build_array('workers-v1',p-'request')::text;
 select * into cmd from domeo_private.commands where user_id=m.user_id and request_id=rid;
 if found then
  if cmd.payload_hash<>fp then raise exception 'Identifiant déjà utilisé.' using errcode='22023';end if;return cmd.result;
 end if;
 if a<>'create_worker' then
  select * into w from domeo_private.worker_profiles where id=(p->>'worker')::uuid and team_id=m.team_id for update;
  if not found then raise exception 'Fiche inaccessible.' using errcode='42501';end if;
  if (p->>'version') is null or (p->>'version')::bigint<>w.version then raise exception 'Cette fiche a changé. Actualise avant de recommencer.' using errcode='40001';end if;
  entity:=w.id;
  if w.user_id is not null then
   select * into target from domeo_private.members where team_id=m.team_id and user_id=w.user_id for update;
   if not found or target.role<>'worker' then raise exception 'Compte intervenante inaccessible.' using errcode='42501';end if;
  end if;
 end if;
 if a in ('create_worker','update_worker') then
  nm:=trim(coalesce(p->>'name',''));em:=lower(trim(coalesce(p->>'email','')));ph:=trim(coalesce(p->>'phone',''));k:=coalesce(p->>'kind','unspecified');nt:=coalesce(p->>'notes','');
  if length(nm) not between 1 and 120 or length(em)>254 or (em<>'' and em!~'^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$') or length(ph)>50 or k not in ('unspecified','employee','independent') or length(nt)>4000 then raise exception 'Fiche incorrecte : vérifie le nom, l’e-mail et les coordonnées.' using errcode='22023';end if;
  if a='create_worker' then
   perform pg_advisory_xact_lock(hashtextextended('domeo-worker-create:'||m.team_id::text,0));
   if (select count(*) from domeo_private.worker_profiles where team_id=m.team_id)>=500 then raise exception 'Maximum de 500 fiches atteint.' using errcode='22023';end if;
   insert into domeo_private.worker_profiles(team_id,name,email,phone,kind,notes) values(m.team_id,nm,em,ph,k,nt) returning id into entity;
  else
   update domeo_private.worker_profiles set name=nm,email=em,phone=ph,kind=k,notes=nt,version=version+1,updated_at=now() where id=w.id;
   if w.user_id is not null then update domeo_private.members set display_name=nm where team_id=m.team_id and user_id=w.user_id;end if;
  end if;
 else
  if w.user_id is null then raise exception 'Cette fiche est en préparation. Le compte de connexion doit être rattaché avant activation.' using errcode='22023';end if;
  if target.active=(a='activate_worker') then raise exception 'Cette intervenante possède déjà ce statut.' using errcode='22023';end if;
  if a='deactivate_worker' and exists(select 1 from domeo_private.shifts where team_id=m.team_id and worker_user_id=w.user_id and status='confirmed') then raise exception 'Termine, réattribue ou annule ses missions encore ouvertes avant de désactiver son accès.' using errcode='22023';end if;
  update domeo_private.members set active=(a='activate_worker') where team_id=m.team_id and user_id=w.user_id;
  update domeo_private.worker_profiles set version=version+1,updated_at=now() where id=w.id;
 end if;
 insert into domeo_private.audit_events(team_id,actor_id,entity_id,operation) values(m.team_id,m.user_id,entity,'plan:'||a);
 result:=jsonb_build_object('ok',true,'id',entity);
 insert into domeo_private.commands(user_id,request_id,team_id,operation,payload_hash,result) values(m.user_id,rid,m.team_id,'plan:'||a,fp,result);
 return result;
exception when unique_violation then raise exception 'Une fiche utilise déjà cet e-mail de contact.' using errcode='22023';
end $function$;
revoke all on function public.domeo_workers(jsonb) from public,anon;
grant execute on function public.domeo_workers(jsonb) to authenticated;
notify pgrst,'reload schema';
commit;
