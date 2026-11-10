-- Academy Knight chat setup. Run the ENTIRE script in Supabase SQL Editor.
create table if not exists public.ka_chat_profiles (
 user_id uuid primary key references auth.users(id) on delete cascade,
 display_name text not null check (char_length(display_name) between 2 and 60),
 username text not null unique check (username ~ '^[a-z0-9_]{3,24}$'),
 bio text not null default '' check (char_length(bio)<=160),
 avatar_url text,
 updated_at timestamptz not null default now()
);
create table if not exists public.ka_chat_messages (
 id uuid primary key default gen_random_uuid(),
 sender_id uuid not null references auth.users(id) on delete cascade,
 recipient_id uuid not null references auth.users(id) on delete cascade,
 body text not null check (char_length(body) between 1 and 2000),
 created_at timestamptz not null default now(),
 check(sender_id<>recipient_id)
);
create table if not exists public.ka_chat_groups (
 id uuid primary key default gen_random_uuid(),
 name text not null check(char_length(name) between 2 and 70),
 created_by uuid not null references auth.users(id) on delete cascade,
 created_at timestamptz not null default now()
);
create table if not exists public.ka_chat_group_members (
 group_id uuid not null references public.ka_chat_groups(id) on delete cascade,
 user_id uuid not null references auth.users(id) on delete cascade,
 member_role text not null default 'member' check(member_role in ('owner','member')),
 joined_at timestamptz not null default now(),
 primary key(group_id,user_id)
);
create table if not exists public.ka_chat_group_messages (
 id uuid primary key default gen_random_uuid(),
 group_id uuid not null references public.ka_chat_groups(id) on delete cascade,
 sender_id uuid not null references auth.users(id) on delete cascade,
 body text not null check(char_length(body) between 1 and 2000),
 created_at timestamptz not null default now()
);

-- Private student-to-teacher inbox and replies.
create table if not exists public.ka_teacher_messages (
 id uuid primary key default gen_random_uuid(),
 student_id uuid not null references auth.users(id) on delete cascade,
 sender_id uuid not null references auth.users(id) on delete cascade,
 sender_role text not null check(sender_role in ('student','teacher')),
 message text not null check(char_length(message) between 1 and 2000),
 created_at timestamptz not null default now()
);
create index if not exists ka_teacher_messages_student_created_idx
 on public.ka_teacher_messages(student_id, created_at);

-- Use a SECURITY DEFINER helper so message INSERT checks are not blocked by RLS on ka_profiles.
create or replace function public.ka_chat_is_approved_user(uid uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
 select exists (
   select 1 from public.ka_profiles p
   where p.id = uid and p.approved = true
 );
$$;
revoke all on function public.ka_chat_is_approved_user(uuid) from public;
grant execute on function public.ka_chat_is_approved_user(uuid) to authenticated;

-- Role-aware security helper for policies that need to verify another account.
create or replace function public.ka_chat_user_has_role(uid uuid, expected_role text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
 select exists (
   select 1 from public.ka_profiles p
   where p.id = uid
     and p.approved = true
     and p.role::text = expected_role
 );
$$;
revoke all on function public.ka_chat_user_has_role(uuid, text) from public;
grant execute on function public.ka_chat_user_has_role(uuid, text) to authenticated;

-- Return roles only for approved chat users, without exposing the full academy profile table.
create or replace function public.ka_chat_get_roles(user_ids uuid[])
returns table(user_id uuid, role text)
language sql
stable
security definer
set search_path = ''
as $$
 select p.id, p.role::text
 from public.ka_profiles p
 where p.id = any(user_ids)
   and p.approved = true
   and public.ka_chat_is_approved_user((select auth.uid()));
$$;
revoke all on function public.ka_chat_get_roles(uuid[]) from public;
grant execute on function public.ka_chat_get_roles(uuid[]) to authenticated;


-- Remove chat data even if an account is removed from the academy profile table.
create or replace function public.ka_chat_cleanup_deleted_academy_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
 delete from public.ka_chat_messages
 where sender_id = old.id or recipient_id = old.id;

 delete from public.ka_chat_group_messages
 where sender_id = old.id;

 delete from public.ka_chat_group_members
 where user_id = old.id;

 delete from public.ka_chat_groups
 where created_by = old.id;

 delete from public.ka_chat_profiles
 where user_id = old.id;

 return old;
end;
$$;

drop trigger if exists ka_chat_cleanup_deleted_academy_user on public.ka_profiles;
create trigger ka_chat_cleanup_deleted_academy_user
after delete on public.ka_profiles
for each row execute function public.ka_chat_cleanup_deleted_academy_user();

create or replace function public.ka_chat_is_member(gid uuid)
returns boolean language sql stable security definer set search_path=public
as $$ select exists(select 1 from public.ka_chat_group_members m where m.group_id=gid and m.user_id=auth.uid()) $$;
create or replace function public.ka_chat_is_owner(gid uuid)
returns boolean language sql stable security definer set search_path=public
as $$ select exists(select 1 from public.ka_chat_groups g where g.id=gid and g.created_by=auth.uid()) $$;
revoke all on function public.ka_chat_is_member(uuid) from public;
revoke all on function public.ka_chat_is_owner(uuid) from public;
grant execute on function public.ka_chat_is_member(uuid) to authenticated;
grant execute on function public.ka_chat_is_owner(uuid) to authenticated;

alter table public.ka_chat_profiles enable row level security;
alter table public.ka_chat_messages enable row level security;
alter table public.ka_chat_groups enable row level security;
alter table public.ka_chat_group_members enable row level security;
alter table public.ka_chat_group_messages enable row level security;
alter table public.ka_teacher_messages enable row level security;

drop policy if exists "chat profiles visible to signed users" on public.ka_chat_profiles;
create policy "chat profiles visible to signed users" on public.ka_chat_profiles for select to authenticated
using(exists(select 1 from public.ka_profiles p where p.id=auth.uid() and p.approved=true));
drop policy if exists "users manage own chat profile" on public.ka_chat_profiles;
create policy "users manage own chat profile" on public.ka_chat_profiles for all to authenticated
using(user_id=auth.uid() and exists(select 1 from public.ka_profiles p where p.id=auth.uid() and p.approved=true))
with check(user_id=auth.uid() and exists(select 1 from public.ka_profiles p where p.id=auth.uid() and p.approved=true));

drop policy if exists "participants read direct messages" on public.ka_chat_messages;
create policy "participants read direct messages" on public.ka_chat_messages for select to authenticated
using(sender_id=auth.uid() or recipient_id=auth.uid());
drop policy if exists "send direct messages as self" on public.ka_chat_messages;
create policy "send direct messages as self" on public.ka_chat_messages for insert to authenticated
with check(sender_id=(select auth.uid())
 and public.ka_chat_is_approved_user((select auth.uid()))
 and public.ka_chat_is_approved_user(recipient_id));

drop policy if exists "members view groups" on public.ka_chat_groups;
create policy "members view groups" on public.ka_chat_groups for select to authenticated
using(public.ka_chat_is_member(id));
drop policy if exists "approved users create groups" on public.ka_chat_groups;
create policy "approved users create groups" on public.ka_chat_groups for insert to authenticated
with check(created_by=auth.uid() and exists(select 1 from public.ka_profiles p where p.id=auth.uid() and p.approved=true));
drop policy if exists "owner updates group" on public.ka_chat_groups;
create policy "owner updates group" on public.ka_chat_groups for update to authenticated
using(created_by=auth.uid()) with check(created_by=auth.uid());

drop policy if exists "members see group membership" on public.ka_chat_group_members;
create policy "members see group membership" on public.ka_chat_group_members for select to authenticated
using(public.ka_chat_is_member(group_id));
drop policy if exists "group owner adds members" on public.ka_chat_group_members;
create policy "group owner adds members" on public.ka_chat_group_members for insert to authenticated
with check(public.ka_chat_is_owner(group_id)
 and exists(select 1 from public.ka_profiles p where p.id=user_id and p.approved=true));
drop policy if exists "group owner removes members" on public.ka_chat_group_members;
create policy "group owner removes members" on public.ka_chat_group_members for delete to authenticated
using(public.ka_chat_is_owner(group_id) or user_id=auth.uid());

drop policy if exists "members read group messages" on public.ka_chat_group_messages;
create policy "members read group messages" on public.ka_chat_group_messages for select to authenticated
using(public.ka_chat_is_member(group_id));
drop policy if exists "members send group messages" on public.ka_chat_group_messages;
create policy "members send group messages" on public.ka_chat_group_messages for insert to authenticated
with check(sender_id=auth.uid() and public.ka_chat_is_member(group_id));

-- Senders can delete only their own direct and group messages.
drop policy if exists "senders delete own direct messages" on public.ka_chat_messages;
create policy "senders delete own direct messages" on public.ka_chat_messages
for delete to authenticated
using(sender_id = (select auth.uid()) and public.ka_chat_is_approved_user((select auth.uid())));

drop policy if exists "owners delete own groups" on public.ka_chat_groups;
create policy "owners delete own groups" on public.ka_chat_groups
for delete to authenticated
using(created_by = (select auth.uid()) and public.ka_chat_is_approved_user((select auth.uid())));

drop policy if exists "senders delete own group messages" on public.ka_chat_group_messages;
create policy "senders delete own group messages" on public.ka_chat_group_messages
for delete to authenticated
using(sender_id = (select auth.uid()) and public.ka_chat_is_member(group_id));

-- Students can read and send only their own teacher thread; approved teachers can read
-- student threads and reply as themselves.
drop policy if exists "students and teachers read teacher messages" on public.ka_teacher_messages;
create policy "students and teachers read teacher messages" on public.ka_teacher_messages
for select to authenticated
using(
 (student_id = (select auth.uid()) and public.ka_chat_user_has_role((select auth.uid()), 'student'))
 or public.ka_chat_user_has_role((select auth.uid()), 'teacher')
);

drop policy if exists "students and teachers send teacher messages" on public.ka_teacher_messages;
create policy "students and teachers send teacher messages" on public.ka_teacher_messages
for insert to authenticated
with check(
 sender_id = (select auth.uid())
 and (
  (sender_role = 'student' and student_id = (select auth.uid())
   and public.ka_chat_user_has_role((select auth.uid()), 'student'))
  or
  (sender_role = 'teacher'
   and public.ka_chat_user_has_role((select auth.uid()), 'teacher')
   and public.ka_chat_user_has_role(student_id, 'student'))
 )
);

grant select,insert,update on public.ka_chat_profiles to authenticated;
grant select,insert,delete on public.ka_chat_messages to authenticated;
grant select,insert,update,delete on public.ka_chat_groups to authenticated;
grant select,insert,delete on public.ka_chat_group_members to authenticated;
grant select,insert,delete on public.ka_chat_group_messages to authenticated;
grant select,insert on public.ka_teacher_messages to authenticated;


-- Storage for uploaded profile pictures (safe to rerun)
insert into storage.buckets (id,name,public,file_size_limit,allowed_mime_types)
values ('ka-avatars','ka-avatars',true,3145728,array['image/jpeg','image/png','image/webp','image/gif'])
on conflict (id) do update set public=true,file_size_limit=3145728,allowed_mime_types=array['image/jpeg','image/png','image/webp','image/gif'];

drop policy if exists "chat avatars are publicly readable" on storage.objects;
create policy "chat avatars are publicly readable" on storage.objects for select using (bucket_id='ka-avatars');

drop policy if exists "users upload own chat avatar" on storage.objects;
create policy "users upload own chat avatar" on storage.objects for insert to authenticated
with check (bucket_id='ka-avatars' and (storage.foldername(name))[1]=auth.uid()::text);

drop policy if exists "users update own chat avatar" on storage.objects;
create policy "users update own chat avatar" on storage.objects for update to authenticated
using (bucket_id='ka-avatars' and (storage.foldername(name))[1]=auth.uid()::text)
with check (bucket_id='ka-avatars' and (storage.foldername(name))[1]=auth.uid()::text);


-- Saved AI tutor conversation history (one row per question and answer).
create table if not exists public.ka_tutor_history (
 id uuid primary key default gen_random_uuid(),
 user_id uuid not null references auth.users(id) on delete cascade,
 question text not null check(char_length(question) between 1 and 1500),
 answer text not null check(char_length(answer) between 1 and 12000),
 created_at timestamptz not null default now()
);
create index if not exists ka_tutor_history_user_created_idx
 on public.ka_tutor_history(user_id, created_at desc);
alter table public.ka_tutor_history enable row level security;
drop policy if exists "students read own tutor history" on public.ka_tutor_history;
create policy "students read own tutor history" on public.ka_tutor_history
 for select to authenticated using(user_id=(select auth.uid()));
drop policy if exists "students save own tutor history" on public.ka_tutor_history;
create policy "students save own tutor history" on public.ka_tutor_history
 for insert to authenticated with check(user_id=(select auth.uid()));
grant select,insert on public.ka_tutor_history to authenticated;
