-- Supports the Shop's own-restaurant, newest-first read-only issue history.
create index if not exists order_issues_restaurant_created_idx
  on public.order_issues (restaurant_id, created_at desc);
