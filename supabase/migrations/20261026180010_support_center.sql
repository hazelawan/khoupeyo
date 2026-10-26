-- Support Center: isolated from chat and order_issues.
-- App default first-response target is configurable by admins in this table; 24h is not a service guarantee.
create table if not exists public.support_center_config (
  singleton boolean primary key default true check (singleton),
  first_response_target_hours integer not null default 24 check (first_response_target_hours between 1 and 720),
  updated_at timestamptz not null default now()
);
insert into public.support_center_config (singleton) values (true) on conflict (singleton) do nothing;
alter table public.support_center_config enable row level security;
revoke all on public.support_center_config from anon, authenticated;
grant select on public.support_center_config to authenticated;
grant update (first_response_target_hours, updated_at) on public.support_center_config to authenticated;
create policy support_config_read_authenticated on public.support_center_config
  for select to authenticated using (true);
create policy support_config_admin_update on public.support_center_config
  for update to authenticated using (public.is_admin()) with check (public.is_admin());

create table if not exists public.support_tickets (
  id uuid primary key default gen_random_uuid(),
  requester_id uuid not null references auth.users(id) on delete cascade,
  requester_role text not null check (requester_role in ('customer','restaurant','rider','admin')),
  subject text not null check (char_length(btrim(subject)) between 1 and 180),
  category text not null default 'general' check (char_length(btrim(category)) between 1 and 60),
  order_id uuid references public.orders(id) on delete set null,
  status text not null default 'open' check (status in ('open','in_progress','waiting_on_requester','resolved','closed')),
  priority text not null default 'normal' check (priority in ('low','normal','high','urgent')),
  assigned_admin_id uuid references auth.users(id) on delete set null,
  first_response_at timestamptz,
  first_response_due_at timestamptz not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists support_tickets_requester_created_idx on public.support_tickets (requester_id, created_at desc, id);
create index if not exists support_tickets_admin_queue_idx on public.support_tickets (status, priority, created_at desc, id);
create index if not exists support_tickets_assignee_idx on public.support_tickets (assigned_admin_id, status, updated_at desc);
alter table public.support_tickets enable row level security;
revoke all on public.support_tickets from anon, authenticated;
grant select on public.support_tickets to authenticated;
grant update (assigned_admin_id, status, priority, first_response_at, updated_at) on public.support_tickets to authenticated;
create policy support_tickets_read_owner_admin on public.support_tickets
  for select to authenticated using (requester_id = auth.uid() or public.is_admin());
create policy support_tickets_admin_update on public.support_tickets
  for update to authenticated using (public.is_admin()) with check (public.is_admin());

create table if not exists public.support_ticket_messages (
  id uuid primary key default gen_random_uuid(),
  ticket_id uuid not null references public.support_tickets(id) on delete cascade,
  author_id uuid not null references auth.users(id) on delete cascade,
  author_role text not null check (author_role in ('customer','restaurant','rider','admin')),
  body text not null check (char_length(btrim(body)) between 1 and 10000),
  created_at timestamptz not null default now()
);
create index if not exists support_ticket_messages_ticket_created_idx on public.support_ticket_messages (ticket_id, created_at, id);
alter table public.support_ticket_messages enable row level security;
revoke all on public.support_ticket_messages from anon, authenticated;
grant select on public.support_ticket_messages to authenticated;
create policy support_messages_read_owner_admin on public.support_ticket_messages
  for select to authenticated using (
    public.is_admin() or exists (select 1 from public.support_tickets t where t.id = ticket_id and t.requester_id = auth.uid())
  );

create or replace function public.support_set_ticket_timestamps()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare v_hours integer;
begin
  if tg_op = 'INSERT' then
    select first_response_target_hours into v_hours from public.support_center_config where singleton = true;
    new.first_response_due_at := new.created_at + make_interval(hours => coalesce(v_hours, 24));
  end if;
  new.updated_at := now();
  return new;
end $$;
create or replace function public.support_message_first_response()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if public.is_admin() then
    update public.support_tickets set first_response_at = coalesce(first_response_at, new.created_at), updated_at = now()
      where id = new.ticket_id;
  end if;
  return new;
end $$;
create or replace function public.support_validate_order_owner(p_order uuid, p_user uuid, p_role text)
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select p_order is null or exists (
    select 1 from public.orders o where o.id = p_order and (
      (p_role = 'customer' and o.customer_id = p_user) or
      (p_role = 'restaurant' and public.owns_restaurant(o.restaurant_id)) or
      (p_role = 'rider' and o.rider_id = public.my_rider_id()) or
      (p_role = 'admin' and public.is_admin())
    )
  )
$$;
create or replace function public.support_create_ticket(p_subject text, p_category text default 'general', p_order_id uuid default null, p_message text default null)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare v_uid uuid := auth.uid(); v_role text; v_id uuid;
begin
  if v_uid is null then raise exception 'Authentication required'; end if;
  select role into v_role from public.profiles where id = v_uid;
  if v_role not in ('customer','restaurant','rider','admin') then raise exception 'Unsupported profile role'; end if;
  if p_subject is null or char_length(btrim(p_subject)) not between 1 and 180 then raise exception 'Subject must be 1-180 characters'; end if;
  if p_category is not null and char_length(btrim(p_category)) not between 1 and 60 then raise exception 'Invalid category'; end if;
  if p_message is not null and char_length(btrim(p_message)) not between 1 and 10000 then raise exception 'Message must be 1-10000 characters'; end if;
  if not public.support_validate_order_owner(p_order_id, v_uid, v_role) then raise exception 'Order is not associated with your account'; end if;
  insert into public.support_tickets (requester_id, requester_role, subject, category, order_id)
    values (v_uid, v_role, btrim(p_subject), coalesce(nullif(btrim(p_category),''),'general'), p_order_id) returning id into v_id;
  if p_message is not null then
    insert into public.support_ticket_messages (ticket_id, author_id, author_role, body)
      values (v_id, v_uid, v_role, btrim(p_message));
  end if;
  return v_id;
end $$;
create or replace function public.support_send_message(p_ticket_id uuid, p_body text)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare v_uid uuid := auth.uid(); v_role text; v_message_id uuid;
begin
  if v_uid is null then raise exception 'Authentication required'; end if;
  if p_body is null or char_length(btrim(p_body)) not between 1 and 10000 then raise exception 'Message must be 1-10000 characters'; end if;
  select role into v_role from public.profiles where id = v_uid;
  if v_role not in ('customer','restaurant','rider','admin') then raise exception 'Unsupported profile role'; end if;
  if not exists (select 1 from public.support_tickets t where t.id = p_ticket_id and (public.is_admin() or t.requester_id = v_uid)) then raise exception 'Ticket not found or access denied'; end if;
  insert into public.support_ticket_messages (ticket_id, author_id, author_role, body)
    values (p_ticket_id, v_uid, v_role, btrim(p_body)) returning id into v_message_id;
  return v_message_id;
end $$;
create or replace function public.support_reopen_ticket(p_ticket_id uuid)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
begin
  update public.support_tickets set status = 'open', updated_at = now()
    where id = p_ticket_id and requester_id = auth.uid() and status in ('resolved','closed');
  if not found then raise exception 'Ticket cannot be reopened or access denied'; end if;
end $$;
create or replace function public.support_escalate_ticket(p_ticket_id uuid)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
begin
  update public.support_tickets set priority = 'high', status = case when status in ('resolved','closed') then 'open' else status end, updated_at = now()
    where id = p_ticket_id and requester_id = auth.uid();
  if not found then raise exception 'Ticket not found or access denied'; end if;
end $$;

drop trigger if exists support_tickets_timestamps on public.support_tickets;
create trigger support_tickets_timestamps before insert or update on public.support_tickets for each row execute function public.support_set_ticket_timestamps();
drop trigger if exists support_messages_first_response on public.support_ticket_messages;
create trigger support_messages_first_response after insert on public.support_ticket_messages for each row execute function public.support_message_first_response();

revoke all on function public.support_validate_order_owner(uuid,uuid,text) from public, anon, authenticated;
revoke all on function public.support_create_ticket(text,text,uuid,text) from public, anon;
revoke all on function public.support_send_message(uuid,text) from public, anon;
revoke all on function public.support_reopen_ticket(uuid) from public, anon;
revoke all on function public.support_escalate_ticket(uuid) from public, anon;
grant execute on function public.support_create_ticket(text,text,uuid,text) to authenticated;
grant execute on function public.support_send_message(uuid,text) to authenticated;
grant execute on function public.support_reopen_ticket(uuid) to authenticated;
grant execute on function public.support_escalate_ticket(uuid) to authenticated;
