-- Durable approval workflows for customer refunds, rider shift requests, and shop promotion requests.
-- No payment is initiated or marked refunded by this migration. Admin must process any
-- external refund separately and record a reference before confirming completion.

-- Customer refund requests ----------------------------------------------------
create table if not exists public.customer_refund_requests (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  customer_id uuid not null references auth.users(id) on delete cascade,
  reason text not null check (char_length(btrim(reason)) between 8 and 2000),
  status text not null default 'requested'
    check (status in ('requested','reviewing','approved','rejected','escalated','refunded')),
  admin_note text,
  external_reference text,
  requested_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  decided_at timestamptz,
  decided_by uuid references auth.users(id) on delete set null,
  constraint customer_refund_admin_note_length check (admin_note is null or char_length(admin_note) <= 2000),
  constraint customer_refund_external_ref_length check (external_reference is null or char_length(external_reference) <= 200)
);
create index if not exists customer_refund_requests_order_idx on public.customer_refund_requests(order_id);
create index if not exists customer_refund_requests_owner_idx on public.customer_refund_requests(customer_id, requested_at desc);
create index if not exists customer_refund_requests_queue_idx on public.customer_refund_requests(status, requested_at desc);
create unique index if not exists customer_refund_requests_one_active_per_order
  on public.customer_refund_requests(order_id)
  where status in ('requested','reviewing','approved','escalated');
alter table public.customer_refund_requests enable row level security;
revoke all on public.customer_refund_requests from anon, authenticated;
grant select on public.customer_refund_requests to authenticated;
drop policy if exists customer_refund_requests_select_owner_admin on public.customer_refund_requests;
create policy customer_refund_requests_select_owner_admin on public.customer_refund_requests
  for select to authenticated using (customer_id = (select auth.uid()) or public.is_admin());

create or replace function public.customer_create_refund_request(p_order_id uuid, p_reason text)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_uid uuid := auth.uid();
  v_role text;
  v_status text;
  v_payment_status text;
  v_id uuid;
begin
  if v_uid is null then raise exception 'Authentication required'; end if;
  select role into v_role from public.profiles where id = v_uid;
  if v_role is distinct from 'customer' then raise exception 'Only customers can request a refund'; end if;
  if p_reason is null or char_length(btrim(p_reason)) not between 8 and 2000 then
    raise exception 'Please explain the issue in 8 to 2000 characters';
  end if;
  select o.status::text, o.payment_status into v_status, v_payment_status
    from public.orders o where o.id = p_order_id and o.customer_id = v_uid;
  if not found then raise exception 'Order not found'; end if;
  if v_status not in ('delivered','cancelled') then
    raise exception 'Refund requests are available after an order is delivered or cancelled';
  end if;
  if lower(coalesce(v_payment_status,'')) = 'refunded' then
    raise exception 'This order is already marked as refunded';
  end if;
  insert into public.customer_refund_requests(order_id, customer_id, reason)
    values (p_order_id, v_uid, btrim(p_reason)) returning id into v_id;
  return v_id;
exception when unique_violation then
  raise exception 'There is already an active refund request for this order';
end $$;

create or replace function public.admin_refund_queue()
returns table (
  id uuid, order_id uuid, customer_id uuid, customer_name text, customer_phone text,
  order_total numeric, order_status text, payment_method text, payment_status text,
  reason text, status text, admin_note text, external_reference text,
  requested_at timestamptz, updated_at timestamptz
)
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if not public.is_admin() then raise exception 'Administrator access required'; end if;
  return query
    select rr.id, rr.order_id, rr.customer_id, p.full_name, p.phone,
      o.total, o.status::text, o.payment_method, o.payment_status,
      rr.reason, rr.status, rr.admin_note, rr.external_reference, rr.requested_at, rr.updated_at
    from public.customer_refund_requests rr
    join public.orders o on o.id = rr.order_id
    left join public.profiles p on p.id = rr.customer_id
    order by case rr.status when 'requested' then 0 when 'escalated' then 1 when 'reviewing' then 2 when 'approved' then 3 else 4 end,
      rr.requested_at desc limit 250;
end $$;

create or replace function public.admin_refund_request_action(
  p_request_id uuid, p_action text, p_note text default null, p_external_reference text default null
)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_status text;
  v_note text := nullif(btrim(coalesce(p_note,'')), '');
  v_ref text := nullif(btrim(coalesce(p_external_reference,'')), '');
begin
  if not public.is_admin() then raise exception 'Administrator access required'; end if;
  if p_action not in ('review','approve','reject','escalate','refunded') then raise exception 'Invalid refund action'; end if;
  if v_note is not null and char_length(v_note) > 2000 then raise exception 'Admin note is too long'; end if;
  if v_ref is not null and char_length(v_ref) > 200 then raise exception 'External reference is too long'; end if;
  select status into v_status from public.customer_refund_requests where id = p_request_id for update;
  if not found then raise exception 'Refund request not found'; end if;
  if p_action = 'review' and v_status not in ('requested','escalated') then raise exception 'Only new or escalated requests can be moved to review'; end if;
  if p_action = 'approve' and v_status not in ('requested','reviewing','escalated') then raise exception 'This request cannot be approved from its current status'; end if;
  if p_action = 'reject' and v_status not in ('requested','reviewing','escalated') then raise exception 'This request cannot be rejected from its current status'; end if;
  if p_action = 'reject' and v_note is null then raise exception 'Add a reason before rejecting a request'; end if;
  if p_action = 'escalate' and v_status in ('refunded','rejected') then raise exception 'This request is already closed'; end if;
  if p_action = 'refunded' and v_status <> 'approved' then raise exception 'Approve the request before confirming an external refund'; end if;
  if p_action = 'refunded' and v_ref is null then raise exception 'Enter the external payment/refund reference after the refund is processed'; end if;
  update public.customer_refund_requests set
    status = case p_action when 'review' then 'reviewing' when 'approve' then 'approved' when 'reject' then 'rejected' when 'escalate' then 'escalated' else 'refunded' end,
    admin_note = coalesce(v_note, admin_note),
    external_reference = case when p_action = 'refunded' then v_ref else external_reference end,
    decided_by = case when p_action in ('approve','reject','refunded') then auth.uid() else decided_by end,
    decided_at = case when p_action in ('approve','reject','refunded') then now() else decided_at end,
    updated_at = now()
  where id = p_request_id;
end $$;

-- Rider shift request/approval workflow --------------------------------------
create table if not exists public.rider_shift_requests (
  id uuid primary key default gen_random_uuid(),
  rider_id uuid not null references public.riders(id) on delete cascade,
  shift_id uuid not null references public.duty_shifts(id) on delete restrict,
  requested_date date not null,
  status text not null default 'pending' check (status in ('pending','approved','rejected','cancelled')),
  admin_note text,
  created_at timestamptz not null default now(),
  decided_at timestamptz,
  decided_by uuid references auth.users(id) on delete set null,
  constraint rider_shift_request_note_length check (admin_note is null or char_length(admin_note) <= 1000)
);
create index if not exists rider_shift_requests_shift_idx on public.rider_shift_requests(shift_id);
create index if not exists rider_shift_requests_queue_idx on public.rider_shift_requests(status, requested_date, created_at desc);
create index if not exists rider_shift_requests_rider_idx on public.rider_shift_requests(rider_id, requested_date desc);
create unique index if not exists rider_shift_requests_one_active_per_rider_date
  on public.rider_shift_requests(rider_id, requested_date) where status in ('pending','approved');
alter table public.rider_shift_requests enable row level security;
revoke all on public.rider_shift_requests from anon, authenticated;
grant select on public.rider_shift_requests to authenticated;
drop policy if exists rider_shift_requests_select_owner_admin on public.rider_shift_requests;
create policy rider_shift_requests_select_owner_admin on public.rider_shift_requests
  for select to authenticated using (
    public.is_admin() or exists (
      select 1 from public.riders r where r.id = rider_shift_requests.rider_id and r.profile_id = (select auth.uid())
    )
  );

create or replace function public.rider_list_available_shifts()
returns table (id uuid, name text, start_time time, end_time time, break_start time, break_minutes integer)
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_rider public.riders%rowtype;
begin
  select r.* into v_rider from public.riders r
    join public.profiles p on p.id = r.profile_id
    where r.profile_id = auth.uid() and p.role = 'rider' and r.is_approved and not r.blocked;
  if not found then raise exception 'Approved rider account required'; end if;
  return query select d.id, d.name, d.start_time, d.end_time, d.break_start, d.break_minutes
    from public.duty_shifts d where d.region_id = v_rider.region_id and d.is_active order by d.sort, d.start_time;
end $$;

create or replace function public.rider_my_shift_requests()
returns table (id uuid, shift_id uuid, shift_name text, start_time time, end_time time,
  requested_date date, status text, admin_note text, created_at timestamptz, decided_at timestamptz)
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_rider_id uuid := public.my_rider_id();
begin
  if v_rider_id is null then raise exception 'Rider account required'; end if;
  return query select q.id, q.shift_id, d.name, d.start_time, d.end_time, q.requested_date,
    q.status, q.admin_note, q.created_at, q.decided_at
    from public.rider_shift_requests q join public.duty_shifts d on d.id=q.shift_id
    where q.rider_id=v_rider_id order by q.requested_date desc, q.created_at desc limit 100;
end $$;

create or replace function public.rider_request_shift(p_shift_id uuid, p_date date)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_uid uuid := auth.uid();
  v_rider_id uuid;
  v_region_id uuid;
  v_today date := (now() at time zone 'Asia/Karachi')::date;
  v_id uuid;
begin
  if v_uid is null then raise exception 'Authentication required'; end if;
  select r.id, r.region_id into v_rider_id, v_region_id from public.riders r
    join public.profiles p on p.id=r.profile_id
    where r.profile_id=v_uid and p.role='rider' and r.is_approved and not r.blocked
      and (r.suspended_until is null or r.suspended_until <= now());
  if not found then raise exception 'Approved, active rider account required'; end if;
  if p_date is null or p_date < v_today or p_date > v_today + 30 then raise exception 'Choose a date within the next 30 days'; end if;
  if not exists (select 1 from public.duty_shifts d where d.id=p_shift_id and d.region_id=v_region_id and d.is_active) then
    raise exception 'That shift is not available in your region';
  end if;
  if exists (select 1 from public.rider_shift_plan p where p.rider_id=v_rider_id and p.date_from<=p_date and (p.date_to is null or p.date_to>=p_date)) then
    raise exception 'You already have a planned shift on that date';
  end if;
  insert into public.rider_shift_requests(rider_id,shift_id,requested_date)
    values(v_rider_id,p_shift_id,p_date) returning id into v_id;
  return v_id;
exception when unique_violation then
  raise exception 'You already have an active shift request for that date';
end $$;

create or replace function public.rider_cancel_shift_request(p_request_id uuid)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare v_rider_id uuid := public.my_rider_id();
begin
  if v_rider_id is null then raise exception 'Rider account required'; end if;
  update public.rider_shift_requests set status='cancelled'
    where id=p_request_id and rider_id=v_rider_id and status='pending';
  if not found then raise exception 'Only your pending request can be cancelled'; end if;
end $$;

create or replace function public.admin_shift_request_queue()
returns table (id uuid, rider_id uuid, rider_name text, rider_code text, shift_id uuid,
  shift_name text, start_time time, end_time time, requested_date date, status text,
  admin_note text, created_at timestamptz)
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if not public.is_admin() then raise exception 'Administrator access required'; end if;
  return query select q.id,q.rider_id,p.full_name,r.rider_code,q.shift_id,d.name,d.start_time,d.end_time,
    q.requested_date,q.status,q.admin_note,q.created_at
    from public.rider_shift_requests q join public.riders r on r.id=q.rider_id
    join public.profiles p on p.id=r.profile_id join public.duty_shifts d on d.id=q.shift_id
    order by case q.status when 'pending' then 0 else 1 end, q.requested_date, q.created_at desc limit 250;
end $$;

create or replace function public.admin_shift_request_action(p_request_id uuid,p_action text,p_note text default null)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_req public.rider_shift_requests%rowtype;
  v_today date := (now() at time zone 'Asia/Karachi')::date;
  v_note text := nullif(btrim(coalesce(p_note,'')), '');
begin
  if not public.is_admin() then raise exception 'Administrator access required'; end if;
  if p_action not in ('approve','reject') then raise exception 'Invalid shift request action'; end if;
  if v_note is not null and char_length(v_note)>1000 then raise exception 'Admin note is too long'; end if;
  select * into v_req from public.rider_shift_requests where id=p_request_id for update;
  if not found or v_req.status<>'pending' then raise exception 'Pending shift request not found'; end if;
  if p_action='approve' then
    if v_req.requested_date<v_today then raise exception 'Past shift requests cannot be approved'; end if;
    if exists (select 1 from public.rider_shift_plan p where p.rider_id=v_req.rider_id and p.date_from<=v_req.requested_date and (p.date_to is null or p.date_to>=v_req.requested_date)) then
      raise exception 'This rider already has a planned shift on that date';
    end if;
    if not exists (select 1 from public.duty_shifts d join public.riders r on r.region_id=d.region_id
      where d.id=v_req.shift_id and d.is_active and r.id=v_req.rider_id and r.is_approved and not r.blocked) then
      raise exception 'The shift or rider is no longer eligible';
    end if;
    insert into public.rider_shift_plan(rider_id,shift_id,date_from,date_to,note,created_by)
      values(v_req.rider_id,v_req.shift_id,v_req.requested_date,v_req.requested_date,
        'Approved rider request' || case when v_note is null then '' else ': '||v_note end,auth.uid());
  elsif p_action='reject' and v_note is null then
    raise exception 'Add a short reason before rejecting a request';
  end if;
  update public.rider_shift_requests set status=case p_action when 'approve' then 'approved' else 'rejected' end,
    admin_note=coalesce(v_note,admin_note),decided_by=auth.uid(),decided_at=now()
    where id=p_request_id;
end $$;

-- Shop promotion request -> admin approval -> customer-facing banner ----------
create table if not exists public.shop_promo_requests (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  requested_by uuid not null references auth.users(id) on delete cascade,
  region_id uuid not null references public.regions(id) on delete restrict,
  title text not null check (char_length(btrim(title)) between 3 and 80),
  subtitle text,
  image_url text,
  starts_at timestamptz,
  ends_at timestamptz,
  status text not null default 'requested' check (status in ('requested','approved','rejected','withdrawn')),
  admin_note text,
  banner_id uuid references public.banners(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  decided_at timestamptz,
  decided_by uuid references auth.users(id) on delete set null,
  constraint shop_promo_subtitle_length check (subtitle is null or char_length(subtitle)<=180),
  constraint shop_promo_admin_note_length check (admin_note is null or char_length(admin_note)<=1000),
  constraint shop_promo_dates_check check (starts_at is null or ends_at is null or ends_at>starts_at)
);
create index if not exists shop_promo_requests_queue_idx on public.shop_promo_requests(status,created_at desc);
create index if not exists shop_promo_requests_shop_idx on public.shop_promo_requests(restaurant_id,created_at desc);
alter table public.shop_promo_requests enable row level security;
revoke all on public.shop_promo_requests from anon, authenticated;
grant select on public.shop_promo_requests to authenticated;
drop policy if exists shop_promo_requests_select_owner_admin on public.shop_promo_requests;
create policy shop_promo_requests_select_owner_admin on public.shop_promo_requests for select to authenticated
  using (public.is_admin() or exists (select 1 from public.restaurants r where r.id=shop_promo_requests.restaurant_id and r.owner_id=(select auth.uid()))
    or exists (select 1 from public.shop_staff s where s.restaurant_id=shop_promo_requests.restaurant_id and s.user_id=(select auth.uid()) and s.status='active'));

create or replace function public.shop_submit_promo_request(
  p_restaurant_id uuid,p_title text,p_subtitle text default null,p_image_url text default null,
  p_starts_at timestamptz default null,p_ends_at timestamptz default null
)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_uid uuid := auth.uid();
  v_region_id uuid;
  v_id uuid;
begin
  if v_uid is null then raise exception 'Authentication required'; end if;
  if p_title is null or char_length(btrim(p_title)) not between 3 and 80 then raise exception 'Title must be 3 to 80 characters'; end if;
  if p_subtitle is not null and char_length(btrim(p_subtitle))>180 then raise exception 'Subtitle is too long'; end if;
  if p_starts_at is not null and p_ends_at is not null and p_ends_at<=p_starts_at then raise exception 'End time must be after start time'; end if;
  if p_image_url is not null and (char_length(p_image_url)>500 or p_image_url !~* '^https://' or p_image_url ~ '[<>''"()[:space:]]') then
    raise exception 'Image URL must be a clean HTTPS URL without spaces or quote characters';
  end if;
  select r.region_id into v_region_id from public.restaurants r
    where r.id=p_restaurant_id and (r.owner_id=v_uid or exists(
      select 1 from public.shop_staff s where s.restaurant_id=r.id and s.user_id=v_uid and s.status='active'));
  if not found then raise exception 'You do not have access to this shop'; end if;
  insert into public.shop_promo_requests(restaurant_id,requested_by,region_id,title,subtitle,image_url,starts_at,ends_at)
    values(p_restaurant_id,v_uid,v_region_id,btrim(p_title),nullif(btrim(coalesce(p_subtitle,'')),''),nullif(btrim(coalesce(p_image_url,'')),''),p_starts_at,p_ends_at)
    returning id into v_id;
  return v_id;
end $$;

create or replace function public.shop_my_promo_requests()
returns table (id uuid,title text,subtitle text,status text,admin_note text,created_at timestamptz,
  starts_at timestamptz,ends_at timestamptz,banner_id uuid)
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  return query select q.id,q.title,q.subtitle,q.status,q.admin_note,q.created_at,q.starts_at,q.ends_at,q.banner_id
    from public.shop_promo_requests q where exists (
      select 1 from public.restaurants r where r.id=q.restaurant_id and r.owner_id=auth.uid()
    ) or exists (
      select 1 from public.shop_staff s where s.restaurant_id=q.restaurant_id and s.user_id=auth.uid() and s.status='active'
    ) order by q.created_at desc limit 100;
end $$;

create or replace function public.admin_promo_queue()
returns table (id uuid,restaurant_id uuid,restaurant_name text,title text,subtitle text,image_url text,
  starts_at timestamptz,ends_at timestamptz,status text,admin_note text,created_at timestamptz)
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if not public.is_admin() then raise exception 'Administrator access required'; end if;
  return query select q.id,q.restaurant_id,r.name,q.title,q.subtitle,q.image_url,q.starts_at,q.ends_at,q.status,q.admin_note,q.created_at
    from public.shop_promo_requests q join public.restaurants r on r.id=q.restaurant_id
    order by case q.status when 'requested' then 0 else 1 end,q.created_at desc limit 250;
end $$;

create or replace function public.admin_promo_request_action(p_request_id uuid,p_action text,p_admin_note text default null)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_req public.shop_promo_requests%rowtype;
  v_banner_id uuid;
  v_note text := nullif(btrim(coalesce(p_admin_note,'')), '');
begin
  if not public.is_admin() then raise exception 'Administrator access required'; end if;
  if p_action not in ('approve','reject') then raise exception 'Invalid promotion action'; end if;
  if v_note is not null and char_length(v_note)>1000 then raise exception 'Admin note is too long'; end if;
  select * into v_req from public.shop_promo_requests where id=p_request_id for update;
  if not found or v_req.status<>'requested' then raise exception 'Pending promotion request not found'; end if;
  if p_action='reject' and v_note is null then raise exception 'Add a short reason before rejecting a request'; end if;
  if p_action='approve' then
    insert into public.banners(title,subtitle,image_url,bg_color,action_type,action_value,is_active,sort_order,starts_at,ends_at,region_id)
      values(v_req.title,v_req.subtitle,v_req.image_url,'#14532D','shop',v_req.restaurant_id::text,true,0,v_req.starts_at,v_req.ends_at,v_req.region_id)
      returning id into v_banner_id;
  end if;
  update public.shop_promo_requests set status=case p_action when 'approve' then 'approved' else 'rejected' end,
    admin_note=coalesce(v_note,admin_note),banner_id=v_banner_id,decided_by=auth.uid(),decided_at=now(),updated_at=now()
    where id=p_request_id;
  return v_banner_id;
end $$;

-- Restrict every new workflow RPC to signed-in users. Each sensitive admin
-- function also verifies the caller's database-backed admin role internally.
revoke execute on function public.customer_create_refund_request(uuid,text) from public, anon;
revoke execute on function public.admin_refund_queue() from public, anon;
revoke execute on function public.admin_refund_request_action(uuid,text,text,text) from public, anon;
revoke execute on function public.rider_list_available_shifts() from public, anon;
revoke execute on function public.rider_my_shift_requests() from public, anon;
revoke execute on function public.rider_request_shift(uuid,date) from public, anon;
revoke execute on function public.rider_cancel_shift_request(uuid) from public, anon;
revoke execute on function public.admin_shift_request_queue() from public, anon;
revoke execute on function public.admin_shift_request_action(uuid,text,text) from public, anon;
revoke execute on function public.shop_submit_promo_request(uuid,text,text,text,timestamptz,timestamptz) from public, anon;
revoke execute on function public.shop_my_promo_requests() from public, anon;
revoke execute on function public.admin_promo_queue() from public, anon;
revoke execute on function public.admin_promo_request_action(uuid,text,text) from public, anon;
grant execute on function public.customer_create_refund_request(uuid,text) to authenticated;
grant execute on function public.admin_refund_queue() to authenticated;
grant execute on function public.admin_refund_request_action(uuid,text,text,text) to authenticated;
grant execute on function public.rider_list_available_shifts() to authenticated;
grant execute on function public.rider_my_shift_requests() to authenticated;
grant execute on function public.rider_request_shift(uuid,date) to authenticated;
grant execute on function public.rider_cancel_shift_request(uuid) to authenticated;
grant execute on function public.admin_shift_request_queue() to authenticated;
grant execute on function public.admin_shift_request_action(uuid,text,text) to authenticated;
grant execute on function public.shop_submit_promo_request(uuid,text,text,text,timestamptz,timestamptz) to authenticated;
grant execute on function public.shop_my_promo_requests() to authenticated;
grant execute on function public.admin_promo_queue() to authenticated;
grant execute on function public.admin_promo_request_action(uuid,text,text) to authenticated;
