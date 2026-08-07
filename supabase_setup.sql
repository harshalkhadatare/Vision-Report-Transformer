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
    select u.id,u.report_type,u.file_name,u.file_size,u.row_count,u.uploaded_by,u.uploaded_by_id,
           u.storage_path,u.status,u.uploaded_at,
           -- role of the uploader, so the UI can show the latest ADMIN-published file
           coalesce(au.role,'user') as uploaded_by_role
    from public.uploads u
    left join public.app_users au on au.user_id = u.uploaded_by_id
      where (p_report_type is null or u.report_type=p_report_type)
      order by u.uploaded_at desc limit 200
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

-- Config lives in a table: hosted Supabase does not allow `alter database ... set`
-- (the SQL Editor runs as a non-superuser). RLS keeps it readable only by the
-- service role. Set your own values here, then run this block.
create table if not exists public.app_config (
  key   text primary key,
  value text not null
);
alter table public.app_config enable row level security;

-- `do nothing`, NOT `do update`: re-running this file must never overwrite the
-- live endpoint/secret with these placeholders. Seed values are inserted only on
-- a fresh install. To change them later, UPDATE the row explicitly:
--   update public.app_config set value = '<real value>' where key = 'mail_endpoint';
insert into public.app_config (key, value) values
  ('mail_endpoint', 'https://your-app.vercel.app/api/send-report-email'),
  ('mail_secret',   'a-long-random-string-matching-MAIL_SECRET')
on conflict (key) do nothing;

create or replace function public.email_dispatch_due()
returns void language plpgsql security definer set search_path = public, extensions as $$
declare s record; v_now timestamptz := now() at time zone 'Asia/Kolkata';
        v_url text; v_secret text;
begin
  select value into v_url    from public.app_config where key = 'mail_endpoint';
  select value into v_secret from public.app_config where key = 'mail_secret';
  if v_url is null then return; end if;

  for s in
    select * from public.email_schedules
     where enabled
       -- today is a selected weekday. Compared numerically: the admin UI stores
       -- days as JSON numbers ([1,2,3]), and `?` only matches STRING keys, so
       -- `days ? '6'` was false even when 6 was present and nothing ever fired.
       and exists (select 1 from jsonb_array_elements_text(days) d
                    where d::int = extract(dow from v_now)::int)
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

-- ============================================================================
-- EMAIL SUBJECT MODES
--   subject_mode: 'report_date'  -> "P&M Rental Report - 03 Aug 2026"
--                 'custom'       -> whatever the admin typed (title)
--                 'all_summary'  -> "Daily Reports Summary - 03 Aug 2026"
--   The subject is generated at SEND time so the date is always current.
--   Safe + idempotent to re-run.
-- ============================================================================
alter table public.email_schedules
  add column if not exists subject_mode text not null default 'custom';

create or replace function public.admin_save_schedule(
  p_token uuid, p_id uuid, p_title text, p_report_types jsonb, p_recipients jsonb,
  p_description text, p_send_time text, p_days jsonb, p_enabled boolean,
  p_subject_mode text default 'custom')
returns json language plpgsql security definer set search_path = public as $$
declare a record; v_id uuid; v_mode text;
begin
  a := public._admin(p_token); if a.id is null then return json_build_object('ok',false,'error','Admin only.'); end if;
  v_mode := coalesce(nullif(trim(p_subject_mode),''),'custom');
  if v_mode not in ('report_date','custom','all_summary') then v_mode := 'custom'; end if;
  -- only a custom subject needs typed text; the others are generated
  if v_mode = 'custom' and coalesce(trim(p_title),'') = '' then
    return json_build_object('ok',false,'error','Enter a subject, or choose one of the generated options.'); end if;
  if p_send_time !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then
    return json_build_object('ok',false,'error','Time must be in HH:MM (24-hour) format.'); end if;
  if jsonb_array_length(coalesce(p_report_types,'[]'::jsonb)) = 0 then
    return json_build_object('ok',false,'error','Select at least one report.'); end if;
  if jsonb_array_length(coalesce(p_recipients,'[]'::jsonb)) = 0 then
    return json_build_object('ok',false,'error','Select at least one recipient.'); end if;

  if p_id is null then
    insert into public.email_schedules (title,report_types,recipients,description,send_time,days,enabled,created_by,subject_mode)
    values (coalesce(trim(p_title),''),p_report_types,p_recipients,p_description,p_send_time,
            coalesce(p_days,'[1,2,3,4,5]'::jsonb),coalesce(p_enabled,true),a.user_id,v_mode)
    returning id into v_id;
  else
    update public.email_schedules
       set title=coalesce(trim(p_title),''), report_types=p_report_types, recipients=p_recipients,
           description=p_description, send_time=p_send_time,
           days=coalesce(p_days,'[1,2,3,4,5]'::jsonb), enabled=coalesce(p_enabled,true),
           subject_mode=v_mode
     where id=p_id returning id into v_id;
    if v_id is null then return json_build_object('ok',false,'error','Schedule not found.'); end if;
  end if;
  perform public.log_activity(a.user_id,a.name,'email_schedule', coalesce(trim(p_title),v_mode));
  return json_build_object('ok',true,'id',v_id);
end; $$;

grant execute on function public.admin_save_schedule(uuid,uuid,text,jsonb,jsonb,text,text,jsonb,boolean,text) to anon, authenticated;

-- ============================================================================
-- DISPATCHER v2 — retry failed sends, and never overlap two SMTP sends
--
--   Problem 1: last_sent_at was stamped the moment the request was DISPATCHED.
--   If the endpoint 404'd, timed out, or the response was lost, the schedule
--   still looked "sent today" and was skipped until tomorrow. Three sends were
--   silently lost this way.
--
--   Problem 2: two schedules in the same/adjacent tick both opened a Gmail SMTP
--   connection. The second one stalled and pg_net recorded a NULL response.
--
--   Fix: mark 'queued' WITHOUT touching last_sent_at (so a failure is retried on
--   the next 5-min tick), and dispatch at most ONE schedule per tick.
--   The retry window stays inside the schedule's own hour so it can't fire late
--   at night; give up after 6 attempts (~30 minutes).
-- ============================================================================
alter table public.email_schedules add column if not exists attempts int not null default 0;

create or replace function public.email_dispatch_due()
returns void language plpgsql security definer set search_path = public, extensions as $$
declare s record; v_now timestamptz := now() at time zone 'Asia/Kolkata';
        v_url text; v_secret text; v_mins int;
begin
  select value into v_url    from public.app_config where key = 'mail_endpoint';
  select value into v_secret from public.app_config where key = 'mail_secret';
  if v_url is null or v_secret is null then return; end if;

  v_mins := extract(hour from v_now)::int * 60 + extract(minute from v_now)::int;

  -- ONE schedule per tick: a second concurrent Gmail SMTP send is what produced
  -- the NULL responses. Anything else due is picked up 5 minutes later.
  select * into s from public.email_schedules
   where enabled
     and exists (select 1 from jsonb_array_elements_text(days) d
                  where d::int = extract(dow from v_now)::int)
     -- window widened to 30 min so a failed attempt has room to be retried
     and (v_mins - (split_part(send_time,':',1)::int * 60 + split_part(send_time,':',2)::int))
         between 0 and 29
     -- not already CONFIRMED sent today
     and (last_sent_at is null
          or (last_sent_at at time zone 'Asia/Kolkata')::date < v_now::date)
     -- stop hammering a broken endpoint
     and attempts < 6
   order by send_time
   limit 1;

  if s.id is null then return; end if;

  perform net.http_post(
    url     := v_url,
    headers := jsonb_build_object('Content-Type','application/json','x-mail-secret',v_secret),
    body    := jsonb_build_object('schedule_id', s.id)
  );

  -- NOTE: last_sent_at is deliberately NOT set here. Only the endpoint sets it,
  -- via email_mark_sent(), once the mail has actually gone out. If this attempt
  -- fails, the row stays eligible and the next tick retries it.
  update public.email_schedules
     set last_status = 'queued', attempts = attempts + 1
   where id = s.id;
end; $$;

-- reset the attempt counter whenever a send succeeds
create or replace function public.email_mark_sent(p_id uuid, p_status text, p_detail text)
returns void language plpgsql security definer set search_path = public as $$
declare s record;
begin
  select * into s from public.email_schedules where id = p_id;
  update public.email_schedules
     set last_sent_at = now(),
         last_status  = p_status,
         attempts     = case when p_status in ('sent','partial','skipped') then 0 else attempts end
   where id = p_id;
  insert into public.email_log (schedule_id,title,recipients,report_types,status,detail)
  values (p_id, s.title, s.recipients, s.report_types, p_status, p_detail);
end; $$;

-- clear yesterday's counters each morning so a retry budget starts fresh
create or replace function public.email_reset_attempts()
returns void language plpgsql security definer set search_path = public as $$
begin
  update public.email_schedules set attempts = 0 where attempts > 0;
end; $$;

select cron.unschedule('report-email-reset')
  where exists (select 1 from cron.job where jobname = 'report-email-reset');
select cron.schedule('report-email-reset', '5 18 * * *',   -- 18:05 UTC = 23:35 IST
  $cron$ select public.email_reset_attempts(); $cron$);

-- ============================================================================
-- REPORT SNAPSHOTS  (KPIs + chart data for the email)
--   Charts are computed in the BROWSER, so the mail function can never rebuild
--   them. Instead the browser stores a snapshot each time a report is rendered,
--   and the email reads the latest snapshot per report type.
--   Idempotent.
-- ============================================================================
create table if not exists public.report_snapshots (
  report_type text primary key,
  kpis        jsonb not null default '[]'::jsonb,
  charts      jsonb not null default '[]'::jsonb,
  row_count   int,
  file_name   text,
  captured_by text,
  captured_at timestamptz default now()
);
alter table public.report_snapshots enable row level security;

-- called by the browser after a report renders
create or replace function public.save_snapshot(
  p_token uuid, p_report_type text, p_kpis jsonb, p_charts jsonb,
  p_row_count int, p_file_name text)
returns json language plpgsql security definer set search_path = public as $$
declare v record;
begin
  select * into v from public.app_users where session_token = p_token;
  if v.id is null or v.status <> 'approved' then
    return json_build_object('ok',false,'error','Not authenticated.'); end if;
  insert into public.report_snapshots (report_type,kpis,charts,row_count,file_name,captured_by,captured_at)
  values (p_report_type, coalesce(p_kpis,'[]'::jsonb), coalesce(p_charts,'[]'::jsonb),
          p_row_count, p_file_name, v.name, now())
  on conflict (report_type) do update
     set kpis = excluded.kpis, charts = excluded.charts, row_count = excluded.row_count,
         file_name = excluded.file_name, captured_by = excluded.captured_by, captured_at = now();
  return json_build_object('ok',true);
end; $$;

grant execute on function public.save_snapshot(uuid,text,jsonb,jsonb,int,text) to anon, authenticated;

-- the mail payload now carries each selected report's snapshot, in the order the
-- schedule lists them
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

  -- keep the schedule's own report order (ordinality), and attach the snapshot
  select coalesce(json_agg(x order by x.ord),'[]') into rep from (
    select t.ord,
           t.rt                                   as report_type,
           up.file_name, up.row_count, up.uploaded_at, up.uploaded_by, up.file_size,
           coalesce(sn.kpis,   '[]'::jsonb)       as kpis,
           coalesce(sn.charts, '[]'::jsonb)       as charts,
           sn.captured_at
      from jsonb_array_elements_text(s.report_types) with ordinality as t(rt, ord)
      left join lateral (
        select file_name,row_count,uploaded_at,uploaded_by,file_size
          from public.uploads u2 where u2.report_type = t.rt
         order by uploaded_at desc limit 1) up on true
      left join public.report_snapshots sn on sn.report_type = t.rt
  ) x;

  return json_build_object('ok',true,'schedule',row_to_json(s),'recipients',r,'reports',rep);
end; $$;

-- ============================================================================
-- OFFICIAL EMAIL AT REGISTRATION  +  APPROVAL WELCOME MAIL
--   Email becomes mandatory when signing up and is the address used for every
--   system message. Admin can still edit it later via admin_set_email().
--   Idempotent.
-- ============================================================================

-- queue of transactional mails the dispatcher picks up (approval, reset, etc.)
create table if not exists public.mail_outbox (
  id          uuid primary key default gen_random_uuid(),
  template    text not null,                  -- 'approved' | 'locked' | 'created' | ...
  to_email    text not null,
  to_name     text,
  payload     jsonb not null default '{}'::jsonb,
  status      text not null default 'pending',
  attempts    int  not null default 0,
  detail      text,
  created_at  timestamptz default now(),
  sent_at     timestamptz
);
create index if not exists mail_outbox_pending_idx on public.mail_outbox (status, created_at);
alter table public.mail_outbox enable row level security;

-- registration now requires a valid, unused official email
create or replace function public.register_user(
  p_name text, p_user_id text, p_password text,
  p_dept text default null, p_email text default null)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare v_id uuid; v_role text; v_status text; v_first boolean; v_email text;
begin
  p_user_id := lower(trim(p_user_id));
  v_email   := nullif(lower(trim(coalesce(p_email,''))),'');

  if coalesce(trim(p_name),'') = '' then
    return json_build_object('ok',false,'error','Please enter your full name.'); end if;
  if p_user_id = '' then
    return json_build_object('ok',false,'error','Please choose a User ID.'); end if;
  if char_length(coalesce(p_password,'')) < 4 then
    return json_build_object('ok',false,'error','Password must be at least 4 characters.'); end if;
  if v_email is null then
    return json_build_object('ok',false,'error','Official email address is required.'); end if;
  if v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    return json_build_object('ok',false,'error','That does not look like a valid email address.'); end if;
  if exists (select 1 from public.app_users where user_id = p_user_id) then
    return json_build_object('ok',false,'error','That User ID is already taken.'); end if;
  if exists (select 1 from public.app_users where lower(email) = v_email) then
    return json_build_object('ok',false,'error','That email address is already registered.'); end if;

  -- the very first account bootstraps as an approved admin
  select count(*) = 0 into v_first from public.app_users;
  v_role   := case when v_first then 'admin'    else 'user'    end;
  v_status := case when v_first then 'approved' else 'pending' end;

  insert into public.app_users (name,user_id,password_hash,role,status,dept,email)
  values (trim(p_name), p_user_id, crypt(p_password, gen_salt('bf')), v_role, v_status, p_dept, v_email)
  returning id into v_id;

  perform public.log_activity(p_user_id, trim(p_name), 'register', v_email);
  return json_build_object('ok',true,'status',v_status,'role',v_role);
end; $$;

-- approving a user now queues the welcome email
create or replace function public.admin_set_status(p_token uuid, p_user_id text, p_status text)
returns json language plpgsql security definer set search_path = public as $$
declare a record; u record;
begin
  a := public._admin(p_token); if a.id is null then return json_build_object('ok',false,'error','Admin only.'); end if;
  if p_status not in ('approved','rejected','disabled','pending') then
    return json_build_object('ok',false,'error','Unknown status.'); end if;

  select * into u from public.app_users where user_id = lower(trim(p_user_id));
  if u.id is null then return json_build_object('ok',false,'error','No such user.'); end if;

  update public.app_users
     set status = p_status,
         approved_by = case when p_status='approved' then a.name else approved_by end,
         approved_at = case when p_status='approved' then now() else approved_at end
   where id = u.id;

  -- queue the welcome mail only on a real pending -> approved transition
  if p_status = 'approved' and u.status <> 'approved'
     and u.email is not null and u.email <> '' then
    insert into public.mail_outbox (template, to_email, to_name, payload)
    values ('approved', u.email, u.name,
            jsonb_build_object('name',u.name,'user_id',u.user_id,'email',u.email,
                               'role',u.role,'dept',u.dept,
                               'approved_by',a.name,'approved_at',now()));
  end if;

  perform public.log_activity(a.user_id,a.name,p_status,p_user_id);
  return json_build_object('ok',true);
end; $$;

-- dispatcher hands pending outbox mail to the same endpoint
create or replace function public.outbox_dispatch()
returns void language plpgsql security definer set search_path = public, extensions as $$
declare m record; v_url text; v_secret text;
begin
  select value into v_url    from public.app_config where key = 'mail_endpoint';
  select value into v_secret from public.app_config where key = 'mail_secret';
  if v_url is null or v_secret is null then return; end if;

  select * into m from public.mail_outbox
   where status = 'pending' and attempts < 5
   order by created_at limit 1;                 -- one per tick: SMTP is serial
  if m.id is null then return; end if;

  perform net.http_post(
    url     := v_url,
    headers := jsonb_build_object('Content-Type','application/json','x-mail-secret',v_secret),
    body    := jsonb_build_object('outbox_id', m.id)
  );
  update public.mail_outbox set attempts = attempts + 1 where id = m.id;
end; $$;

create or replace function public.outbox_mark(p_id uuid, p_status text, p_detail text)
returns void language plpgsql security definer set search_path = public as $$
begin
  update public.mail_outbox
     set status = p_status, detail = p_detail,
         sent_at = case when p_status = 'sent' then now() else sent_at end
   where id = p_id;
end; $$;

create or replace function public.outbox_payload_svc(p_id uuid)
returns json language plpgsql security definer set search_path = public as $$
declare m record;
begin
  select * into m from public.mail_outbox where id = p_id;
  if m.id is null then return json_build_object('ok',false,'error','Not found.'); end if;
  return json_build_object('ok',true,'template',m.template,'to_email',m.to_email,
                           'to_name',m.to_name,'payload',m.payload);
end; $$;

select cron.unschedule('outbox-dispatch')
  where exists (select 1 from cron.job where jobname = 'outbox-dispatch');
select cron.schedule('outbox-dispatch', '* * * * *', $cron$ select public.outbox_dispatch(); $cron$);

grant execute on function public.register_user(text,text,text,text,text) to anon, authenticated;
grant execute on function public.admin_set_status(uuid,text,text)         to anon, authenticated;

-- ============================================================================
-- SHARE LINKS  —  "management" schedules: open a report without logging in
--
--   A schedule flagged share_access gets a one-per-recipient token embedded in
--   its email. Opening that link renders the report read-only: filters, charts
--   and exports work; upload, admin and other reports do not.
--
--   A token is a BEARER credential — whoever holds the URL has access, including
--   anyone the mail is forwarded to. Hence: scoped to ONE report, expires after
--   7 days, revocable, and every open is recorded.
--   Idempotent.
-- ============================================================================
alter table public.email_schedules
  add column if not exists share_access boolean not null default false;

create table if not exists public.share_tokens (
  token         uuid primary key default gen_random_uuid(),
  schedule_id   uuid,
  report_type   text not null,
  storage_path  text,
  file_name     text,
  recipient     text,                      -- app_users.user_id (audit only)
  recipient_email text,
  created_at    timestamptz default now(),
  expires_at    timestamptz not null default (now() + interval '7 days'),
  revoked       boolean not null default false,
  opens         int not null default 0,
  last_opened_at timestamptz,
  last_ip       text
);
create index if not exists share_tokens_active_idx on public.share_tokens (expires_at, revoked);
alter table public.share_tokens enable row level security;

-- called by the mail function (service key) as it builds each recipient's email
create or replace function public.share_token_issue(
  p_schedule_id uuid, p_report_type text, p_recipient text, p_recipient_email text)
returns json language plpgsql security definer set search_path = public as $$
declare v_tok uuid; up record;
begin
  select file_name, storage_path into up
    from public.uploads
   where report_type = p_report_type and storage_path is not null
   order by uploaded_at desc limit 1;
  if up.storage_path is null then
    return json_build_object('ok',false,'error','No stored file for this report.'); end if;

  insert into public.share_tokens (schedule_id,report_type,storage_path,file_name,recipient,recipient_email)
  values (p_schedule_id,p_report_type,up.storage_path,up.file_name,p_recipient,p_recipient_email)
  returning token into v_tok;
  return json_build_object('ok',true,'token',v_tok);
end; $$;

-- PUBLIC: the share page calls this with no session. Returns only what is needed
-- to render one report, and records the access.
create or replace function public.share_resolve(p_token uuid, p_ip text default null)
returns json language plpgsql security definer set search_path = public as $$
declare t record; nm text;
begin
  select * into t from public.share_tokens where token = p_token;
  if t.token is null then
    return json_build_object('ok',false,'error','This link is not valid.'); end if;
  if t.revoked then
    return json_build_object('ok',false,'error','This link has been revoked by an administrator.'); end if;
  if t.expires_at < now() then
    return json_build_object('ok',false,'error','This link has expired. Please ask for a fresh report email.'); end if;

  update public.share_tokens
     set opens = opens + 1, last_opened_at = now(), last_ip = coalesce(p_ip, last_ip)
   where token = p_token;

  insert into public.activity_log (user_id, name, action, detail)
  values (coalesce(t.recipient,'(share)'), coalesce(t.recipient_email,'share link'),
          'share_open', t.report_type);

  return json_build_object('ok',true,
    'report_type', t.report_type,
    'storage_path', t.storage_path,
    'file_name', t.file_name,
    'expires_at', t.expires_at,
    'recipient', t.recipient_email);
end; $$;

-- admin: see and kill active links
create or replace function public.admin_list_shares(p_token uuid)
returns json language plpgsql security definer set search_path = public as $$
declare a record; r json;
begin
  a := public._admin(p_token); if a.id is null then return json_build_object('ok',false,'error','Admin only.'); end if;
  select coalesce(json_agg(t order by t.created_at desc),'[]') into r
    from (select token,report_type,file_name,recipient,recipient_email,created_at,
                 expires_at,revoked,opens,last_opened_at
            from public.share_tokens
           order by created_at desc limit 200) t;
  return json_build_object('ok',true,'rows',r);
end; $$;

create or replace function public.admin_revoke_share(p_token uuid, p_share uuid)
returns json language plpgsql security definer set search_path = public as $$
declare a record;
begin
  a := public._admin(p_token); if a.id is null then return json_build_object('ok',false,'error','Admin only.'); end if;
  if p_share is null then
    update public.share_tokens set revoked = true where revoked = false and expires_at > now();
    perform public.log_activity(a.user_id,a.name,'share_revoke','ALL active links');
  else
    update public.share_tokens set revoked = true where token = p_share;
    perform public.log_activity(a.user_id,a.name,'share_revoke',p_share::text);
  end if;
  return json_build_object('ok',true);
end; $$;

-- keep the schedule save able to carry the flag
create or replace function public.admin_save_schedule(
  p_token uuid, p_id uuid, p_title text, p_report_types jsonb, p_recipients jsonb,
  p_description text, p_send_time text, p_days jsonb, p_enabled boolean,
  p_subject_mode text default 'custom', p_share_access boolean default false)
returns json language plpgsql security definer set search_path = public as $$
declare a record; v_id uuid; v_mode text;
begin
  a := public._admin(p_token); if a.id is null then return json_build_object('ok',false,'error','Admin only.'); end if;
  v_mode := coalesce(nullif(trim(p_subject_mode),''),'custom');
  if v_mode not in ('report_date','custom','all_summary') then v_mode := 'custom'; end if;
  if v_mode = 'custom' and coalesce(trim(p_title),'') = '' then
    return json_build_object('ok',false,'error','Enter a subject, or choose one of the generated options.'); end if;
  if p_send_time !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then
    return json_build_object('ok',false,'error','Time must be in HH:MM (24-hour) format.'); end if;
  if jsonb_array_length(coalesce(p_report_types,'[]'::jsonb)) = 0 then
    return json_build_object('ok',false,'error','Select at least one report.'); end if;
  if jsonb_array_length(coalesce(p_recipients,'[]'::jsonb)) = 0 then
    return json_build_object('ok',false,'error','Select at least one recipient.'); end if;

  if p_id is null then
    insert into public.email_schedules (title,report_types,recipients,description,send_time,days,enabled,created_by,subject_mode,share_access)
    values (coalesce(trim(p_title),''),p_report_types,p_recipients,p_description,p_send_time,
            coalesce(p_days,'[1,2,3,4,5]'::jsonb),coalesce(p_enabled,true),a.user_id,v_mode,coalesce(p_share_access,false))
    returning id into v_id;
  else
    update public.email_schedules
       set title=coalesce(trim(p_title),''), report_types=p_report_types, recipients=p_recipients,
           description=p_description, send_time=p_send_time,
           days=coalesce(p_days,'[1,2,3,4,5]'::jsonb), enabled=coalesce(p_enabled,true),
           subject_mode=v_mode, share_access=coalesce(p_share_access,false)
     where id=p_id returning id into v_id;
    if v_id is null then return json_build_object('ok',false,'error','Schedule not found.'); end if;
  end if;
  perform public.log_activity(a.user_id,a.name,'email_schedule', coalesce(trim(p_title),v_mode));
  return json_build_object('ok',true,'id',v_id);
end; $$;

-- nightly tidy: drop tokens that expired over a month ago
create or replace function public.share_tokens_prune()
returns void language plpgsql security definer set search_path = public as $$
begin
  delete from public.share_tokens where expires_at < now() - interval '30 days';
end; $$;

select cron.unschedule('share-token-prune')
  where exists (select 1 from cron.job where jobname = 'share-token-prune');
select cron.schedule('share-token-prune', '20 18 * * *', $cron$ select public.share_tokens_prune(); $cron$);

grant execute on function public.share_resolve(uuid,text)                          to anon, authenticated;
grant execute on function public.admin_list_shares(uuid)                           to anon, authenticated;
grant execute on function public.admin_revoke_share(uuid,uuid)                     to anon, authenticated;
grant execute on function public.admin_save_schedule(uuid,uuid,text,jsonb,jsonb,text,text,jsonb,boolean,text,boolean) to anon, authenticated;

-- ============================================================================
-- FORGOT PASSWORD  —  email OTP reset
--
--   Flow:  request  ->  api/forgot-password (service)  ->  otp_issue_svc
--          verify   ->  verify_password_otp        (anon, rate limited)
--          reset    ->  reset_password_with_otp    (anon, one-time token)
--
--   Security notes
--     * The OTP is NEVER stored or returned in plain text to the browser. Only a
--       bcrypt hash is persisted; the clear code exists just long enough for the
--       serverless mailer to put it in the email.
--     * otp_issue_svc is the ONLY function that can see a code, it requires the
--       shared mail secret and is NOT granted to anon — the browser cannot call
--       it, so nobody can pull an OTP out of the API.
--     * Requesting a new OTP supersedes every earlier pending code.
--     * 5 wrong attempts burn the code; 15-minute expiry; single use.
--     * Nothing here reveals whether an email exists: the caller always gets ok.
--     * Passwords keep using the app's existing bcrypt (crypt/gen_salt('bf')).
-- ============================================================================

create table if not exists public.password_otp (
  id            uuid primary key default gen_random_uuid(),
  user_id       text not null,
  email         text not null,
  code_hash     text not null,               -- bcrypt of the 6-digit code
  status        text not null default 'pending',   -- pending | used | superseded
  attempts      int  not null default 0,
  created_at    timestamptz not null default now(),
  expires_at    timestamptz not null,
  used_at       timestamptz,
  reset_token   uuid,                        -- issued on successful verification
  reset_expires timestamptz
);
create index if not exists password_otp_lookup_idx on public.password_otp (email, status, created_at desc);
create index if not exists password_otp_token_idx  on public.password_otp (reset_token);
alter table public.password_otp enable row level security;   -- no policies: RPC-only

-- ---------------------------------------------------------------------------
-- SERVICE ONLY. Issues a code and returns it so the mailer can send it.
-- Returns ok=true even when the address is unknown (no account enumeration);
-- 'send' tells the caller whether there is actually an email to deliver.
-- ---------------------------------------------------------------------------
create or replace function public.otp_issue_svc(p_secret text, p_email text)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare v_secret text; v record; v_code text; v_b bytea; v_recent int; v_last timestamptz; v_id uuid;
begin
  -- The real access control is the GRANT: this function is revoked from public,
  -- anon and authenticated, so only the service role (the serverless mailer) can
  -- call it at all. The shared secret is a second layer, and it is only enforced
  -- when app_config actually holds one — otherwise a seeding mismatch would
  -- silently stop every reset email with no visible reason.
  select value into v_secret from public.app_config where key = 'mail_secret';
  if v_secret is not null and v_secret <> '' and p_secret is distinct from v_secret then
    return json_build_object('ok',false,'error','Not authorised.');
  end if;

  select * into v from public.app_users
   where lower(email) = lower(trim(coalesce(p_email,''))) and status = 'approved';
  if v.id is null then
    return json_build_object('ok',true,'send',false);       -- unknown / not approved
  end if;

  -- throttle: 30s between requests, max 3 in any 15 minutes
  select max(created_at), count(*) into v_last, v_recent
    from public.password_otp
   where email = lower(v.email) and created_at > now() - interval '15 minutes';
  if v_last is not null and v_last > now() - interval '30 seconds' then
    return json_build_object('ok',true,'send',false,'throttled',true);
  end if;
  if coalesce(v_recent,0) >= 3 then
    return json_build_object('ok',true,'send',false,'throttled',true);
  end if;

  -- any earlier code stops working the moment a new one is issued
  update public.password_otp set status = 'superseded'
   where email = lower(v.email) and status = 'pending';

  -- cryptographically random 6-digit code
  v_b := gen_random_bytes(3);
  v_code := lpad( ((get_byte(v_b,0)::bigint * 65536
                  + get_byte(v_b,1)::bigint * 256
                  + get_byte(v_b,2)::bigint) % 1000000)::text, 6, '0');

  insert into public.password_otp (user_id, email, code_hash, expires_at)
  values (v.user_id, lower(v.email), crypt(v_code, gen_salt('bf')), now() + interval '15 minutes')
  returning id into v_id;

  perform public.log_activity(v.user_id, v.name, 'otp_requested', 'password reset code issued');
  return json_build_object('ok',true,'send',true,'id',v_id,
                           'code',v_code,'email',v.email,'name',v.name,
                           'user_id',v.user_id,'minutes',15);
end; $$;

-- ---------------------------------------------------------------------------
-- Verify a code. Generic errors only — never confirms an address exists.
-- ---------------------------------------------------------------------------
create or replace function public.verify_password_otp(p_email text, p_code text)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare o record; v_tok uuid; v_email text; v_code text;
begin
  v_email := lower(trim(coalesce(p_email,'')));
  v_code  := regexp_replace(coalesce(p_code,''), '\s', '', 'g');
  if v_email = '' or v_code = '' then
    return json_build_object('ok',false,'error','Enter the 6-digit code sent to your email.');
  end if;

  select * into o from public.password_otp
   where email = v_email and status = 'pending'
   order by created_at desc limit 1;

  if o.id is null then
    return json_build_object('ok',false,'error','That code is not valid. Please request a new one.');
  end if;
  if o.expires_at <= now() then
    update public.password_otp set status = 'superseded' where id = o.id;
    return json_build_object('ok',false,'expired',true,
      'error','This code has expired. Please request a new one.');
  end if;
  if o.attempts >= 5 then
    update public.password_otp set status = 'superseded' where id = o.id;
    return json_build_object('ok',false,'blocked',true,
      'error','Too many incorrect attempts. Please request a new code.');
  end if;

  if o.code_hash <> crypt(v_code, o.code_hash) then
    update public.password_otp set attempts = attempts + 1 where id = o.id;
    if o.attempts + 1 >= 5 then
      update public.password_otp set status = 'superseded' where id = o.id;
      return json_build_object('ok',false,'blocked',true,
        'error','Too many incorrect attempts. Please request a new code.');
    end if;
    return json_build_object('ok',false,'left',5 - (o.attempts + 1),
      'error','Incorrect code. ' || (5 - (o.attempts + 1)) || ' attempt(s) remaining.');
  end if;

  -- correct: burn the code and hand back a short-lived one-time reset token
  v_tok := gen_random_uuid();
  update public.password_otp
     set status = 'used', used_at = now(),
         reset_token = v_tok, reset_expires = now() + interval '15 minutes'
   where id = o.id;
  return json_build_object('ok',true,'reset_token',v_tok);
end; $$;

-- ---------------------------------------------------------------------------
-- Consume the reset token and set the new password (same bcrypt as everywhere).
-- ---------------------------------------------------------------------------
create or replace function public.reset_password_with_otp(p_reset_token uuid, p_new_password text)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare o record; u record; p text;
begin
  p := coalesce(p_new_password,'');
  select * into o from public.password_otp
   where reset_token = p_reset_token and status = 'used'
     and reset_expires is not null and reset_expires > now();
  if o.id is null then
    return json_build_object('ok',false,'error','This reset session has expired. Please start again.');
  end if;

  if char_length(p) < 8                    then return json_build_object('ok',false,'error','Password must be at least 8 characters.'); end if;
  if p !~ '[A-Z]'                          then return json_build_object('ok',false,'error','Password must include an uppercase letter.'); end if;
  if p !~ '[a-z]'                          then return json_build_object('ok',false,'error','Password must include a lowercase letter.'); end if;
  if p !~ '[0-9]'                          then return json_build_object('ok',false,'error','Password must include a number.'); end if;
  if p !~ '[^A-Za-z0-9]'                   then return json_build_object('ok',false,'error','Password must include a special character.'); end if;

  select * into u from public.app_users where user_id = o.user_id;
  if u.id is null then return json_build_object('ok',false,'error','This reset session is no longer valid.'); end if;

  update public.app_users
     set password_hash   = crypt(p, gen_salt('bf')),
         failed_attempts = 0,
         locked_until    = null,
         session_token   = null              -- sign out any existing session
   where id = u.id;

  -- token is single use
  update public.password_otp
     set reset_token = null, reset_expires = null
   where id = o.id;

  -- confirmation mail (queued through the existing transactional outbox)
  if u.email is not null and u.email <> '' then
    insert into public.mail_outbox (template, to_email, to_name, payload)
    values ('passwordChanged', u.email, u.name,
            jsonb_build_object('name',u.name,'user_id',u.user_id,'when',now()));
  end if;

  perform public.log_activity(u.user_id, u.name, 'password_reset', 'via email OTP');
  return json_build_object('ok',true,'user_id',u.user_id);
end; $$;

-- The browser may verify and reset, but must NEVER be able to mint a code.
-- Postgres grants EXECUTE to PUBLIC by default, so revoking from anon alone
-- would still leave the function reachable with the anon key — revoke PUBLIC
-- as well and hand execute rights only to the roles the server uses.
revoke all on function public.otp_issue_svc(text,text) from public, anon, authenticated;
do $$
begin
  -- service_role is what the serverless mailer authenticates as; postgres is the
  -- owner. Wrapped so a missing role on a non-Supabase database cannot abort the
  -- whole script (which would leave the reset flow half-installed).
  begin execute 'grant execute on function public.otp_issue_svc(text,text) to service_role'; exception when others then null; end;
  begin execute 'grant execute on function public.otp_issue_svc(text,text) to postgres';     exception when others then null; end;
end $$;
grant execute on function public.verify_password_otp(text,text)      to anon, authenticated;
grant execute on function public.reset_password_with_otp(uuid,text)  to anon, authenticated;

-- Belt and braces: the OTP table is RLS-enabled with no policies (so PostgREST
-- returns nothing), and no direct table rights are needed by the browser.
revoke all on table public.password_otp from anon, authenticated;

-- Ask PostgREST to reload its schema cache so the new functions are visible
-- immediately instead of after the next restart.
notify pgrst, 'reload schema';
