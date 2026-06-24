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
  if length(coalesce(p_password,''))<8 or p_password !~ '[A-Z]' or p_password !~ '[a-z]'
     or p_password !~ '[0-9]' or p_password !~ '[^A-Za-z0-9]' then
    return json_build_object('ok',false,'error','Password needs 8+ chars with upper, lower, number and special character.'); end if;
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
  if length(coalesce(p_new,''))<8 or p_new !~ '[A-Z]' or p_new !~ '[a-z]' or p_new !~ '[0-9]' or p_new !~ '[^A-Za-z0-9]' then
    return json_build_object('ok',false,'error','New password needs 8+ chars with upper, lower, number and special character.'); end if;
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
  if length(coalesce(p_new_password,''))<8 then return json_build_object('ok',false,'error','Password must be 8+ characters.'); end if;
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
             'add_upload','list_my_uploads','delete_upload','log_report','list_my_reports',
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
