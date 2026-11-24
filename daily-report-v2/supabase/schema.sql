-- DAYLOG: separate tables; does not modify the existing daily_tasks app.
create schema if not exists private;
create table public.dr_profiles (
 id uuid primary key references auth.users(id) on delete cascade,
 display_name text not null check(length(display_name) between 1 and 80),
 department text not null default '' check(length(department)<=80),
 role text not null default 'employee' check(role in ('employee','manager')),
 created_at timestamptz not null default now()
);
alter table public.dr_profiles enable row level security;
create function private.dr_is_manager() returns boolean language sql stable security definer set search_path='' as $$
 select auth.uid() is not null and exists(select 1 from public.dr_profiles p join auth.users u on u.id=p.id where p.id=auth.uid() and p.role='manager' and u.email_confirmed_at is not null);
$$;
revoke all on function private.dr_is_manager() from public;
grant usage on schema private to authenticated;
grant execute on function private.dr_is_manager() to authenticated;
create policy dr_profiles_read on public.dr_profiles for select to authenticated using(id=(select auth.uid()) or (select private.dr_is_manager()));
grant select on public.dr_profiles to authenticated;
create function private.dr_profile_setup() returns trigger language plpgsql security definer set search_path='' as $$
begin
 insert into public.dr_profiles(id,display_name,department,role) values(new.id,left(coalesce(nullif(btrim(new.raw_user_meta_data->>'display_name'),''),split_part(new.email,'@',1),'사용자'),80),left(coalesce(new.raw_user_meta_data->>'department',''),80),case when lower(new.email)='topjjk@gmail.com' and new.email_confirmed_at is not null then 'manager' else 'employee' end) on conflict(id) do nothing;
 if lower(new.email)='topjjk@gmail.com' and new.email_confirmed_at is not null then update public.dr_profiles set role='manager' where id=new.id; end if;
 return new;
end; $$;
revoke all on function private.dr_profile_setup() from public;
create trigger dr_user_profile after insert or update of email_confirmed_at on auth.users for each row execute function private.dr_profile_setup();
insert into public.dr_profiles(id,display_name,department,role) select id,left(coalesce(nullif(btrim(raw_user_meta_data->>'display_name'),''),split_part(email,'@',1),'사용자'),80),left(coalesce(raw_user_meta_data->>'department',''),80),case when lower(email)='topjjk@gmail.com' and email_confirmed_at is not null then 'manager' else 'employee' end from auth.users on conflict(id) do nothing;

create table public.dr_reports (
 id uuid primary key default gen_random_uuid(), author_id uuid not null default auth.uid() references public.dr_profiles(id),
 author_name text not null default '', department text not null default '',
 report_date date not null default (now() at time zone 'Asia/Seoul')::date,
 title text not null check(length(btrim(title)) between 1 and 160),
 today_work text not null default '' check(length(today_work)<=20000),
 ongoing_work text not null default '' check(length(ongoing_work)<=20000),
 issues text not null default '' check(length(issues)<=20000), actions text not null default '' check(length(actions)<=20000),
 tomorrow_plan text not null default '' check(length(tomorrow_plan)<=20000),
 status text not null default 'draft' check(status in ('draft','submitted','returned','approved')),
 review_note text not null default '' check(length(review_note)<=5000),
 reviewed_by uuid references public.dr_profiles(id),reviewed_at timestamptz,submitted_at timestamptz,
 version integer not null default 1,created_at timestamptz not null default now(),updated_at timestamptz not null default now()
);
create index dr_reports_author_date on public.dr_reports(author_id,report_date desc);
create index dr_reports_status on public.dr_reports(status,report_date desc);
create index dr_reports_reviewer on public.dr_reports(reviewed_by);
alter table public.dr_reports enable row level security;
create policy dr_reports_read on public.dr_reports for select to authenticated using(author_id=(select auth.uid()) or (status<>'draft' and (select private.dr_is_manager())));
create policy dr_reports_create on public.dr_reports for insert to authenticated with check(author_id=(select auth.uid()) and status='draft');
create policy dr_reports_edit on public.dr_reports for update to authenticated using((author_id=(select auth.uid()) and status in ('draft','returned')) or (status='submitted' and author_id<>(select auth.uid()) and (select private.dr_is_manager()))) with check(author_id=(select auth.uid()) or (status in ('approved','returned') and (select private.dr_is_manager())));
grant select,insert,update on public.dr_reports to authenticated;
create function private.dr_report_guard() returns trigger language plpgsql security invoker set search_path='' as $$
declare actor uuid:=auth.uid();
begin
 if actor is null then raise exception '로그인이 필요합니다.'; end if;
 if tg_op='INSERT' then
  if new.author_id<>actor or new.status<>'draft' then raise exception '본인의 임시 보고서만 생성할 수 있습니다.'; end if;
  select display_name,department into new.author_name,new.department from public.dr_profiles where id=actor;
  new.version:=1;new.created_at:=now();new.review_note:='';new.reviewed_by:=null;new.reviewed_at:=null;new.submitted_at:=null;
 else
  if new.id<>old.id or new.author_id<>old.author_id then raise exception '작성자는 변경할 수 없습니다.'; end if;
  if old.author_id=actor then
   if old.status not in ('draft','returned') or new.status not in ('draft','submitted') then raise exception '현재 상태에서는 수정할 수 없습니다.'; end if;
   new.review_note:=old.review_note;new.reviewed_by:=old.reviewed_by;new.reviewed_at:=old.reviewed_at;
   if new.status='submitted' then
    if length(btrim(new.today_work))=0 then raise exception '오늘 한 일을 입력해 주세요.'; end if;
    new.submitted_at:=now();new.reviewed_by:=null;new.reviewed_at:=null;
   else new.submitted_at:=old.submitted_at; end if;
  elsif private.dr_is_manager() then
   if old.status<>'submitted' or new.status not in ('approved','returned') then raise exception '제출된 보고서만 검토할 수 있습니다.'; end if;
   if (to_jsonb(new)-array['status','review_note','reviewed_by','reviewed_at','updated_at','version']) is distinct from (to_jsonb(old)-array['status','review_note','reviewed_by','reviewed_at','updated_at','version']) then raise exception '관리자는 보고서 원문을 변경할 수 없습니다.'; end if;
   if new.status='returned' and length(btrim(new.review_note))=0 then raise exception '보완 요청 사유를 입력해 주세요.'; end if;
   new.reviewed_by:=actor;new.reviewed_at:=now();
  else raise exception '접근 권한이 없습니다.';end if;
  new.author_name:=old.author_name;new.department:=old.department;new.created_at:=old.created_at;new.version:=old.version+1;
 end if;
 new.updated_at:=now();return new;
end; $$;
revoke all on function private.dr_report_guard() from public;
create trigger dr_report_before before insert or update on public.dr_reports for each row execute function private.dr_report_guard();

create table public.dr_report_events(id uuid primary key default gen_random_uuid(),report_id uuid not null references public.dr_reports(id) on delete cascade,actor_id uuid not null references public.dr_profiles(id),status text not null,note text not null default '',created_at timestamptz not null default now());
create index dr_report_events_report on public.dr_report_events(report_id,created_at);
create index dr_report_events_actor on public.dr_report_events(actor_id);
alter table public.dr_report_events enable row level security;
create policy dr_events_read on public.dr_report_events for select to authenticated using(exists(select 1 from public.dr_reports r where r.id=report_id));
grant select on public.dr_report_events to authenticated;
create function private.dr_log_report() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null then raise exception '로그인이 필요합니다.';end if;
 if tg_op='INSERT' then insert into public.dr_report_events(report_id,actor_id,status,note) values(new.id,auth.uid(),new.status,'보고서 생성');
 elsif new.status is distinct from old.status then insert into public.dr_report_events(report_id,actor_id,status,note) values(new.id,auth.uid(),new.status,case when new.status in ('returned','approved') then new.review_note else '' end);end if;return new;
end; $$;
revoke all on function private.dr_log_report() from public;
create trigger dr_report_after after insert or update on public.dr_reports for each row execute function private.dr_log_report();

create table public.dr_projects(id uuid primary key default gen_random_uuid(),owner_id uuid not null default auth.uid() references public.dr_profiles(id),owner_name text not null default '',name text not null check(length(btrim(name)) between 1 and 160),description text not null default '' check(length(description)<=10000),progress integer not null default 0 check(progress between 0 and 100),status text not null default 'active' check(status in ('active','on_hold','completed')),due_date date,created_at timestamptz not null default now(),updated_at timestamptz not null default now());
create index dr_projects_owner on public.dr_projects(owner_id);
alter table public.dr_projects enable row level security;
create policy dr_projects_read on public.dr_projects for select to authenticated using(owner_id=(select auth.uid()) or (select private.dr_is_manager()));
create policy dr_projects_create on public.dr_projects for insert to authenticated with check(owner_id=(select auth.uid()));
create policy dr_projects_edit on public.dr_projects for update to authenticated using(owner_id=(select auth.uid()) or (select private.dr_is_manager())) with check(owner_id=(select auth.uid()) or (select private.dr_is_manager()));
grant select,insert,update on public.dr_projects to authenticated;
create function private.dr_project_guard() returns trigger language plpgsql security invoker set search_path='' as $$
begin
 if auth.uid() is null then raise exception '로그인이 필요합니다.';end if;
 if tg_op='INSERT' then select display_name into new.owner_name from public.dr_profiles where id=auth.uid();new.created_at:=now();
 elsif new.owner_id<>old.owner_id or new.id<>old.id then raise exception '프로젝트 담당자는 변경할 수 없습니다.';
 else new.owner_name:=old.owner_name;new.created_at:=old.created_at;end if;
 if new.status='completed' then new.progress:=100;end if;
 new.updated_at:=now();return new;
end; $$;
revoke all on function private.dr_project_guard() from public;
create trigger dr_project_before before insert or update on public.dr_projects for each row execute function private.dr_project_guard();
create table public.dr_project_updates(id uuid primary key default gen_random_uuid(),project_id uuid not null references public.dr_projects(id),author_id uuid not null default auth.uid() references public.dr_profiles(id),author_name text not null default '',content text not null check(length(btrim(content)) between 1 and 10000),progress integer not null check(progress between 0 and 100),created_at timestamptz not null default now());
create index dr_updates_project on public.dr_project_updates(project_id,created_at desc);
create index dr_updates_author on public.dr_project_updates(author_id);
alter table public.dr_project_updates enable row level security;
create policy dr_updates_read on public.dr_project_updates for select to authenticated using(exists(select 1 from public.dr_projects p where p.id=project_id));
create policy dr_updates_create on public.dr_project_updates for insert to authenticated with check(author_id=(select auth.uid()) and exists(select 1 from public.dr_projects p where p.id=project_id and (p.owner_id=(select auth.uid()) or (select private.dr_is_manager()))));
grant select,insert on public.dr_project_updates to authenticated;
create function private.dr_update_progress() returns trigger language plpgsql security invoker set search_path='' as $$
begin
 if auth.uid() is null or new.author_id<>auth.uid() then raise exception '로그인이 필요합니다.';end if;
 select display_name into new.author_name from public.dr_profiles where id=auth.uid();new.created_at:=now();
 update public.dr_projects set progress=new.progress where id=new.project_id;
 if not found then raise exception '프로젝트 접근 권한이 없습니다.';end if;return new;
end; $$;
revoke all on function private.dr_update_progress() from public;
create trigger dr_update_before before insert on public.dr_project_updates for each row execute function private.dr_update_progress();

create table public.dr_attachments(id uuid primary key default gen_random_uuid(),report_id uuid not null references public.dr_reports(id),uploader_id uuid not null default auth.uid() references public.dr_profiles(id),file_name text not null check(length(file_name) between 1 and 255),file_path text not null unique,size_bytes bigint not null check(size_bytes between 1 and 10485760),mime_type text not null default 'application/octet-stream',created_at timestamptz not null default now());
create index dr_attachments_report on public.dr_attachments(report_id);
create index dr_attachments_uploader on public.dr_attachments(uploader_id);
alter table public.dr_attachments enable row level security;
create policy dr_attachments_read on public.dr_attachments for select to authenticated using(exists(select 1 from public.dr_reports r where r.id=report_id));
create policy dr_attachments_create on public.dr_attachments for insert to authenticated with check(uploader_id=(select auth.uid()) and file_path like ((select auth.uid())::text||'/'||report_id::text||'/%') and exists(select 1 from public.dr_reports r where r.id=report_id and r.author_id=(select auth.uid()) and r.status in ('draft','returned')));
create policy dr_attachments_remove on public.dr_attachments for delete to authenticated using(uploader_id=(select auth.uid()) and exists(select 1 from public.dr_reports r where r.id=report_id and r.author_id=(select auth.uid()) and r.status in ('draft','returned')));
grant select,insert,delete on public.dr_attachments to authenticated;
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values('dr-report-files','dr-report-files',false,10485760,array['image/jpeg','image/png','image/webp','application/pdf','text/plain','application/vnd.openxmlformats-officedocument.wordprocessingml.document','application/vnd.openxmlformats-officedocument.spreadsheetml.sheet']) on conflict(id) do nothing;
create policy dr_storage_read on storage.objects for select to authenticated using(bucket_id='dr-report-files' and exists(select 1 from public.dr_reports r where r.id::text=(storage.foldername(name))[2] and r.author_id::text=(storage.foldername(name))[1]));
create policy dr_storage_create on storage.objects for insert to authenticated with check(bucket_id='dr-report-files' and (storage.foldername(name))[1]=(select auth.uid())::text and exists(select 1 from public.dr_reports r where r.id::text=(storage.foldername(name))[2] and r.author_id=(select auth.uid()) and r.status in ('draft','returned')));
create policy dr_storage_remove on storage.objects for delete to authenticated using(bucket_id='dr-report-files' and (storage.foldername(name))[1]=(select auth.uid())::text and exists(select 1 from public.dr_reports r where r.id::text=(storage.foldername(name))[2] and r.author_id=(select auth.uid()) and r.status in ('draft','returned')));
notify pgrst, 'reload schema';

-- Require a named account, including when anonymous Auth is enabled in this project.
do $$ declare t text; begin foreach t in array array['dr_profiles','dr_reports','dr_projects','dr_project_updates','dr_report_events','dr_attachments'] loop execute format('create policy dr_named_accounts on public.%I as restrictive for all to authenticated using ((auth.jwt()->>''is_anonymous'')::boolean is false) with check ((auth.jwt()->>''is_anonymous'')::boolean is false)',t);end loop;end $$;
create policy dr_storage_named_accounts on storage.objects as restrictive for all to authenticated using(bucket_id<>'dr-report-files' or (auth.jwt()->>'is_anonymous')::boolean is false) with check(bucket_id<>'dr-report-files' or (auth.jwt()->>'is_anonymous')::boolean is false);
-- Remove Supabase default grants before explicitly granting minimum privileges.
revoke all on public.dr_profiles,public.dr_reports,public.dr_report_events,public.dr_projects,public.dr_project_updates,public.dr_attachments from anon,authenticated;
grant select on public.dr_profiles,public.dr_report_events to authenticated;
grant select,insert,update on public.dr_reports,public.dr_projects to authenticated;
grant select,insert on public.dr_project_updates to authenticated;
grant select,insert,delete on public.dr_attachments to authenticated;
do $$ declare p record; q text; begin for p in select * from pg_policies where (schemaname='public' and tablename like 'dr_%' and policyname<>'dr_named_accounts') or (schemaname='storage' and tablename='objects' and policyname in ('dr_storage_read','dr_storage_create','dr_storage_remove')) loop q:=format('alter policy %I on %I.%I',p.policyname,p.schemaname,p.tablename);if p.qual is not null then q:=q||' using (('||p.qual||') and (auth.jwt()->>''is_anonymous'')::boolean is false)';end if;if p.with_check is not null then q:=q||' with check (('||p.with_check||') and (auth.jwt()->>''is_anonymous'')::boolean is false)';end if;execute q;end loop;end $$;
