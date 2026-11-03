-- Knight Academy: secure roles, teacher invitations, publishing, and rewards.
-- Run once in Supabase SQL Editor. Safe to re-run.

-- Every Auth user gets a default pending student profile.
create or replace function public.ka_on_auth_user_created()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  insert into public.ka_profiles (id, role, approved)
  values (new.id, 'student', false)
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists ka_auth_user_profile on auth.users;
create trigger ka_auth_user_profile
after insert on auth.users
for each row execute function public.ka_on_auth_user_created();

-- Backfill Auth users that were created before the trigger existed.
insert into public.ka_profiles (id, role, approved)
select u.id, 'student', false
from auth.users u
left join public.ka_profiles p on p.id = u.id
where p.id is null
on conflict (id) do nothing;

-- Creator-only, safe list of approved accounts.
create or replace function public.ka_creator_list_users_v2()
returns table(user_id uuid, full_name text, email text, role text, approved boolean)
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
begin
  if not exists (
    select 1 from public.ka_profiles p
    where p.id = auth.uid() and p.role::text = 'creator' and p.approved is true
  ) then
    raise exception 'اجازه دسترسی ندارید.' using errcode = '42501';
  end if;
  return query
    select p.id,
      coalesce(u.raw_user_meta_data->>'full_name', ''),
      coalesce(u.email, ''),
      p.role::text,
      p.approved
    from public.ka_profiles p
    join auth.users u on u.id = p.id
    where p.approved is true
    order by lower(coalesce(u.raw_user_meta_data->>'full_name', u.email, ''));
end;
$$;

-- Creator-only list of pending registrations.
create or replace function public.ka_creator_list_pending_users_v2()
returns table(user_id uuid, full_name text, email text, created_at timestamptz)
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
begin
  if not exists (
    select 1 from public.ka_profiles p
    where p.id = auth.uid() and p.role::text = 'creator' and p.approved is true
  ) then
    raise exception 'اجازه دسترسی ندارید.' using errcode = '42501';
  end if;
  return query
    select p.id,
      coalesce(u.raw_user_meta_data->>'full_name', ''),
      coalesce(u.email, ''),
      u.created_at
    from public.ka_profiles p
    join auth.users u on u.id = p.id
    where p.approved is not true and p.role::text = 'student'
    order by u.created_at asc;
end;
$$;

-- Creator may grant student, teacher, or admin; never creator.
create or replace function public.ka_creator_set_user_role(target_id uuid, new_role text)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare target_role text;
begin
  if not exists (
    select 1 from public.ka_profiles p
    where p.id = auth.uid() and p.role::text = 'creator' and p.approved is true
  ) then
    raise exception 'فقط Creator اجازه تغییر نقش دارد.' using errcode = '42501';
  end if;
  if new_role not in ('student', 'teacher', 'admin') then
    raise exception 'این نقش قابل واگذاری نیست.';
  end if;
  if target_id = auth.uid() then
    raise exception 'تغییر نقش حساب مالک اصلی مجاز نیست.';
  end if;
  select p.role::text into target_role
  from public.ka_profiles p where p.id = target_id and p.approved is true;
  if target_role is null or target_role = 'creator' then
    raise exception 'حساب هدف پیدا نشد یا قابل تغییر نیست.';
  end if;
  execute format('update public.ka_profiles set role = %L where id = $1', new_role) using target_id;
end;
$$;

-- Creator approves a pending student account.
create or replace function public.ka_creator_approve_signup(target_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not exists (
    select 1 from public.ka_profiles p
    where p.id = auth.uid() and p.role::text = 'creator' and p.approved is true
  ) then
    raise exception 'فقط Creator اجازه تأیید ثبت‌نام دارد.' using errcode = '42501';
  end if;
  update public.ka_profiles
  set approved = true
  where id = target_id and role::text = 'student' and approved is not true;
  if not found then
    raise exception 'درخواست در انتظار تأیید پیدا نشد.';
  end if;
end;
$$;

-- Creator can add a published or draft lesson without exposing table write privileges.
create or replace function public.ka_creator_create_lesson(
  lesson_title text,
  lesson_description text default '',
  make_published boolean default false
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare new_id uuid;
begin
  if not exists (
    select 1 from public.ka_profiles p
    where p.id = auth.uid() and p.role::text = 'creator' and p.approved is true
  ) then
    raise exception 'فقط Creator اجازه افزودن محتوا دارد.' using errcode = '42501';
  end if;
  if length(trim(coalesce(lesson_title, ''))) < 2 or length(lesson_title) > 150 then
    raise exception 'عنوان درس باید بین ۲ تا ۱۵۰ نویسه باشد.';
  end if;
  insert into public.ka_lessons (title, description, created_by, published)
  values (trim(lesson_title), left(coalesce(lesson_description, ''), 2000), auth.uid(), make_published)
  returning id into new_id;
  return new_id;
end;
$$;

-- Admin can list approved students and teachers, but not administrators or Creator.
create or replace function public.ka_admin_list_people()
returns table(user_id uuid, full_name text, email text, role text)
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
begin
  if not exists (
    select 1 from public.ka_profiles p
    where p.id = auth.uid() and p.role::text = 'admin' and p.approved is true
  ) then
    raise exception 'فقط مدیر تأییدشده اجازه دسترسی دارد.' using errcode = '42501';
  end if;
  return query
    select p.id,
      coalesce(u.raw_user_meta_data->>'full_name', ''),
      coalesce(u.email, ''),
      p.role::text
    from public.ka_profiles p
    join auth.users u on u.id = p.id
    where p.approved is true and p.role::text in ('student', 'teacher')
    order by lower(coalesce(u.raw_user_meta_data->>'full_name', u.email, ''));
end;
$$;

-- Admin may promote approved students to teacher or revoke teacher access.
create or replace function public.ka_admin_set_teacher_role(target_id uuid, new_role text)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare target_role text;
begin
  if not exists (
    select 1 from public.ka_profiles p
    where p.id = auth.uid() and p.role::text = 'admin' and p.approved is true
  ) then
    raise exception 'فقط مدیر تأییدشده اجازه تغییر دسترسی دارد.' using errcode = '42501';
  end if;
  if new_role not in ('student', 'teacher') then
    raise exception 'مدیر فقط می‌تواند دسترسی معلم را فعال یا لغو کند.';
  end if;
  if target_id = auth.uid() then
    raise exception 'تغییر نقش حساب خودتان مجاز نیست.';
  end if;
  select p.role::text into target_role
  from public.ka_profiles p
  where p.id = target_id and p.approved is true;
  if target_role not in ('student', 'teacher') then
    raise exception 'حساب هدف پیدا نشد یا قابل مدیریت نیست.';
  end if;
  execute format('update public.ka_profiles set role = %L where id = $1', new_role) using target_id;
end;
$$;

-- Shared staff list for teacher/admin reward controls.
create or replace function public.ka_staff_list_students()
returns table(student_id uuid, full_name text, email text)
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
begin
  if not exists (
    select 1 from public.ka_profiles p
    where p.id = auth.uid()
      and p.approved is true
      and p.role::text in ('teacher', 'admin')
  ) then
    raise exception 'دسترسی معلم یا مدیر تأییدشده لازم است.' using errcode = '42501';
  end if;
  return query
    select p.id,
      coalesce(u.raw_user_meta_data->>'full_name', ''),
      coalesce(u.email, '')
    from public.ka_profiles p
    join auth.users u on u.id = p.id
    where p.approved is true and p.role::text = 'student'
    order by lower(coalesce(u.raw_user_meta_data->>'full_name', u.email, ''));
end;
$$;

-- Dedicated reward tables: independent of any legacy tables already in the project.
create table if not exists public.ka_effort_awards (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references auth.users(id) on delete cascade,
  awarded_by uuid not null references auth.users(id) on delete restrict,
  awarder_role text not null check (awarder_role in ('teacher', 'admin')),
  note text not null default '',
  created_at timestamptz not null default now()
);

create table if not exists public.ka_effort_certificates (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references auth.users(id) on delete cascade,
  source_role text not null check (source_role in ('teacher', 'admin')),
  milestone_number integer not null check (milestone_number > 0),
  issued_at timestamptz not null default now(),
  unique (student_id, source_role, milestone_number)
);

alter table public.ka_effort_awards enable row level security;
alter table public.ka_effort_certificates enable row level security;

drop policy if exists ka_effort_awards_read on public.ka_effort_awards;
create policy ka_effort_awards_read on public.ka_effort_awards
for select to authenticated
using (
  student_id = auth.uid()
  or awarded_by = auth.uid()
  or exists (
    select 1 from public.ka_profiles p
    where p.id = auth.uid() and p.approved is true and p.role::text in ('teacher', 'admin')
  )
);

drop policy if exists ka_effort_certificates_read on public.ka_effort_certificates;
create policy ka_effort_certificates_read on public.ka_effort_certificates
for select to authenticated
using (
  student_id = auth.uid()
  or exists (
    select 1 from public.ka_profiles p
    where p.id = auth.uid() and p.approved is true and p.role::text in ('teacher', 'admin')
  )
);

grant select on public.ka_effort_awards, public.ka_effort_certificates to authenticated;
revoke insert, update, delete on public.ka_effort_awards, public.ka_effort_certificates from anon, authenticated;

-- Award one card; 10 teacher cards or 1 admin card issue one certificate.
create or replace function public.ka_award_effort_card(target_student uuid, award_note text default '')
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  actor_role text;
  card_total integer;
  certificate_total integer;
  threshold integer;
  milestone integer;
begin
  select p.role::text into actor_role
  from public.ka_profiles p
  where p.id = auth.uid() and p.approved is true
    and p.role::text in ('teacher', 'admin');
  if actor_role is null then
    raise exception 'فقط معلم یا مدیر تأییدشده می‌تواند کارت تلاش بدهد.' using errcode = '42501';
  end if;
  if not exists (
    select 1 from public.ka_profiles p
    where p.id = target_student and p.role::text = 'student' and p.approved is true
  ) then
    raise exception 'دانش‌آموز تأییدشده پیدا نشد.';
  end if;

  perform pg_advisory_xact_lock(hashtext(target_student::text));
  insert into public.ka_effort_awards(student_id, awarded_by, awarder_role, note)
  values (target_student, auth.uid(), actor_role, left(coalesce(award_note, ''), 500));

  select count(*)::integer into card_total
  from public.ka_effort_awards
  where student_id = target_student and awarder_role = actor_role;

  threshold := case when actor_role = 'teacher' then 10 else 1 end;
  milestone := floor(card_total::numeric / threshold)::integer;
  insert into public.ka_effort_certificates(student_id, source_role, milestone_number)
  select target_student, actor_role, n
  from generate_series(1, milestone) as n
  on conflict (student_id, source_role, milestone_number) do nothing;

  select count(*)::integer into certificate_total
  from public.ka_effort_certificates
  where student_id = target_student;

  return jsonb_build_object(
    'card_total', card_total,
    'certificate_total', certificate_total,
    'award_role', actor_role,
    'threshold', threshold
  );
end;
$$;

-- Expose only explicitly guarded RPCs to logged-in users.
revoke all on function public.ka_creator_list_users_v2() from public, anon;
revoke all on function public.ka_creator_list_pending_users_v2() from public, anon;
revoke all on function public.ka_creator_set_user_role(uuid, text) from public, anon;
revoke all on function public.ka_creator_approve_signup(uuid) from public, anon;
revoke all on function public.ka_creator_create_lesson(text, text, boolean) from public, anon;
revoke all on function public.ka_admin_list_people() from public, anon;
revoke all on function public.ka_admin_set_teacher_role(uuid, text) from public, anon;
revoke all on function public.ka_staff_list_students() from public, anon;
revoke all on function public.ka_award_effort_card(uuid, text) from public, anon;

grant execute on function public.ka_creator_list_users_v2() to authenticated;
grant execute on function public.ka_creator_list_pending_users_v2() to authenticated;
grant execute on function public.ka_creator_set_user_role(uuid, text) to authenticated;
grant execute on function public.ka_creator_approve_signup(uuid) to authenticated;
grant execute on function public.ka_creator_create_lesson(text, text, boolean) to authenticated;
grant execute on function public.ka_admin_list_people() to authenticated;
grant execute on function public.ka_admin_set_teacher_role(uuid, text) to authenticated;
grant execute on function public.ka_staff_list_students() to authenticated;
grant execute on function public.ka_award_effort_card(uuid, text) to authenticated;
