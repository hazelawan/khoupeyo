-- Customer saved-shop favorites. Rows are private to the authenticated owner.
create table if not exists public.customer_shop_favorites (
  user_id uuid not null references auth.users(id) on delete cascade,
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, restaurant_id)
);

alter table public.customer_shop_favorites enable row level security;
revoke all on table public.customer_shop_favorites from anon;
grant select, insert, delete on table public.customer_shop_favorites to authenticated;

drop policy if exists customer_shop_favorites_select_own on public.customer_shop_favorites;
create policy customer_shop_favorites_select_own on public.customer_shop_favorites
  for select to authenticated using (auth.uid() = user_id);
drop policy if exists customer_shop_favorites_insert_own on public.customer_shop_favorites;
create policy customer_shop_favorites_insert_own on public.customer_shop_favorites
  for insert to authenticated with check (auth.uid() = user_id);
drop policy if exists customer_shop_favorites_delete_own on public.customer_shop_favorites;
create policy customer_shop_favorites_delete_own on public.customer_shop_favorites
  for delete to authenticated using (auth.uid() = user_id);
