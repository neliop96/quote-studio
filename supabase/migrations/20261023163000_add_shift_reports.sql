create table if not exists public.shift_reports (
  id uuid primary key default gen_random_uuid(),
  report_date date not null,
  shift_name text not null check (length(trim(shift_name)) between 1 and 60),
  tasks jsonb not null check (
    case
      when jsonb_typeof(tasks) = 'array' then jsonb_array_length(tasks) > 0
      else false
    end
  ),
  status text not null default 'draft' check (status in ('draft', 'submitted')),
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  submitted_by uuid references public.profiles(id),
  submitted_at timestamptz
);

alter table public.shift_reports enable row level security;
grant select, insert, update on public.shift_reports to authenticated;

drop policy if exists "Authenticated users can view shift reports"
on public.shift_reports;
create policy "Authenticated users can view shift reports"
on public.shift_reports
for select
to authenticated
using (true);

drop policy if exists "Authenticated users can create shift report drafts"
on public.shift_reports;
create policy "Authenticated users can create shift report drafts"
on public.shift_reports
for insert
to authenticated
with check (
  created_by = auth.uid()
  and status = 'draft'
  and submitted_by is null
  and submitted_at is null
);

drop policy if exists "Creators can update their shift report drafts"
on public.shift_reports;
create policy "Creators can update their shift report drafts"
on public.shift_reports
for update
to authenticated
using (created_by = auth.uid() and status = 'draft')
with check (
  created_by = auth.uid()
  and status = 'draft'
  and submitted_by is null
  and submitted_at is null
);

create or replace function public.submit_shift_report(p_report uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_report public.shift_reports%rowtype;
  v_task jsonb;
  v_item jsonb;
  v_product_id uuid;
  v_quantity integer;
  v_notes text;
  v_movement_count integer := 0;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  select *
  into v_report
  from public.shift_reports
  where id = p_report
  for update;

  if not found then
    raise exception 'Shift report not found';
  end if;
  if v_report.status <> 'draft' then
    raise exception 'Only draft shift reports can be submitted';
  end if;
  if jsonb_typeof(v_report.tasks) is distinct from 'array'
     or jsonb_array_length(v_report.tasks) = 0 then
    raise exception 'Add at least one task before submitting';
  end if;

  for v_task in
    select task.value
    from jsonb_array_elements(v_report.tasks) as task(value)
  loop
    if coalesce(length(trim(v_task ->> 'title')), 0) = 0 then
      raise exception 'Each task must have a title';
    end if;
    if jsonb_typeof(v_task -> 'items') is distinct from 'array' then
      raise exception 'Each task must have a product list';
    end if;

    for v_item in
      select item.value
      from jsonb_array_elements(v_task -> 'items') as item(value)
    loop
      if coalesce(v_item ->> 'product_id', '') !~
         '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
         or coalesce(v_item ->> 'qty', '') !~ '^[1-9][0-9]*$' then
        raise exception 'Each product needs a valid ID and positive whole-number quantity';
      end if;

      v_product_id := (v_item ->> 'product_id')::uuid;
      v_quantity := (v_item ->> 'qty')::integer;

      if not exists (
        select 1
        from public.products
        where id = v_product_id
          and active = true
      ) then
        raise exception 'A report product is no longer active';
      end if;

      v_notes := left(
        'Shift: ' || v_report.shift_name || '; Task: ' || (v_task ->> 'title')
          || case
               when coalesce(v_task ->> 'notes', '') = '' then ''
               else '; ' || (v_task ->> 'notes')
             end,
        4000
      );

      perform public.record_stock_movement(
        v_product_id,
        'issue',
        v_quantity,
        null::numeric,
        left('Shift report ' || v_report.id::text, 120),
        v_notes
      );
      v_movement_count := v_movement_count + 1;
    end loop;
  end loop;

  update public.shift_reports
  set status = 'submitted',
      submitted_by = auth.uid(),
      submitted_at = now()
  where id = p_report;

  return jsonb_build_object(
    'report_id', p_report,
    'movement_count', v_movement_count,
    'submitted_at', now()
  );
end;
$$;

revoke all on function public.submit_shift_report(uuid) from public;
grant execute on function public.submit_shift_report(uuid) to authenticated;
