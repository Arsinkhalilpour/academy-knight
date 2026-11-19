-- Knight Academy: exam foundation (v1)
create table if not exists public.ka_exams (
  id uuid primary key default gen_random_uuid(),
  created_by uuid not null references auth.users(id) on delete cascade,
  title text not null check (char_length(title) between 2 and 180),
  subject text not null default '',
  description text not null default '',
  questions jsonb not null default '[]'::jsonb,
  status text not null default 'draft' check (status in ('draft','published','paused','closed')),
  grading_mode text not null default 'teacher' check (grading_mode in ('teacher','ai')),
  starts_at timestamptz,
  ends_at timestamptz,
  duration_minutes integer not null default 30 check (duration_minutes between 1 and 240),
  max_attempts integer not null default 1 check (max_attempts between 1 and 20),
  score_policy text not null default 'highest' check (score_policy in ('highest','latest','average')),
  assignment_user_ids uuid[] not null default '{}'::uuid[],
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists ka_exams_created_by_idx on public.ka_exams(created_by);
create index if not exists ka_exams_status_idx on public.ka_exams(status);

create table if not exists public.ka_exam_attempts (
  id uuid primary key default gen_random_uuid(),
  exam_id uuid not null references public.ka_exams(id) on delete cascade,
  student_id uuid not null references auth.users(id) on delete cascade,
  answers jsonb not null default '{}'::jsonb,
  score numeric(7,2),
  max_score numeric(7,2),
  feedback text not null default '',
  evaluation text check (evaluation in ('خیلی خوب','خوب','قابل قبول','نیاز به تلاش بیشتر')),
  status text not null default 'submitted' check (status in ('submitted','graded')),
  submitted_at timestamptz not null default now(),
  graded_at timestamptz,
  attempt_no integer not null default 1,
  unique(exam_id, student_id, attempt_no)
);
create index if not exists ka_exam_attempts_student_idx on public.ka_exam_attempts(student_id, exam_id);

alter table public.ka_exams enable row level security;
alter table public.ka_exam_attempts enable row level security;

drop policy if exists "approved teachers create exams" on public.ka_exams;
create policy "approved teachers create exams" on public.ka_exams
for insert to authenticated
with check (
  created_by = (select auth.uid())
  and exists (select 1 from public.ka_profiles p where p.id=(select auth.uid()) and p.approved is true and p.role::text in ('teacher','admin','creator'))
);

drop policy if exists "owners manage exams" on public.ka_exams;
create policy "owners manage exams" on public.ka_exams
for all to authenticated
using (
  created_by = (select auth.uid())
  and exists (select 1 from public.ka_profiles p where p.id=(select auth.uid()) and p.approved is true and p.role::text in ('teacher','admin','creator'))
)
with check (
  created_by = (select auth.uid())
  and exists (select 1 from public.ka_profiles p where p.id=(select auth.uid()) and p.approved is true and p.role::text in ('teacher','admin','creator'))
);

drop policy if exists "students read assigned published exams" on public.ka_exams;
create policy "students read assigned published exams" on public.ka_exams
for select to authenticated
using (
  status = 'published'
  and (starts_at is null or starts_at <= now())
  and (ends_at is null or ends_at >= now())
  and (cardinality(assignment_user_ids)=0 or (select auth.uid()) = any(assignment_user_ids))
  and exists (select 1 from public.ka_profiles p where p.id=(select auth.uid()) and p.approved is true and p.role::text='student')
);

drop policy if exists "students read own attempts" on public.ka_exam_attempts;
create policy "students read own attempts" on public.ka_exam_attempts
for select to authenticated
using (student_id=(select auth.uid()));

drop policy if exists "students submit attempts" on public.ka_exam_attempts;
create policy "students submit attempts" on public.ka_exam_attempts
for insert to authenticated
with check (
  student_id=(select auth.uid())
  and exists (
    select 1 from public.ka_profiles p
    where p.id=(select auth.uid()) and p.approved is true and p.role::text='student'
  )
  and exists (
    select 1 from public.ka_exams e
    where e.id=exam_id and e.status='published'
      and (e.starts_at is null or e.starts_at <= now())
      and (e.ends_at is null or e.ends_at >= now())
      and (cardinality(e.assignment_user_ids)=0 or (select auth.uid()) = any(e.assignment_user_ids))
  )
);

drop policy if exists "teachers read and grade own exam attempts" on public.ka_exam_attempts;
create policy "teachers read and grade own exam attempts" on public.ka_exam_attempts
for all to authenticated
using (
  exists (
    select 1 from public.ka_exams e
    join public.ka_profiles p on p.id=(select auth.uid())
    where e.id=exam_id and e.created_by=(select auth.uid())
      and p.approved is true and p.role::text in ('teacher','admin','creator')
  )
)
with check (
  exists (
    select 1 from public.ka_exams e
    join public.ka_profiles p on p.id=(select auth.uid())
    where e.id=exam_id and e.created_by=(select auth.uid())
      and p.approved is true and p.role::text in ('teacher','admin','creator')
  )
);

grant select, insert, update, delete on public.ka_exams to authenticated;
grant select, insert, update on public.ka_exam_attempts to authenticated;


-- Enforce attempt limits and exam window on the database, not only in the browser.
create or replace function public.ka_exam_validate_attempt_v1()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  exam_row public.ka_exams%rowtype;
  used_count integer;
begin
  select * into exam_row
  from public.ka_exams
  where id = new.exam_id
  for update;

  if not found or exam_row.status <> 'published' then
    raise exception 'این آزمون در دسترس نیست.';
  end if;
  if exam_row.starts_at is not null and exam_row.starts_at > now() then
    raise exception 'زمان شروع آزمون هنوز نرسیده است.';
  end if;
  if exam_row.ends_at is not null and exam_row.ends_at < now() then
    raise exception 'مهلت شرکت در آزمون پایان یافته است.';
  end if;
  if cardinality(exam_row.assignment_user_ids) > 0
     and not (new.student_id = any(exam_row.assignment_user_ids)) then
    raise exception 'این آزمون برای حساب شما اختصاص داده نشده است.';
  end if;

  select count(*) into used_count
  from public.ka_exam_attempts
  where exam_id = new.exam_id and student_id = new.student_id;

  if used_count >= exam_row.max_attempts then
    raise exception 'تعداد دفعات مجاز شرکت در این آزمون تمام شده است.';
  end if;
  new.attempt_no := used_count + 1;
  return new;
end;
$$;

drop trigger if exists ka_exam_validate_attempt_before_insert on public.ka_exam_attempts;
create trigger ka_exam_validate_attempt_before_insert
before insert on public.ka_exam_attempts
for each row execute function public.ka_exam_validate_attempt_v1();
