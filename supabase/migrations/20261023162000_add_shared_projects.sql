create table public.projects (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) between 1 and 140),
  items jsonb not null check (
    case
      when jsonb_typeof(items) = 'array' then jsonb_array_length(items) > 0
      else false
    end
  ),
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now()
);

alter table public.projects enable row level security;
grant select, insert, delete on public.projects to authenticated;

create policy "Authenticated users can view shared projects"
on public.projects
for select
to authenticated
using (true);

create policy "Authenticated users can create projects"
on public.projects
for insert
to authenticated
with check (created_by = auth.uid());

create policy "Project creators and admins can delete projects"
on public.projects
for delete
to authenticated
using (
  created_by = auth.uid()
  or exists (
    select 1
    from public.profiles
    where id = auth.uid()
      and role = 'admin'
  )
);
