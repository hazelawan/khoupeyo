-- Date-specific shop-hour exceptions. Weekly restaurants.hours remains untouched.
create table if not exists public.restaurant_special_hours (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  exception_date date not null,
  is_closed boolean not null default false,
  open_time time without time zone,
  close_time time without time zone,
  note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint restaurant_special_hours_date_unique unique (restaurant_id, exception_date),
  constraint restaurant_special_hours_note_length check (note is null or length(note) <= 160),
  constraint restaurant_special_hours_times check (
    (is_closed and open_time is null and close_time is null)
    or (not is_closed and open_time is not null and close_time is not null and open_time < close_time)
  )
);

create index if not exists restaurant_special_hours_date_idx
  on public.restaurant_special_hours (restaurant_id, exception_date);

alter table public.restaurant_special_hours enable row level security;

grant select on public.restaurant_special_hours to anon, authenticated;
grant insert, update, delete on public.restaurant_special_hours to authenticated;

create policy restaurant_special_hours_public_read
  on public.restaurant_special_hours for select
  using (exists (
    select 1 from public.restaurants r
    where r.id = restaurant_special_hours.restaurant_id and r.is_active
  ));

create policy restaurant_special_hours_shop_write
  on public.restaurant_special_hours for all to authenticated
  using (
    exists (
      select 1 from public.restaurants r
      where r.id = restaurant_special_hours.restaurant_id
        and r.owner_id = auth.uid()
    )
    or exists (
      select 1 from public.shop_staff s
      where s.restaurant_id = restaurant_special_hours.restaurant_id
        and s.user_id = auth.uid() and s.status = 'active'
    )
  )
  with check (
    exists (
      select 1 from public.restaurants r
      where r.id = restaurant_special_hours.restaurant_id
        and r.owner_id = auth.uid()
    )
    or exists (
      select 1 from public.shop_staff s
      where s.restaurant_id = restaurant_special_hours.restaurant_id
        and s.user_id = auth.uid() and s.status = 'active'
    )
  );
