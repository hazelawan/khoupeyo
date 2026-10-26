-- Shop operations: per-order handoff checklist for shop owners and active staff.
create table if not exists public.shop_order_handoffs (
  order_id uuid primary key references public.orders(id) on delete cascade,
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  checklist jsonb not null default '{"items_checked":false,"order_sealed":false,"customer_or_rider_confirmed":false}'::jsonb,
  note text,
  updated_at timestamptz not null default now(),
  constraint shop_order_handoffs_checklist_object check (jsonb_typeof(checklist) = 'object'),
  constraint shop_order_handoffs_note_length check (note is null or char_length(note) <= 500)
);

create index if not exists shop_order_handoffs_restaurant_updated_idx
  on public.shop_order_handoffs (restaurant_id, updated_at desc);

alter table public.shop_order_handoffs enable row level security;
revoke all on table public.shop_order_handoffs from anon;
grant select, insert, update on table public.shop_order_handoffs to authenticated;

drop policy if exists shop_order_handoffs_select on public.shop_order_handoffs;
create policy shop_order_handoffs_select on public.shop_order_handoffs
  for select to authenticated using (
    (
      exists (
        select 1 from public.restaurants r
        where r.id = shop_order_handoffs.restaurant_id and r.owner_id = auth.uid()
      ) or exists (
        select 1 from public.shop_staff s
        where s.restaurant_id = shop_order_handoffs.restaurant_id
          and s.user_id = auth.uid() and s.status = 'active'
      )
    ) and exists (
      select 1 from public.orders o
      where o.id = shop_order_handoffs.order_id and o.restaurant_id = shop_order_handoffs.restaurant_id
    )
  );

drop policy if exists shop_order_handoffs_insert on public.shop_order_handoffs;
create policy shop_order_handoffs_insert on public.shop_order_handoffs
  for insert to authenticated with check (
    (
      exists (
        select 1 from public.restaurants r
        where r.id = shop_order_handoffs.restaurant_id and r.owner_id = auth.uid()
      ) or exists (
        select 1 from public.shop_staff s
        where s.restaurant_id = shop_order_handoffs.restaurant_id
          and s.user_id = auth.uid() and s.status = 'active'
      )
    ) and exists (
      select 1 from public.orders o
      where o.id = shop_order_handoffs.order_id and o.restaurant_id = shop_order_handoffs.restaurant_id
    )
  );

drop policy if exists shop_order_handoffs_update on public.shop_order_handoffs;
create policy shop_order_handoffs_update on public.shop_order_handoffs
  for update to authenticated
  using (
    (
      exists (
        select 1 from public.restaurants r
        where r.id = shop_order_handoffs.restaurant_id and r.owner_id = auth.uid()
      ) or exists (
        select 1 from public.shop_staff s
        where s.restaurant_id = shop_order_handoffs.restaurant_id
          and s.user_id = auth.uid() and s.status = 'active'
      )
    ) and exists (
      select 1 from public.orders o
      where o.id = shop_order_handoffs.order_id and o.restaurant_id = shop_order_handoffs.restaurant_id
    )
  )
  with check (
    (
      exists (
        select 1 from public.restaurants r
        where r.id = shop_order_handoffs.restaurant_id and r.owner_id = auth.uid()
      ) or exists (
        select 1 from public.shop_staff s
        where s.restaurant_id = shop_order_handoffs.restaurant_id
          and s.user_id = auth.uid() and s.status = 'active'
      )
    ) and exists (
      select 1 from public.orders o
      where o.id = shop_order_handoffs.order_id and o.restaurant_id = shop_order_handoffs.restaurant_id
    )
  );
