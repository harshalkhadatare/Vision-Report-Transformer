-- ============================================================================
--  Vision Infra · Report Analyzer — Supabase setup  (v3: approval + roles +
--  data isolation + lockout + activity log + report history + admin)
--  Run this ONCE (safe to re-run):  Dashboard → SQL Editor → New query → Run
-- ============================================================================
create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------------------
-- 1) USERS  (login by User ID + bcrypt password, session token, role, status)
-- ---------------------------------------------------------------------------
create table if not exists public.app_users (
  id            uuid primary key default gen_random_uuid(),
  name          text not null,
  user_id       text unique not null,
  password_hash text not null,
  session_token uuid,
  role          text not null default 'user',     -- 'user' | 'admin'
  status        text not null default 'pending',   -- 'pending' | 'approved' | 'rejected' | 'disabled'
  dept          text,
  failed_attempts int not null default 0,
  locked_until  timestamptz,
  last_login    timestamptz,
  approved_by   text,
  approved_at   timestamptz,
  created_at    timestamptz default now()
);
alter table public.app_users enable row level security;     -- locked: access only via SECURITY DEFINER fns
alter table public.app_users add column if not exists session_token uuid;
alter table public.app_users add column if not exists role text not null default 'user';
alter table public.app_users add column if not exists status text not null default 'pending';
alter table public.app_users add column if not exists dept text;
alter table public.app_users add column if not exists failed_attempts int not null default 0;
alter table public.app_users add column if not exists locked_until timestamptz;
alter table public.app_users add column if not exists last_login timestamptz;
alter table public.app_users add column if not exists approved_by text;
alter table public.app_users add column if not exists approved_at timestamptz;

-- ---------------------------------------------------------------------------
-- 2) ACTIVITY LOG  (audit trail) + REPORT HISTORY
-- ---------------------------------------------------------------------------
create table if not exists public.activity_log (
  id         bigserial primary key,
  user_id    text,
  name       text,
  action     text not null,     -- login, logout, register, approve, reject, upload, delete_file, report, password_change, login_failed, ...
  detail     text,
  created_at timestamptz default now()
);
alter table public.activity_log enable row level security;     -- access only via fns
create index if not exists activity_log_created_idx on public.activity_log(created_at desc);

create table if not exists public.report_history (
  id          uuid primary key default gen_random_uuid(),
  user_id     text,
  name        text,
  report_type text,
  report_name text,
  created_at  timestamptz default now()
);
alter table public.report_history enable row level security;

-- internal helper: write an audit row
create or replace function public.log_activity(p_user_id text, p_name text, p_action text, p_detail text)
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into public.activity_log(user_id,name,action,detail) values (p_user_id,p_name,p_action,p_detail);
end; $$;

-- ---------------------------------------------------------------------------
-- 3) REGISTER  (new users start as pending; very first user bootstraps as admin)
-- ---------------------------------------------------------------------------
create or replace function public.register_user(p_name text, p_user_id text, p_password text, p_dept text default null)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare v_id uuid; v_role text; v_status text; v_first boolean;
begin
  p_user_id := lower(trim(p_user_id));
  if length(coalesce(p_name,''))=0 or length(p_user_id)=0 then
    return json_build_object('ok',false,'error','Name and User ID are required.'); end if;
  -- strong password policy (also enforced client-side)
  if length(coalesce(p_password,''))<4 then
    return json_build_object('ok',false,'error','Password must be at least 4 characters.'); end if;
  if exists (select 1 from public.app_users where user_id=p_user_id) then
    return json_build_object('ok',false,'error','That User ID is already taken.'); end if;
  v_first := not exists (select 1 from public.app_users);
  v_role  := case when v_first then 'admin'    else 'user'    end;
  v_status:= case when v_first then 'approved' else 'pending' end;
  insert into public.app_users(name,user_id,password_hash,role,status,dept)
    values (trim(p_name),p_user_id,crypt(p_password,gen_salt('bf')),v_role,v_status,nullif(trim(coalesce(p_dept,'')),''))
    returning id into v_id;
  perform public.log_activity(p_user_id,trim(p_name),'register', case when v_first then 'bootstrap admin' else 'pending approval' end);
  return json_build_object('ok',true,'name',trim(p_name),'user_id',p_user_id,'status',v_status,'role',v_role,'first',v_first);
end; $$;

-- ---------------------------------------------------------------------------
-- 4) LOGIN  (lockout after 5 fails / 15 min; status gating; audit)
-- ---------------------------------------------------------------------------
create or replace function public.login_user(p_user_id text, p_password text)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare v record; v_token uuid;
begin
  p_user_id := lower(trim(p_user_id));
  select * into v from public.app_users where user_id=p_user_id;
  if v.id is null then return json_build_object('ok',false,'error','Invalid User ID or password.'); end if;
  if v.locked_until is not null and v.locked_until > now() then
    return json_build_object('ok',false,'error','Account locked due to failed attempts. Try again later or contact an administrator.'); end if;
  if v.password_hash <> crypt(p_password, v.password_hash) then
    update public.app_users set failed_attempts = failed_attempts+1,
      locked_until = case when failed_attempts+1 >= 5 then now() + interval '15 minutes' else locked_until end
      where id=v.id;
    perform public.log_activity(v.user_id,v.name,'login_failed', 'attempt '||(v.failed_attempts+1));
    return json_build_object('ok',false,'error','Invalid User ID or password.');
  end if;
  -- password OK — gate on status
  if v.status='pending'  then return json_build_object('ok',false,'error','Your account is awaiting administrator approval.'); end if;
  if v.status='rejected' then return json_build_object('ok',false,'error','Your registration was rejected. Please contact an administrator.'); end if;
  if v.status='disabled' then return json_build_object('ok',false,'error','Your account has been disabled. Please contact an administrator.'); end if;
  v_token := gen_random_uuid();
  update public.app_users set session_token=v_token, failed_attempts=0, locked_until=null, last_login=now() where id=v.id;
  perform public.log_activity(v.user_id,v.name,'login', null);
  return json_build_object('ok',true,'name',v.name,'user_id',v.user_id,'token',v_token,'role',v.role,'status',v.status,'dept',v.dept);
end; $$;

create or replace function public.whoami(p_token uuid)
returns json language plpgsql security definer set search_path = public as $$
declare v record;
begin
  select * into v from public.app_users where session_token=p_token;
  if v.id is null then return json_build_object('ok',false); end if;
  if v.status <> 'approved' then return json_build_object('ok',false); end if;
  return json_build_object('ok',true,'name',v.name,'user_id',v.user_id,'role',v.role,'status',v.status,'dept',v.dept);
end; $$;

create or replace function public.logout_user(p_token uuid)
returns json language plpgsql security definer set search_path = public as $$
declare v record;
begin
  select * into v from public.app_users where session_token=p_token;
  if v.id is not null then
    update public.app_users set session_token=null where id=v.id;
    perform public.log_activity(v.user_id,v.name,'logout',null);
  end if;
  return json_build_object('ok',true);
end; $$;

create or replace function public.change_password(p_token uuid, p_old text, p_new text)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare v record;
begin
  select * into v from public.app_users where session_token=p_token;
  if v.id is null then return json_build_object('ok',false,'error','Not signed in.'); end if;
  if v.password_hash <> crypt(p_old, v.password_hash) then return json_build_object('ok',false,'error','Current password is incorrect.'); end if;
  if length(coalesce(p_new,''))<4 then
    return json_build_object('ok',false,'error','New password must be at least 4 characters.'); end if;
  update public.app_users set password_hash=crypt(p_new,gen_salt('bf')) where id=v.id;
  perform public.log_activity(v.user_id,v.name,'password_change',null);
  return json_build_object('ok',true,'message','Password updated.');
end; $$;

-- ---------------------------------------------------------------------------
-- 5) UPLOADS  (owner-scoped; direct table reads are DENIED — only via fns)
-- ---------------------------------------------------------------------------
create table if not exists public.uploads (
  id             uuid primary key default gen_random_uuid(),
  report_type    text not null,
  file_name      text not null,
  file_size      bigint,
  row_count      int,
  uploaded_by    text,
  uploaded_by_id text,
  storage_path   text,
  status         text default 'stored',
  uploaded_at    timestamptz default now()
);
alter table public.uploads add column if not exists uploaded_by_id text;
alter table public.uploads add column if not exists storage_path text;
alter table public.uploads add column if not exists status text default 'stored';
alter table public.uploads enable row level security;
-- CLOSE THE ISOLATION HOLE: remove permissive read; all access goes via token-checked fns
drop policy if exists "uploads read"   on public.uploads;
drop policy if exists "uploads insert" on public.uploads;
-- (no SELECT policy => direct anon/authenticated reads return nothing)

create or replace function public.add_upload(p_token uuid, p_report_type text, p_file_name text,
  p_file_size bigint, p_row_count int, p_storage_path text)
returns json language plpgsql security definer set search_path = public as $$
declare v record; v_id uuid;
begin
  select * into v from public.app_users where session_token=p_token;
  if v.id is null or v.status<>'approved' then return json_build_object('ok',false,'error','Not signed in.'); end if;
  insert into public.uploads(report_type,file_name,file_size,row_count,uploaded_by,uploaded_by_id,storage_path,status)
    values(p_report_type,p_file_name,p_file_size,p_row_count,v.name,v.user_id,p_storage_path,'stored')
    returning id into v_id;
  perform public.log_activity(v.user_id,v.name,'upload', p_report_type||' · '||p_file_name);
  return json_build_object('ok',true,'id',v_id);
end; $$;

-- a user sees ONLY their own uploads (admins use admin_list_uploads)
create or replace function public.list_my_uploads(p_token uuid, p_report_type text default null)
returns json language plpgsql security definer set search_path = public as $$
declare v record; v_rows json;
begin
  select * into v from public.app_users where session_token=p_token;
  if v.id is null or v.status<>'approved' then return json_build_object('ok',false,'error','Not signed in.'); end if;
  select coalesce(json_agg(t order by t.uploaded_at desc),'[]') into v_rows from (
    select id,report_type,file_name,file_size,row_count,uploaded_by,storage_path,status,uploaded_at
    from public.uploads where uploaded_by_id=v.user_id
      and (p_report_type is null or report_type=p_report_type) limit 200
  ) t;
  return json_build_object('ok',true,'rows',v_rows);
end; $$;

-- SHARED: any approved user can see ALL uploads (every department). Includes the
-- owner id so the UI shows the Delete button only to the owner or an admin.
create or replace function public.list_uploads(p_token uuid, p_report_type text default null)
returns json language plpgsql security definer set search_path = public as $$
declare v record; v_rows json;
begin
  select * into v from public.app_users where session_token=p_token;
  if v.id is null or v.status<>'approved' then return json_build_object('ok',false,'error','Not signed in.'); end if;
  select coalesce(json_agg(t order by t.uploaded_at desc),'[]') into v_rows from (
    select id,report_type,file_name,file_size,row_count,uploaded_by,uploaded_by_id,storage_path,status,uploaded_at
    from public.uploads
      where (p_report_type is null or report_type=p_report_type) limit 200
  ) t;
  return json_build_object('ok',true,'rows',v_rows);
end; $$;

-- owner OR admin can delete (also removes the stored object)
create or replace function public.delete_upload(p_token uuid, p_id uuid)
returns json language plpgsql security definer set search_path = public, storage as $$
declare v record; u record;
begin
  select * into v from public.app_users where session_token=p_token;
  if v.id is null or v.status<>'approved' then return json_build_object('ok',false,'error','Not signed in.'); end if;
  select * into u from public.uploads where id=p_id;
  if u.id is null then return json_build_object('ok',false,'error','File not found.'); end if;
  if v.role<>'admin' and coalesce(u.uploaded_by_id,'')<>v.user_id then
    return json_build_object('ok',false,'error','You can only delete your own files.'); end if;
  if u.storage_path is not null then
    begin delete from storage.objects where bucket_id='report-files' and name=u.storage_path; exception when others then null; end;
  end if;
  delete from public.uploads where id=p_id;
  perform public.log_activity(v.user_id,v.name,'delete_file', u.file_name);
  return json_build_object('ok',true);
end; $$;

-- report-generation history
create or replace function public.log_report(p_token uuid, p_report_type text, p_report_name text)
returns json language plpgsql security definer set search_path = public as $$
declare v record;
begin
  select * into v from public.app_users where session_token=p_token;
  if v.id is null or v.status<>'approved' then return json_build_object('ok',false); end if;
  insert into public.report_history(user_id,name,report_type,report_name) values(v.user_id,v.name,p_report_type,p_report_name);
  perform public.log_activity(v.user_id,v.name,'report', coalesce(p_report_name,p_report_type));
  return json_build_object('ok',true);
end; $$;

create or replace function public.list_my_reports(p_token uuid)
returns json language plpgsql security definer set search_path = public as $$
declare v record; r json;
begin
  select * into v from public.app_users where session_token=p_token;
  if v.id is null or v.status<>'approved' then return json_build_object('ok',false,'error','Not signed in.'); end if;
  select coalesce(json_agg(t order by t.created_at desc),'[]') into r from (
    select report_type,report_name,created_at from public.report_history where user_id=v.user_id limit 100) t;
  return json_build_object('ok',true,'rows',r);
end; $$;

-- ---------------------------------------------------------------------------
-- 6) ADMIN  (every fn validates the caller is an approved admin)
-- ---------------------------------------------------------------------------
create or replace function public._admin(p_token uuid)
returns public.app_users language sql security definer set search_path = public as $$
  select * from public.app_users where session_token=p_token and role='admin' and status='approved';
$$;

create or replace function public.admin_list_users(p_token uuid)
returns json language plpgsql security definer set search_path = public as $$
declare a record; r json;
begin
  a := public._admin(p_token); if a.id is null then return json_build_object('ok',false,'error','Admin only.'); end if;
  select coalesce(json_agg(t order by t.created_at desc),'[]') into r from (
    select id,name,user_id,role,status,dept,failed_attempts,locked_until,last_login,created_at,approved_by,approved_at
    from public.app_users) t;
  return json_build_object('ok',true,'rows',r);
end; $$;

create or replace function public.admin_set_status(p_token uuid, p_user_id text, p_status text)
returns json language plpgsql security definer set search_path = public as $$
declare a record;
begin
  a := public._admin(p_token); if a.id is null then return json_build_object('ok',false,'error','Admin only.'); end if;
  if p_status not in ('approved','rejected','disabled','pending') then return json_build_object('ok',false,'error','Bad status.'); end if;
  update public.app_users set status=p_status,
    approved_by=case when p_status='approved' then a.user_id else approved_by end,
    approved_at=case when p_status='approved' then now() else approved_at end,
    session_token=case when p_status in ('rejected','disabled') then null else session_token end
    where user_id=lower(trim(p_user_id));
  if not found then return json_build_object('ok',false,'error','No such user.'); end if;
  perform public.log_activity(a.user_id,a.name, case p_status when 'approved' then 'approve' when 'rejected' then 'reject' else 'set_status' end, p_user_id||' -> '||p_status);
  return json_build_object('ok',true);
end; $$;

create or replace function public.admin_set_role(p_token uuid, p_user_id text, p_role text)
returns json language plpgsql security definer set search_path = public as $$
declare a record;
begin
  a := public._admin(p_token); if a.id is null then return json_build_object('ok',false,'error','Admin only.'); end if;
  if p_role not in ('user','admin') then return json_build_object('ok',false,'error','Bad role.'); end if;
  update public.app_users set role=p_role where user_id=lower(trim(p_user_id));
  perform public.log_activity(a.user_id,a.name,'set_role', p_user_id||' -> '||p_role);
  return json_build_object('ok',true);
end; $$;

create or replace function public.admin_unlock_user(p_token uuid, p_user_id text)
returns json language plpgsql security definer set search_path = public as $$
declare a record;
begin
  a := public._admin(p_token); if a.id is null then return json_build_object('ok',false,'error','Admin only.'); end if;
  update public.app_users set failed_attempts=0, locked_until=null where user_id=lower(trim(p_user_id));
  perform public.log_activity(a.user_id,a.name,'unlock', p_user_id);
  return json_build_object('ok',true);
end; $$;

create or replace function public.admin_change_username(p_token uuid, p_user_id text, p_new_user_id text)
returns json language plpgsql security definer set search_path = public as $$
declare a record;
begin
  a := public._admin(p_token); if a.id is null then return json_build_object('ok',false,'error','Admin only.'); end if;
  p_new_user_id := lower(trim(p_new_user_id));
  if length(p_new_user_id)=0 then return json_build_object('ok',false,'error','New User ID required.'); end if;
  if exists(select 1 from public.app_users where user_id=p_new_user_id) then return json_build_object('ok',false,'error','That User ID is taken.'); end if;
  update public.app_users set user_id=p_new_user_id where user_id=lower(trim(p_user_id));
  if not found then return json_build_object('ok',false,'error','No such user.'); end if;
  perform public.log_activity(a.user_id,a.name,'rename_user', p_user_id||' -> '||p_new_user_id);
  return json_build_object('ok',true);
end; $$;

create or replace function public.admin_reset_password(p_token uuid, p_user_id text, p_new_password text)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare a record;
begin
  a := public._admin(p_token); if a.id is null then return json_build_object('ok',false,'error','Admin only.'); end if;
  if length(coalesce(p_new_password,''))<4 then return json_build_object('ok',false,'error','Password must be at least 4 characters.'); end if;
  update public.app_users set password_hash=crypt(p_new_password,gen_salt('bf')), failed_attempts=0, locked_until=null where user_id=lower(trim(p_user_id));
  if not found then return json_build_object('ok',false,'error','No such user.'); end if;
  perform public.log_activity(a.user_id,a.name,'password_reset', p_user_id);
  return json_build_object('ok',true,'message','Password reset.');
end; $$;

create or replace function public.admin_delete_user(p_token uuid, p_user_id text)
returns json language plpgsql security definer set search_path = public as $$
declare a record;
begin
  a := public._admin(p_token); if a.id is null then return json_build_object('ok',false,'error','Admin only.'); end if;
  if lower(trim(p_user_id))=a.user_id then return json_build_object('ok',false,'error','You cannot delete your own admin account.'); end if;
  delete from public.app_users where user_id=lower(trim(p_user_id));
  if not found then return json_build_object('ok',false,'error','No such user.'); end if;
  perform public.log_activity(a.user_id,a.name,'delete_user', p_user_id);
  return json_build_object('ok',true);
end; $$;

create or replace function public.admin_list_uploads(p_token uuid)
returns json language plpgsql security definer set search_path = public as $$
declare a record; r json;
begin
  a := public._admin(p_token); if a.id is null then return json_build_object('ok',false,'error','Admin only.'); end if;
  select coalesce(json_agg(t order by t.uploaded_at desc),'[]') into r from (
    select id,report_type,file_name,file_size,row_count,uploaded_by,uploaded_by_id,storage_path,status,uploaded_at
    from public.uploads limit 500) t;
  return json_build_object('ok',true,'rows',r);
end; $$;

create or replace function public.admin_list_activity(p_token uuid, p_user text default null, p_action text default null, p_limit int default 300)
returns json language plpgsql security definer set search_path = public as $$
declare a record; r json;
begin
  a := public._admin(p_token); if a.id is null then return json_build_object('ok',false,'error','Admin only.'); end if;
  select coalesce(json_agg(t order by t.created_at desc),'[]') into r from (
    select user_id,name,action,detail,created_at from public.activity_log
    where (p_user is null or user_id=lower(trim(p_user)))
      and (p_action is null or action=p_action)
    order by created_at desc limit greatest(1,least(coalesce(p_limit,300),1000))) t;
  return json_build_object('ok',true,'rows',r);
end; $$;

create or replace function public.admin_kpis(p_token uuid)
returns json language plpgsql security definer set search_path = public as $$
declare a record; reg json; upl json; rep json;
begin
  a := public._admin(p_token);
  if a.id is null then return json_build_object('ok',false,'error','Admin only.'); end if;

  select coalesce(json_agg(json_build_object('day', to_char(g.d,'YYYY-MM-DD'), 'n', g.n) order by g.d), '[]')
    into reg
  from (
    select s.d::date as d, count(u.id) as n
    from generate_series((now()::date - 13)::timestamp, (now()::date)::timestamp, interval '1 day') as s(d)
    left join public.app_users u on u.created_at::date = s.d::date
    group by s.d::date
  ) g;

  select coalesce(json_agg(json_build_object('day', to_char(g.d,'YYYY-MM-DD'), 'n', g.n) order by g.d), '[]')
    into upl
  from (
    select s.d::date as d, count(x.id) as n
    from generate_series((now()::date - 13)::timestamp, (now()::date)::timestamp, interval '1 day') as s(d)
    left join public.uploads x on x.uploaded_at::date = s.d::date
    group by s.d::date
  ) g;

  select coalesce(json_agg(json_build_object('day', to_char(g.d,'YYYY-MM-DD'), 'n', g.n) order by g.d), '[]')
    into rep
  from (
    select s.d::date as d, count(rh.id) as n
    from generate_series((now()::date - 13)::timestamp, (now()::date)::timestamp, interval '1 day') as s(d)
    left join public.report_history rh on rh.created_at::date = s.d::date
    group by s.d::date
  ) g;

  return json_build_object('ok',true,
    'totalUsers',   (select count(*) from public.app_users),
    'activeUsers',  (select count(*) from public.app_users where status='approved'),
    'pendingUsers', (select count(*) from public.app_users where status='pending'),
    'rejectedUsers',(select count(*) from public.app_users where status='rejected'),
    'disabledUsers',(select count(*) from public.app_users where status='disabled'),
    'totalUploads', (select count(*) from public.uploads),
    'uploadsToday', (select count(*) from public.uploads where uploaded_at::date=now()::date),
    'totalReports', (select count(*) from public.report_history),
    'reportsToday', (select count(*) from public.report_history where created_at::date=now()::date),
    'regTrend',reg,'uploadTrend',upl,'reportTrend',rep);
end; $$;

grant execute on function public.admin_kpis(uuid) to anon, authenticated;
-- ---------------------------------------------------------------------------
-- 7) GRANTS  (anon/authenticated may only EXECUTE these vetted functions)
-- ---------------------------------------------------------------------------
do $$ declare f text; begin
  for f in select 'public.'||p.proname||'('||pg_get_function_identity_arguments(p.oid)||')'
           from pg_proc p join pg_namespace n on n.oid=p.pronamespace
           where n.nspname='public' and p.proname in (
             'register_user','login_user','whoami','logout_user','change_password',
             'add_upload','list_my_uploads','list_uploads','delete_upload','log_report','list_my_reports',
             'admin_list_users','admin_set_status','admin_set_role','admin_unlock_user',
             'admin_change_username','admin_reset_password','admin_delete_user',
             'admin_list_uploads','admin_list_activity','admin_kpis')
  loop execute 'grant execute on function '||f||' to anon, authenticated'; end loop;
end $$;
-- internal helpers are NOT granted to clients
revoke all on function public.log_activity(text,text,text,text) from anon, authenticated;
revoke all on function public._admin(uuid) from anon, authenticated;

-- ---------------------------------------------------------------------------
-- 8) STORAGE
--  NOTE ON FILE PRIVACY: with the app's custom (anon-key) auth, the bucket is
--  public-read so downloads work. File *metadata* is fully isolated (users only
--  see their own via list_my_uploads). For private file *content*, switch the
--  bucket to private and serve downloads through a Supabase Edge Function that
--  validates the session token and returns a short-lived signed URL.
-- ---------------------------------------------------------------------------
insert into storage.buckets (id,name,public) values ('report-files','report-files',true)
  on conflict (id) do update set public=true;
drop policy if exists "report files upload" on storage.objects;
create policy "report files upload" on storage.objects for insert to anon, authenticated
  with check (bucket_id='report-files');

-- Done.  (Tip: the FIRST account you register becomes the admin automatically.)

-- ============================================================================
-- ROLE RIGHTS (RBAC)  — per-user report-module access control
--   report_access: NULL  = unconfigured (user sees ALL reports, legacy behaviour)
--                  jsonb array = explicit list of allowed report keys, e.g. ["rental","stock"]
--   Admins always bypass this and see every report.
-- Re-run this block on an existing database to enable Role Rights.
-- ============================================================================
alter table public.app_users add column if not exists report_access jsonb;

-- login_user now also returns report_access
create or replace function public.login_user(p_user_id text, p_password text)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare v record; v_token uuid;
begin
  p_user_id := lower(trim(p_user_id));
  select * into v from public.app_users where user_id=p_user_id;
  if v.id is null then return json_build_object('ok',false,'error','Invalid User ID or password.'); end if;
  if v.locked_until is not null and v.locked_until > now() then
    return json_build_object('ok',false,'error','Account locked due to failed attempts. Try again later or contact an administrator.'); end if;
  if v.password_hash <> crypt(p_password, v.password_hash) then
    update public.app_users set failed_attempts = failed_attempts+1,
      locked_until = case when failed_attempts+1 >= 5 then now() + interval '15 minutes' else locked_until end
      where id=v.id;
    perform public.log_activity(v.user_id,v.name,'login_failed', 'attempt '||(v.failed_attempts+1));
    return json_build_object('ok',false,'error','Invalid User ID or password.');
  end if;
  if v.status='pending'  then return json_build_object('ok',false,'error','Your account is awaiting administrator approval.'); end if;
  if v.status='rejected' then return json_build_object('ok',false,'error','Your registration was rejected. Please contact an administrator.'); end if;
  if v.status='disabled' then return json_build_object('ok',false,'error','Your account has been disabled. Please contact an administrator.'); end if;
  v_token := gen_random_uuid();
  update public.app_users set session_token=v_token, failed_attempts=0, locked_until=null, last_login=now() where id=v.id;
  perform public.log_activity(v.user_id,v.name,'login', null);
  return json_build_object('ok',true,'name',v.name,'user_id',v.user_id,'token',v_token,'role',v.role,'status',v.status,'dept',v.dept,'report_access',v.report_access);
end; $$;

-- whoami now also returns report_access (authoritative permission source on every session restore)
create or replace function public.whoami(p_token uuid)
returns json language plpgsql security definer set search_path = public as $$
declare v record;
begin
  select * into v from public.app_users where session_token=p_token;
  if v.id is null then return json_build_object('ok',false); end if;
  if v.status <> 'approved' then return json_build_object('ok',false); end if;
  return json_build_object('ok',true,'name',v.name,'user_id',v.user_id,'role',v.role,'status',v.status,'dept',v.dept,'report_access',v.report_access);
end; $$;

-- admin_list_users now also returns report_access (for the Role Rights UI)
create or replace function public.admin_list_users(p_token uuid)
returns json language plpgsql security definer set search_path = public as $$
declare a record; r json;
begin
  a := public._admin(p_token); if a.id is null then return json_build_object('ok',false,'error','Admin only.'); end if;
  select coalesce(json_agg(t order by t.created_at desc),'[]') into r from (
    select id,name,user_id,role,status,dept,failed_attempts,locked_until,last_login,created_at,approved_by,approved_at,report_access
    from public.app_users) t;
  return json_build_object('ok',true,'rows',r);
end; $$;

-- admin-only: set a user's allowed report modules (pass a jsonb array of report keys; null = all)
create or replace function public.admin_set_report_access(p_token uuid, p_user_id text, p_reports jsonb)
returns json language plpgsql security definer set search_path = public as $$
declare a record;
begin
  a := public._admin(p_token); if a.id is null then return json_build_object('ok',false,'error','Admin only.'); end if;
  if p_reports is not null and jsonb_typeof(p_reports) <> 'array' then
    return json_build_object('ok',false,'error','report list must be a JSON array.'); end if;
  update public.app_users set report_access = p_reports where user_id=lower(trim(p_user_id));
  if not found then return json_build_object('ok',false,'error','No such user.'); end if;
  perform public.log_activity(a.user_id,a.name,'role_rights', p_user_id||' -> '||coalesce(p_reports::text,'ALL'));
  return json_build_object('ok',true);
end; $$;

grant execute on function public.login_user(text,text)               to anon, authenticated;
grant execute on function public.whoami(uuid)                          to anon, authenticated;
grant execute on function public.admin_list_users(uuid)                to anon, authenticated;
grant execute on function public.admin_set_report_access(uuid,text,jsonb) to anon, authenticated;

-- ============================================================================
-- EMAIL ADDRESSES  — prerequisite for the report notification system
--   app_users had no email column, so no user could be contacted.
--   Safe + idempotent: re-run this block on an existing database.
-- ============================================================================
alter table public.app_users add column if not exists email text;

-- optional but recommended: stop two accounts sharing one address
create unique index if not exists app_users_email_uniq
  on public.app_users (lower(email)) where email is not null and email <> '';

-- login_user now also returns email
create or replace function public.login_user(p_user_id text, p_password text)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare v record; v_token uuid;
begin
  p_user_id := lower(trim(p_user_id));
  select * into v from public.app_users where user_id=p_user_id;
  if v.id is null then return json_build_object('ok',false,'error','Invalid User ID or password.'); end if;
  if v.locked_until is not null and v.locked_until > now() then
    return json_build_object('ok',false,'error','Account locked due to failed attempts. Try again later or contact an administrator.'); end if;
  if v.password_hash <> crypt(p_password, v.password_hash) then
    update public.app_users set failed_attempts = failed_attempts+1,
      locked_until = case when failed_attempts+1 >= 5 then now() + interval '15 minutes' else locked_until end
      where id=v.id;
    perform public.log_activity(v.user_id,v.name,'login_failed', 'attempt '||(v.failed_attempts+1));
    return json_build_object('ok',false,'error','Invalid User ID or password.');
  end if;
  if v.status='pending'  then return json_build_object('ok',false,'error','Your account is awaiting administrator approval.'); end if;
  if v.status='rejected' then return json_build_object('ok',false,'error','Your registration was rejected. Please contact an administrator.'); end if;
  if v.status='disabled' then return json_build_object('ok',false,'error','Your account has been disabled. Please contact an administrator.'); end if;
  v_token := gen_random_uuid();
  update public.app_users set session_token=v_token, failed_attempts=0, locked_until=null, last_login=now() where id=v.id;
  perform public.log_activity(v.user_id,v.name,'login', null);
  return json_build_object('ok',true,'name',v.name,'user_id',v.user_id,'token',v_token,'role',v.role,
                           'status',v.status,'dept',v.dept,'report_access',v.report_access,
                           'email',v.email,'last_login',v.last_login,'created_at',v.created_at);
end; $$;

-- whoami now also returns email / last_login / created_at (fills the profile panel)
create or replace function public.whoami(p_token uuid)
returns json language plpgsql security definer set search_path = public as $$
declare v record;
begin
  select * into v from public.app_users where session_token=p_token;
  if v.id is null then return json_build_object('ok',false); end if;
  if v.status <> 'approved' then return json_build_object('ok',false); end if;
  return json_build_object('ok',true,'name',v.name,'user_id',v.user_id,'role',v.role,'status',v.status,
                           'dept',v.dept,'report_access',v.report_access,
                           'email',v.email,'last_login',v.last_login,'created_at',v.created_at);
end; $$;

-- admin_list_users now also returns email
create or replace function public.admin_list_users(p_token uuid)
returns json language plpgsql security definer set search_path = public as $$
declare a record; r json;
begin
  a := public._admin(p_token); if a.id is null then return json_build_object('ok',false,'error','Admin only.'); end if;
  select coalesce(json_agg(t order by t.created_at desc),'[]') into r from (
    select id,name,user_id,role,status,dept,email,failed_attempts,locked_until,last_login,created_at,approved_by,approved_at,report_access
    from public.app_users) t;
  return json_build_object('ok',true,'rows',r);
end; $$;

-- admin-only: set / clear a user's email address
create or replace function public.admin_set_email(p_token uuid, p_user_id text, p_email text)
returns json language plpgsql security definer set search_path = public as $$
declare a record; v_email text;
begin
  a := public._admin(p_token); if a.id is null then return json_build_object('ok',false,'error','Admin only.'); end if;
  v_email := nullif(lower(trim(coalesce(p_email,''))),'');
  if v_email is not null and v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    return json_build_object('ok',false,'error','That does not look like a valid email address.');
  end if;
  if v_email is not null and exists (
      select 1 from public.app_users where lower(email)=v_email and user_id <> lower(trim(p_user_id))) then
    return json_build_object('ok',false,'error','That email is already used by another account.');
  end if;
  update public.app_users set email = v_email where user_id = lower(trim(p_user_id));
  if not found then return json_build_object('ok',false,'error','No such user.'); end if;
  perform public.log_activity(a.user_id,a.name,'set_email', p_user_id||' -> '||coalesce(v_email,'(cleared)'));
  return json_build_object('ok',true);
end; $$;

grant execute on function public.login_user(text,text)                to anon, authenticated;
grant execute on function public.whoami(uuid)                          to anon, authenticated;
grant execute on function public.admin_list_users(uuid)                to anon, authenticated;
grant execute on function public.admin_set_email(uuid,text,text)       to anon, authenticated;

-- ============================================================================
-- REPORT EMAIL NOTIFICATIONS
--   Admin builds a schedule: which report, which users, what time, what text.
--   pg_cron wakes every 5 minutes, finds anything due, and calls the Vercel
--   endpoint (which sends through Resend). Safe + idempotent to re-run.
-- ============================================================================

create table if not exists public.email_schedules (
  id           uuid primary key default gen_random_uuid(),
  title        text not null,
  report_types jsonb not null default '[]'::jsonb,   -- ["rental","sales"]
  recipients   jsonb not null default '[]'::jsonb,   -- ["harshal","sandeep"] (app_users.user_id)
  description  text,
  send_time    text not null default '09:00',        -- 'HH:MM' in IST
  days         jsonb not null default '[1,2,3,4,5]'::jsonb, -- 0=Sun … 6=Sat
  enabled      boolean not null default true,
  last_sent_at timestamptz,
  last_status  text,
  created_by   text,
  created_at   timestamptz default now()
);

create table if not exists public.email_log (
  id          uuid primary key default gen_random_uuid(),
  schedule_id uuid,
  title       text,
  recipients  jsonb,
  report_types jsonb,
  status      text,                                   -- 'sent' | 'failed' | 'skipped'
  detail      text,
  sent_at     timestamptz default now()
);
create index if not exists email_log_sent_idx on public.email_log (sent_at desc);

alter table public.email_schedules enable row level security;
alter table public.email_log       enable row level security;

-- ---------- admin RPCs ----------
create or replace function public.admin_list_schedules(p_token uuid)
returns json language plpgsql security definer set search_path = public as $$
declare a record; r json;
begin
  a := public._admin(p_token); if a.id is null then return json_build_object('ok',false,'error','Admin only.'); end if;
  select coalesce(json_agg(t order by t.created_at desc),'[]') into r from public.email_schedules t;
  return json_build_object('ok',true,'rows',r);
end; $$;

create or replace function public.admin_save_schedule(
  p_token uuid, p_id uuid, p_title text, p_report_types jsonb, p_recipients jsonb,
  p_description text, p_send_time text, p_days jsonb, p_enabled boolean)
returns json language plpgsql security definer set search_path = public as $$
declare a record; v_id uuid;
begin
  a := public._admin(p_token); if a.id is null then return json_build_object('ok',false,'error','Admin only.'); end if;
  if coalesce(trim(p_title),'') = '' then return json_build_object('ok',false,'error','Give the schedule a title.'); end if;
  if p_send_time !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then
    return json_build_object('ok',false,'error','Time must be in HH:MM (24-hour) format.'); end if;
  if jsonb_array_length(coalesce(p_report_types,'[]'::jsonb)) = 0 then
    return json_build_object('ok',false,'error','Select at least one report.'); end if;
  if jsonb_array_length(coalesce(p_recipients,'[]'::jsonb)) = 0 then
    return json_build_object('ok',false,'error','Select at least one recipient.'); end if;

  if p_id is null then
    insert into public.email_schedules (title,report_types,recipients,description,send_time,days,enabled,created_by)
    values (trim(p_title),p_report_types,p_recipients,p_description,p_send_time,coalesce(p_days,'[1,2,3,4,5]'::jsonb),coalesce(p_enabled,true),a.user_id)
    returning id into v_id;
  else
    update public.email_schedules
       set title=trim(p_title), report_types=p_report_types, recipients=p_recipients,
           description=p_description, send_time=p_send_time,
           days=coalesce(p_days,'[1,2,3,4,5]'::jsonb), enabled=coalesce(p_enabled,true)
     where id=p_id returning id into v_id;
    if v_id is null then return json_build_object('ok',false,'error','Schedule not found.'); end if;
  end if;
  perform public.log_activity(a.user_id,a.name,'email_schedule', trim(p_title));
  return json_build_object('ok',true,'id',v_id);
end; $$;

create or replace function public.admin_delete_schedule(p_token uuid, p_id uuid)
returns json language plpgsql security definer set search_path = public as $$
declare a record;
begin
  a := public._admin(p_token); if a.id is null then return json_build_object('ok',false,'error','Admin only.'); end if;
  delete from public.email_schedules where id=p_id;
  perform public.log_activity(a.user_id,a.name,'email_schedule', 'deleted '||p_id::text);
  return json_build_object('ok',true);
end; $$;

create or replace function public.admin_email_log(p_token uuid, p_limit int default 100)
returns json language plpgsql security definer set search_path = public as $$
declare a record; r json;
begin
  a := public._admin(p_token); if a.id is null then return json_build_object('ok',false,'error','Admin only.'); end if;
  select coalesce(json_agg(t order by t.sent_at desc),'[]') into r
    from (select * from public.email_log order by sent_at desc limit coalesce(p_limit,100)) t;
  return json_build_object('ok',true,'rows',r);
end; $$;

-- Resolve a schedule into a ready-to-send payload (recipients + report freshness).
-- Used by the sender endpoint; also powers "Send test now".
create or replace function public.email_payload(p_token uuid, p_id uuid)
returns json language plpgsql security definer set search_path = public as $$
declare a record; s record; r json; rep json;
begin
  a := public._admin(p_token); if a.id is null then return json_build_object('ok',false,'error','Admin only.'); end if;
  select * into s from public.email_schedules where id=p_id;
  if s.id is null then return json_build_object('ok',false,'error','Schedule not found.'); end if;

  -- recipients that actually have an email on file
  select coalesce(json_agg(json_build_object('name',u.name,'user_id',u.user_id,'email',u.email)),'[]') into r
    from public.app_users u
   where u.user_id in (select jsonb_array_elements_text(s.recipients))
     and u.email is not null and u.email <> '' and u.status='approved';

  -- latest upload per selected report -> "report updated" timestamp
  select coalesce(json_agg(json_build_object('report_type',x.report_type,'file_name',x.file_name,
                                             'row_count',x.row_count,'uploaded_at',x.uploaded_at,
                                             'uploaded_by',x.uploaded_by)),'[]') into rep
    from (select distinct on (report_type) report_type,file_name,row_count,uploaded_at,uploaded_by
            from public.uploads
           where report_type in (select jsonb_array_elements_text(s.report_types))
           order by report_type, uploaded_at desc) x;

  return json_build_object('ok',true,'schedule',row_to_json(s),'recipients',r,'reports',rep);
end; $$;

create or replace function public.email_mark_sent(p_id uuid, p_status text, p_detail text)
returns void language plpgsql security definer set search_path = public as $$
declare s record;
begin
  select * into s from public.email_schedules where id=p_id;
  update public.email_schedules set last_sent_at=now(), last_status=p_status where id=p_id;
  insert into public.email_log (schedule_id,title,recipients,report_types,status,detail)
  values (p_id, s.title, s.recipients, s.report_types, p_status, p_detail);
end; $$;

grant execute on function public.admin_list_schedules(uuid)                              to anon, authenticated;
grant execute on function public.admin_save_schedule(uuid,uuid,text,jsonb,jsonb,text,text,jsonb,boolean) to anon, authenticated;
grant execute on function public.admin_delete_schedule(uuid,uuid)                        to anon, authenticated;
grant execute on function public.admin_email_log(uuid,int)                               to anon, authenticated;
grant execute on function public.email_payload(uuid,uuid)                                to anon, authenticated;

-- ---------------------------------------------------------------------------
-- SCHEDULER  (pg_cron + pg_net)
-- Run ONCE, after setting the two settings below to your own values.
-- Everything above works without this; this is only the automatic trigger.
-- ---------------------------------------------------------------------------
create extension if not exists pg_cron;
create extension if not exists pg_net;

-- Where to POST, and the shared secret the endpoint checks.
-- Replace both, then run this block.
--   alter database postgres set app.mail_endpoint = 'https://your-app.vercel.app/api/send-report-email';
--   alter database postgres set app.mail_secret   = 'a-long-random-string';

create or replace function public.email_dispatch_due()
returns void language plpgsql security definer set search_path = public, extensions as $$
declare s record; v_now timestamptz := now() at time zone 'Asia/Kolkata';
        v_url text; v_secret text;
begin
  v_url    := current_setting('app.mail_endpoint', true);
  v_secret := current_setting('app.mail_secret', true);
  if v_url is null then return; end if;

  for s in
    select * from public.email_schedules
     where enabled
       -- today is a selected weekday
       and (days ? extract(dow from v_now)::text)
       -- the scheduled minute has arrived (within the last 5 min window).
       -- Compared as minutes-since-midnight so a 23:5x schedule cannot wrap past
       -- midnight and silently never fire.
       and (
         (extract(hour from v_now)::int * 60 + extract(minute from v_now)::int)
         - (split_part(send_time,':',1)::int * 60 + split_part(send_time,':',2)::int)
       ) between 0 and 4
       -- and it has not already gone out today
       and (last_sent_at is null
            or (last_sent_at at time zone 'Asia/Kolkata')::date < v_now::date)
  loop
    perform net.http_post(
      url     := v_url,
      headers := jsonb_build_object('Content-Type','application/json','x-mail-secret',v_secret),
      body    := jsonb_build_object('schedule_id', s.id)
    );
    -- marked immediately so a slow response cannot double-send in the next tick
    update public.email_schedules set last_sent_at = now(), last_status = 'queued' where id = s.id;
  end loop;
end; $$;

-- every 5 minutes
select cron.unschedule('report-email-dispatch')
  where exists (select 1 from cron.job where jobname = 'report-email-dispatch');
select cron.schedule('report-email-dispatch', '*/5 * * * *', $cron$ select public.email_dispatch_due(); $cron$);

-- the sender endpoint calls this with the service key to fetch a payload without a user token
create or replace function public.email_payload_svc(p_id uuid)
returns json language plpgsql security definer set search_path = public as $$
declare s record; r json; rep json;
begin
  select * into s from public.email_schedules where id=p_id;
  if s.id is null then return json_build_object('ok',false,'error','Schedule not found.'); end if;
  select coalesce(json_agg(json_build_object('name',u.name,'user_id',u.user_id,'email',u.email)),'[]') into r
    from public.app_users u
   where u.user_id in (select jsonb_array_elements_text(s.recipients))
     and u.email is not null and u.email <> '' and u.status='approved';
  select coalesce(json_agg(json_build_object('report_type',x.report_type,'file_name',x.file_name,
                                             'row_count',x.row_count,'uploaded_at',x.uploaded_at,
                                             'uploaded_by',x.uploaded_by)),'[]') into rep
    from (select distinct on (report_type) report_type,file_name,row_count,uploaded_at,uploaded_by
            from public.uploads
           where report_type in (select jsonb_array_elements_text(s.report_types))
           order by report_type, uploaded_at desc) x;
  return json_build_object('ok',true,'schedule',row_to_json(s),'recipients',r,'reports',rep);
end; $$;
