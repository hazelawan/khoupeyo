-- Active Shop subaccounts may open a support ticket linked to an order in their shop.
create or replace function public.support_validate_order_owner(p_order uuid, p_user uuid, p_role text)
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select p_order is null or exists (
    select 1 from public.orders o where o.id = p_order and (
      (p_role = 'customer' and o.customer_id = p_user) or
      (p_role = 'restaurant' and (
        public.owns_restaurant(o.restaurant_id) or exists (
          select 1 from public.shop_staff s
          where s.restaurant_id = o.restaurant_id and s.user_id = p_user and s.status = 'active'
        )
      )) or
      (p_role = 'rider' and o.rider_id = public.my_rider_id()) or
      (p_role = 'admin' and public.is_admin())
    )
  )
$$;
