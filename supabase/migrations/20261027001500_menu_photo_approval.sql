-- Shop photo approval workflow. New photos stay out of the public catalog until an Admin approves them.
-- Existing live photos remain unchanged while a submission is pending or rejected.

create table if not exists public.menu_photo_submissions (
  id uuid primary key default gen_random_uuid(),
  menu_item_id uuid not null references public.menu_items(id) on delete cascade,
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  submitted_by uuid not null references auth.users(id) on delete restrict,
  photo_url text,
  photos text[] not null default '{}'::text[],
  back_photos jsonb not null default '[]'::jsonb,
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  review_note text,
  submitted_at timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by uuid references auth.users(id) on delete set null,
  constraint menu_photo_submissions_photos_count check (coalesce(array_length(photos, 1), 0) <= 10),
  constraint menu_photo_submissions_back_photos_array check (jsonb_typeof(back_photos) = 'array' and jsonb_array_length(back_photos) <= 11),
  constraint menu_photo_submissions_photo_url_length check (photo_url is null or char_length(photo_url) <= 2048),
  constraint menu_photo_submissions_review_note_length check (review_note is null or char_length(review_note) <= 2000)
);

create index if not exists menu_photo_submissions_shop_idx
  on public.menu_photo_submissions (restaurant_id, submitted_at desc);
create index if not exists menu_photo_submissions_queue_idx
  on public.menu_photo_submissions (status, submitted_at desc);
create unique index if not exists menu_photo_submissions_one_pending_per_item
  on public.menu_photo_submissions (menu_item_id) where status = 'pending';

alter table public.menu_photo_submissions enable row level security;
revoke all on public.menu_photo_submissions from anon, authenticated;
grant select on public.menu_photo_submissions to authenticated;
drop policy if exists menu_photo_submissions_owner_admin_read on public.menu_photo_submissions;
create policy menu_photo_submissions_owner_admin_read on public.menu_photo_submissions
  for select to authenticated using (public.is_admin() or public.owns_restaurant(restaurant_id));

create or replace function public.shop_submit_menu_photo(
  p_menu_item_id uuid,
  p_photo_url text,
  p_photos text[],
  p_back_photos jsonb
)
returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_restaurant_id uuid;
  v_id uuid;
  v_photos text[] := coalesce(p_photos, '{}'::text[]);
  v_back_photos jsonb := coalesce(p_back_photos, '[]'::jsonb);
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select restaurant_id into v_restaurant_id from public.menu_items where id = p_menu_item_id;
  if not found then raise exception 'Product not found'; end if;
  if not public.owns_restaurant(v_restaurant_id) then raise exception 'Shop access required'; end if;
  if p_photo_url is not null and char_length(p_photo_url) > 2048 then raise exception 'Photo URL is too long'; end if;
  if coalesce(array_ndims(v_photos), 1) <> 1 or coalesce(array_length(v_photos, 1), 0) > 10 then
    raise exception 'A product can have up to 10 additional photos';
  end if;
  if exists (select 1 from unnest(v_photos) as u(url) where u.url is null or char_length(u.url) > 2048) then
    raise exception 'Invalid additional photo URL';
  end if;
  if jsonb_typeof(v_back_photos) <> 'array' or jsonb_array_length(v_back_photos) > 11 then
    raise exception 'Invalid back-photo list';
  end if;
  if exists (
    select 1 from jsonb_array_elements(v_back_photos) as e(value)
    where jsonb_typeof(e.value) not in ('string','null')
       or (jsonb_typeof(e.value) = 'string' and char_length(e.value #>> '{}') > 2048)
  ) then raise exception 'Invalid back-photo URL'; end if;

  insert into public.menu_photo_submissions(menu_item_id, restaurant_id, submitted_by, photo_url, photos, back_photos)
    values (p_menu_item_id, v_restaurant_id, auth.uid(), p_photo_url, v_photos, v_back_photos)
    returning id into v_id;
  return v_id;
exception when unique_violation then
  raise exception 'This product already has a photo submission awaiting review';
end;
$$;

create or replace function public.admin_menu_photo_review_queue()
returns table (
  id uuid,
  restaurant_id uuid,
  shop_name text,
  menu_item_id uuid,
  product_name text,
  photo_url text,
  photos text[],
  back_photos jsonb,
  submitted_at timestamptz
)
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if not public.is_admin() then raise exception 'Administrator access required'; end if;
  return query
    select s.id, s.restaurant_id, r.name, s.menu_item_id, m.name,
      s.photo_url, s.photos, s.back_photos, s.submitted_at
    from public.menu_photo_submissions s
    join public.restaurants r on r.id = s.restaurant_id
    join public.menu_items m on m.id = s.menu_item_id
    where s.status = 'pending'
    order by s.submitted_at asc
    limit 250;
end;
$$;

create or replace function public.admin_review_menu_photo_submission(
  p_submission_id uuid,
  p_action text,
  p_note text default null
)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_submission public.menu_photo_submissions%rowtype;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
begin
  if not public.is_admin() then raise exception 'Administrator access required'; end if;
  if p_action not in ('approve','reject') then raise exception 'Invalid photo review action'; end if;
  if v_note is not null and char_length(v_note) > 2000 then raise exception 'Review note is too long'; end if;
  if p_action = 'reject' and v_note is null then raise exception 'Add a reason before rejecting photos'; end if;
  select * into v_submission from public.menu_photo_submissions where id = p_submission_id for update;
  if not found or v_submission.status <> 'pending' then raise exception 'Pending photo submission not found'; end if;

  if p_action = 'approve' then
    update public.menu_items set
      photo_url = v_submission.photo_url,
      photos = v_submission.photos,
      back_photos = v_submission.back_photos
    where id = v_submission.menu_item_id and restaurant_id = v_submission.restaurant_id;
    if not found then raise exception 'Product no longer exists'; end if;
  end if;

  update public.menu_photo_submissions set
    status = p_action,
    review_note = v_note,
    reviewed_at = now(),
    reviewed_by = auth.uid()
  where id = p_submission_id;
end;
$$;

revoke all on function public.shop_submit_menu_photo(uuid, text, text[], jsonb) from public, anon;
revoke all on function public.admin_menu_photo_review_queue() from public, anon;
revoke all on function public.admin_review_menu_photo_submission(uuid, text, text) from public, anon;
grant execute on function public.shop_submit_menu_photo(uuid, text, text[], jsonb) to authenticated;
grant execute on function public.admin_menu_photo_review_queue() to authenticated;
grant execute on function public.admin_review_menu_photo_submission(uuid, text, text) to authenticated;
