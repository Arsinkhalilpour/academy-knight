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
with check(sender_id=auth.uid()
 and exists(select 1 from public.ka_profiles p where p.id=auth.uid() and p.approved=true)
 and exists(select 1 from public.ka_profiles p where p.id=recipient_id and p.approved=true));

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

grant select,insert,update on public.ka_chat_profiles to authenticated;
grant select,insert on public.ka_chat_messages to authenticated;
grant select,insert,update on public.ka_chat_groups to authenticated;
grant select,insert,delete on public.ka_chat_group_members to authenticated;
grant select,insert on public.ka_chat_group_messages to authenticated;
