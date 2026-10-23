create table if not exists public.shift_alert_settings (
  id smallint primary key check (id = 1),
  recipient_roles text[] not null default array[]::text[],
  updated_by uuid references public.profiles(id),
  updated_at timestamptz not null default now()
);

alter table public.shift_alert_settings enable row level security;
revoke all on table public.shift_alert_settings from anon, authenticated;

insert into public.shift_alert_settings (id, recipient_roles)
values (1, array[]::text[])
on conflict (id) do nothing;

create table if not exists public.shift_alerts (
  id uuid primary key default gen_random_uuid(),
  report_id uuid not null references public.shift_reports(id),
  task_index integer not null check (task_index >= 0),
  recipient_role text not null,
  task_title text not null,
  handoff_note text not null check (length(trim(handoff_note)) > 0),
  created_at timestamptz not null default now(),
  unique (report_id, task_index, recipient_role)
);

alter table public.shift_alerts enable row level security;
grant select on public.shift_alerts to authenticated;

drop policy if exists "Employees can view handoff alerts for their role"
on public.shift_alerts;
create policy "Employees can view handoff alerts for their role"
on public.shift_alerts
for select
to authenticated
using (
  recipient_role = (
    select role::text
    from public.profiles
    where id = auth.uid()
  )
);

create table if not exists public.shift_alert_reads (
  alert_id uuid not null references public.shift_alerts(id),
  user_id uuid not null references public.profiles(id),
  read_at timestamptz not null default now(),
  primary key (alert_id, user_id)
);

alter table public.shift_alert_reads enable row level security;
revoke all on table public.shift_alert_reads from anon, authenticated;

create or replace function public.get_shift_alert_settings()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  result jsonb;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  select jsonb_build_object(
    'available_roles',
    coalesce(
      (
        select jsonb_agg(roles.role order by roles.role)
        from (
          select distinct profile.role::text as role
          from public.profiles as profile
          where profile.role is not null
            and profile.role::text <> 'admin'
        ) as roles
      ),
      '[]'::jsonb
    ),
    'recipient_roles',
    coalesce(to_jsonb(settings.recipient_roles), '[]'::jsonb)
  )
  into result
  from public.shift_alert_settings as settings
  where settings.id = 1;

  if result is null then
    raise exception 'Shift handoff alert settings are not initialized';
  end if;

  return result;
end;
$$;

create or replace function public.save_shift_alert_settings(p_roles text[])
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  normalized_roles text[];
begin
  if not exists (
    select 1
    from public.profiles
    where id = auth.uid()
      and role::text = 'admin'
  ) then
    raise exception 'Admin required to change handoff alert recipients';
  end if;

  if exists (
    select 1
    from unnest(coalesce(p_roles, array[]::text[])) as requested(role)
    where requested.role is null
      or length(trim(requested.role)) = 0
      or trim(requested.role) = 'admin'
  ) then
    raise exception 'Choose valid employee roles';
  end if;

  select coalesce(
    array_agg(distinct trim(requested.role) order by trim(requested.role)),
    array[]::text[]
  )
  into normalized_roles
  from unnest(coalesce(p_roles, array[]::text[])) as requested(role);

  if exists (
    select 1
    from unnest(normalized_roles) as requested(role)
    where not exists (
      select 1
      from public.profiles as profile
      where profile.role::text = requested.role
        and profile.role::text <> 'admin'
    )
  ) then
    raise exception 'Recipients must be roles currently assigned to employees';
  end if;

  update public.shift_alert_settings
  set recipient_roles = normalized_roles,
      updated_by = auth.uid(),
      updated_at = now()
  where id = 1;

  if not found then
    raise exception 'Shift handoff alert settings are not initialized';
  end if;

  return jsonb_build_object('recipient_roles', normalized_roles);
end;
$$;

create or replace function public.get_my_shift_alerts()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  current_role text;
  result jsonb;
begin
  select profile.role::text
  into current_role
  from public.profiles as profile
  where profile.id = auth.uid();

  if current_role is null then
    raise exception 'Employee profile required';
  end if;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', alert.id,
        'report_id', alert.report_id,
        'report_date', report.report_date,
        'shift_name', report.shift_name,
        'task_title', alert.task_title,
        'handoff_note', alert.handoff_note,
        'created_at', alert.created_at
      )
      order by alert.created_at desc
    ),
    '[]'::jsonb
  )
  into result
  from public.shift_alerts as alert
  join public.shift_reports as report
    on report.id = alert.report_id
  left join public.shift_alert_reads as receipt
    on receipt.alert_id = alert.id
   and receipt.user_id = auth.uid()
  where alert.recipient_role = current_role
    and receipt.alert_id is null;

  return result;
end;
$$;

create or replace function public.mark_shift_alert_read(p_alert uuid)
returns timestamptz
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_role text;
  read_time timestamptz;
begin
  select profile.role::text
  into current_role
  from public.profiles as profile
  where profile.id = auth.uid();

  if current_role is null then
    raise exception 'Employee profile required';
  end if;

  if not exists (
    select 1
    from public.shift_alerts as alert
    where alert.id = p_alert
      and alert.recipient_role = current_role
  ) then
    raise exception 'Handoff alert not found for your role';
  end if;

  insert into public.shift_alert_reads (alert_id, user_id)
  values (p_alert, auth.uid())
  on conflict (alert_id, user_id) do nothing;

  select receipt.read_at
  into read_time
  from public.shift_alert_reads as receipt
  where receipt.alert_id = p_alert
    and receipt.user_id = auth.uid();

  return read_time;
end;
$$;

create or replace function public.create_shift_alerts_for_submitted_report()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  recipient_roles text[];
  handoff_task record;
begin
  if new.status <> 'submitted' or old.status = 'submitted' then
    return new;
  end if;

  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  if new.created_by <> auth.uid()
     and not exists (
       select 1
       from public.profiles as profile
       where profile.id = auth.uid()
         and profile.role::text = 'admin'
     ) then
    raise exception 'Only the report creator or an administrator can submit this report';
  end if;

  select settings.recipient_roles
  into recipient_roles
  from public.shift_alert_settings as settings
  where settings.id = 1;

  if exists (
    select 1
    from jsonb_array_elements(new.tasks) as task(value)
    where length(trim(coalesce(task.value ->> 'notes', ''))) > 0
  ) and coalesce(cardinality(recipient_roles), 0) = 0 then
    raise exception 'An administrator must select handoff alert recipients before submitting reports with notes';
  end if;

  for handoff_task in
    select task.value, task.ordinality - 1 as task_index
    from jsonb_array_elements(new.tasks) with ordinality as task(value, ordinality)
    where length(trim(coalesce(task.value ->> 'notes', ''))) > 0
  loop
    insert into public.shift_alerts (
      report_id,
      task_index,
      recipient_role,
      task_title,
      handoff_note
    )
    select
      new.id,
      handoff_task.task_index::integer,
      recipient.role,
      handoff_task.value ->> 'title',
      trim(handoff_task.value ->> 'notes')
    from unnest(recipient_roles) as recipient(role);
  end loop;

  return new;
end;
$$;

drop trigger if exists create_shift_alerts_after_report_submission
on public.shift_reports;
create trigger create_shift_alerts_after_report_submission
after update of status on public.shift_reports
for each row
when (old.status = 'draft' and new.status = 'submitted')
execute function public.create_shift_alerts_for_submitted_report();

revoke all on function public.get_shift_alert_settings() from public;
revoke all on function public.save_shift_alert_settings(text[]) from public;
revoke all on function public.get_my_shift_alerts() from public;
revoke all on function public.mark_shift_alert_read(uuid) from public;
revoke all on function public.create_shift_alerts_for_submitted_report()
from public, anon, authenticated;

grant execute on function public.get_shift_alert_settings() to authenticated;
grant execute on function public.save_shift_alert_settings(text[]) to authenticated;
grant execute on function public.get_my_shift_alerts() to authenticated;
grant execute on function public.mark_shift_alert_read(uuid) to authenticated;
