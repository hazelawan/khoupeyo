-- Private customer shopping lists and dated meal plans.
create table if not exists public.customer_shopping_list (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  item_name text not null check (char_length(btrim(item_name)) between 1 and 120),
  is_checked boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists customer_shopping_list_owner_created_idx
  on public.customer_shopping_list (user_id, created_at);
alter table public.customer_shopping_list enable row level security;
revoke all on table public.customer_shopping_list from anon;
grant select, insert, update, delete on public.customer_shopping_list to authenticated;
drop policy if exists customer_shopping_list_select_own on public.customer_shopping_list;
create policy customer_shopping_list_select_own on public.customer_shopping_list
  for select to authenticated using (auth.uid() = user_id);
drop policy if exists customer_shopping_list_insert_own on public.customer_shopping_list;
create policy customer_shopping_list_insert_own on public.customer_shopping_list
  for insert to authenticated with check (auth.uid() = user_id);
drop policy if exists customer_shopping_list_update_own on public.customer_shopping_list;
create policy customer_shopping_list_update_own on public.customer_shopping_list
  for update to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id);
drop policy if exists customer_shopping_list_delete_own on public.customer_shopping_list;
create policy customer_shopping_list_delete_own on public.customer_shopping_list
  for delete to authenticated using (auth.uid() = user_id);

create table if not exists public.customer_meal_plan (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  planned_date date not null,
  meal_name text not null check (char_length(btrim(meal_name)) between 1 and 160),
  created_at timestamptz not null default now()
);
create index if not exists customer_meal_plan_owner_date_idx
  on public.customer_meal_plan (user_id, planned_date, created_at);
alter table public.customer_meal_plan enable row level security;
revoke all on table public.customer_meal_plan from anon;
grant select, insert, delete on public.customer_meal_plan to authenticated;
drop policy if exists customer_meal_plan_select_own on public.customer_meal_plan;
create policy customer_meal_plan_select_own on public.customer_meal_plan
  for select to authenticated using (auth.uid() = user_id);
drop policy if exists customer_meal_plan_insert_own on public.customer_meal_plan;
create policy customer_meal_plan_insert_own on public.customer_meal_plan
  for insert to authenticated with check (auth.uid() = user_id);
drop policy if exists customer_meal_plan_delete_own on public.customer_meal_plan;
create policy customer_meal_plan_delete_own on public.customer_meal_plan
  for delete to authenticated using (auth.uid() = user_id);
