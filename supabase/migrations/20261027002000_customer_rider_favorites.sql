-- Customer rider favorites are private informational records only.
-- No dispatch, assignment, ranking, location, or phone data is exposed here.
create table if not exists public.customer_rider_favorites (
  user_id uuid not null references auth.users(id) on delete cascade,
  rider_id uuid not null references public.riders(id) on delete cascade,
  source_order_id uuid not null references public.orders(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, rider_id)
);

alter table public.customer_rider_favorites enable row level security;
revoke all on table public.customer_rider_favorites from public, anon, authenticated;

-- Explicit owner-only policies remain in place even though direct table access is revoked.
drop policy if exists customer_rider_favorites_select_own on public.customer_rider_favorites;
create policy customer_rider_favorites_select_own on public.customer_rider_favorites
  for select to authenticated using ((select auth.uid()) = user_id);
drop policy if exists customer_rider_favorites_insert_own on public.customer_rider_favorites;
create policy customer_rider_favorites_insert_own on public.customer_rider_favorites
  for insert to authenticated with check ((select auth.uid()) = user_id);
drop policy if exists customer_rider_favorites_delete_own on public.customer_rider_favorites;
create policy customer_rider_favorites_delete_own on public.customer_rider_favorites
  for delete to authenticated using ((select auth.uid()) = user_id);

create or replace function public.customer_save_rider_favorite(p_order_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_rider_id uuid;
begin
  if v_uid is null then raise exception 'Authentication required'; end if;
  if not exists (select 1 from public.profiles p where p.id = v_uid and p.role = 'customer') then
    raise exception 'Customer account required';
  end if;

  select o.rider_id into v_rider_id
  from public.orders o
  where o.id = p_order_id
    and o.customer_id = v_uid
    and o.status::text in ('delivered', 'completed')
    and o.rider_id is not null;
  if not found then raise exception 'Completed order with an assigned rider required'; end if;

  insert into public.customer_rider_favorites(user_id, rider_id, source_order_id)
  values (v_uid, v_rider_id, p_order_id)
  on conflict (user_id, rider_id) do nothing;
  return true;
end;
$$;

create or replace function public.customer_list_rider_favorites()
returns table (rider_id uuid, rider_name text, saved_at timestamptz)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Authentication required'; end if;
  if not exists (select 1 from public.profiles p where p.id = v_uid and p.role = 'customer') then
    raise exception 'Customer account required';
  end if;
  return query
    select f.rider_id, coalesce(nullif(btrim(p.full_name), ''), 'Rider'), f.created_at
    from public.customer_rider_favorites f
    join public.riders r on r.id = f.rider_id
    join public.profiles p on p.id = r.profile_id
    where f.user_id = v_uid
    order by f.created_at desc
    limit 200;
end;
$$;

create or replace function public.customer_remove_rider_favorite(p_rider_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Authentication required'; end if;
  if not exists (select 1 from public.profiles p where p.id = v_uid and p.role = 'customer') then
    raise exception 'Customer account required';
  end if;
  delete from public.customer_rider_favorites
    where user_id = v_uid and rider_id = p_rider_id;
  return found;
end;
$$;

revoke all on function public.customer_save_rider_favorite(uuid) from public, anon;
revoke all on function public.customer_list_rider_favorites() from public, anon;
revoke all on function public.customer_remove_rider_favorite(uuid) from public, anon;
grant execute on function public.customer_save_rider_favorite(uuid) to authenticated;
grant execute on function public.customer_list_rider_favorites() to authenticated;
grant execute on function public.customer_remove_rider_favorite(uuid) to authenticated;
