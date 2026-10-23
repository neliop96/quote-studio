create table public.estimate_number_settings (
  id smallint primary key check (id = 1),
  prefix text not null check (prefix ~ '^[A-Z][A-Z0-9]{0,11}$'),
  serial_width integer not null check (serial_width between 1 and 8),
  next_serial bigint not null check (next_serial > 0)
);

alter table public.estimate_number_settings enable row level security;
revoke all on table public.estimate_number_settings from anon, authenticated;

insert into public.estimate_number_settings (id, prefix, serial_width, next_serial)
select
  1,
  'EST',
  3,
  greatest(
    1,
    coalesce(max(substring(quote_number from 8)::bigint), 0) + 1
  )
from public.quotes
where quote_number ~ '^EST[0-9]{4}[0-9]+$'
on conflict (id) do nothing;

create or replace function public.get_estimate_number_settings()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  settings jsonb;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  select jsonb_build_object(
    'prefix', prefix,
    'serial_width', serial_width,
    'next_serial', next_serial
  )
  into settings
  from public.estimate_number_settings
  where id = 1;

  return settings;
end;
$$;

create or replace function public.save_estimate_number_settings(
  p_prefix text,
  p_serial_width integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  settings jsonb;
begin
  if not exists (
    select 1
    from public.profiles
    where id = auth.uid()
      and role = 'admin'
  ) then
    raise exception 'Admin required to change estimate numbering';
  end if;

  p_prefix := upper(trim(p_prefix));
  if p_prefix !~ '^[A-Z][A-Z0-9]{0,11}$' then
    raise exception 'Prefix must start with a letter and contain only letters and numbers';
  end if;
  if p_serial_width is null or p_serial_width not between 1 and 8 then
    raise exception 'Serial number digits must be between 1 and 8';
  end if;

  update public.estimate_number_settings
  set prefix = p_prefix,
      serial_width = p_serial_width
  where id = 1
  returning jsonb_build_object(
    'prefix', prefix,
    'serial_width', serial_width,
    'next_serial', next_serial
  )
  into settings;

  return settings;
end;
$$;

create or replace function public.generate_estimate_number()
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_prefix text;
  current_width integer;
  serial bigint;
  estimate_number text;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  select prefix, serial_width, next_serial
  into current_prefix, current_width, serial
  from public.estimate_number_settings
  where id = 1
  for update;

  loop
    estimate_number :=
      current_prefix
      || to_char(current_date, 'YYMM')
      || lpad(serial::text, greatest(current_width, length(serial::text)), '0');

    if not exists (
      select 1
      from public.quotes
      where quote_number = estimate_number
    ) then
      update public.estimate_number_settings
      set next_serial = serial + 1
      where id = 1;
      return estimate_number;
    end if;

    serial := serial + 1;
  end loop;
end;
$$;

revoke all on function public.get_estimate_number_settings() from public;
revoke all on function public.save_estimate_number_settings(text, integer) from public;
revoke all on function public.generate_estimate_number() from public;

grant execute on function public.get_estimate_number_settings() to authenticated;
grant execute on function public.save_estimate_number_settings(text, integer) to authenticated;
grant execute on function public.generate_estimate_number() to authenticated;
