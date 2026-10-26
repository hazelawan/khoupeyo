-- Enforce the existing trip-end chat closure on the server. Direct customer/shop/rider
-- threads (including call signaling carried through the message RPC) close when the
-- order is delivered or cancelled. Separate support threads remain available.
create or replace function public.send_message(
  p_order_id uuid,
  p_thread text,
  p_body text,
  p_user_id uuid default null::uuid
)
returns uuid
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_role text;
  v_id uuid;
  v_user uuid := p_user_id;
  v_status text;
begin
  if p_order_id is null and p_thread = 'sup' and v_user is null then
    v_user := auth.uid();
  end if;
  if p_order_id is not null then
    v_user := null;
    if p_thread in ('cr', 'cs', 'rs') then
      -- Serialize message sends against the order-status RPC's FOR UPDATE lock.
      select o.status::text into v_status
      from public.orders o
      where o.id = p_order_id
      for share;
      if found and v_status in ('delivered', 'cancelled') then
        raise exception 'This chat is closed because the trip has ended';
      end if;
    end if;
  end if;
  v_role := public.chat_role(p_order_id, p_thread, v_user);
  if v_role is null then raise exception 'You cannot send messages in this chat'; end if;
  if p_body is null or length(trim(p_body)) = 0 then raise exception 'Write a message'; end if;
  insert into public.messages (order_id, thread, user_id, sender_id, sender_role, body)
  values (p_order_id, p_thread, v_user, auth.uid(), v_role, left(trim(p_body), 1000))
  returning id into v_id;
  return v_id;
end
$function$;

-- Supports the Shop app's descending created_at + id cursor for archived orders.
create index if not exists orders_restaurant_created_id_idx
  on public.orders (restaurant_id, created_at desc, id desc);
