-- Private support screenshots for Shop bug reports and Rider feedback.
-- Screenshots are never public. Only the ticket requester and authenticated admins
-- may read them; only the requester may upload to their own ticket.
create table if not exists public.support_attachments (
  id uuid primary key default gen_random_uuid(),
  ticket_id uuid not null references public.support_tickets(id) on delete cascade,
  uploader_id uuid not null references auth.users(id) on delete cascade,
  storage_path text not null unique check (char_length(storage_path) between 1 and 500),
  file_name text not null check (char_length(file_name) between 1 and 255),
  mime_type text not null check (mime_type in ('image/jpeg','image/png','image/webp')),
  size_bytes bigint not null check (size_bytes between 1 and 5242880),
  created_at timestamptz not null default now()
);
create index if not exists support_attachments_ticket_created_idx on public.support_attachments(ticket_id,created_at,id);
create index if not exists support_attachments_uploader_idx on public.support_attachments(uploader_id);
alter table public.support_attachments enable row level security;
revoke all on public.support_attachments from public,anon,authenticated;
grant select,insert on public.support_attachments to authenticated;
drop policy if exists support_attachments_select_owner_admin on public.support_attachments;
create policy support_attachments_select_owner_admin on public.support_attachments
  for select to authenticated using (
    public.is_admin() or exists (
      select 1 from public.support_tickets t where t.id=support_attachments.ticket_id and t.requester_id=(select auth.uid())
    )
  );
drop policy if exists support_attachments_insert_own_ticket on public.support_attachments;
create policy support_attachments_insert_own_ticket on public.support_attachments
  for insert to authenticated with check (
    uploader_id=(select auth.uid())
    and storage_path like (select auth.uid())::text || '/' || ticket_id::text || '/%'
    and exists (select 1 from public.support_tickets t where t.id=support_attachments.ticket_id and t.requester_id=(select auth.uid()))
  );

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
  values('support-attachments','support-attachments',false,5242880,array['image/jpeg','image/png','image/webp'])
  on conflict(id) do update set public=false,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;

drop policy if exists support_screenshots_select_owner_admin on storage.objects;
create policy support_screenshots_select_owner_admin on storage.objects
  for select to authenticated using (
    bucket_id='support-attachments' and (
      public.is_admin() or exists (
        select 1 from public.support_tickets t
        where t.id::text=split_part(storage.objects.name,'/',2) and t.requester_id=(select auth.uid())
      )
    )
  );
drop policy if exists support_screenshots_insert_own_ticket on storage.objects;
create policy support_screenshots_insert_own_ticket on storage.objects
  for insert to authenticated with check (
    bucket_id='support-attachments'
    and split_part(storage.objects.name,'/',1)=(select auth.uid())::text
    and exists (
      select 1 from public.support_tickets t
      where t.id::text=split_part(storage.objects.name,'/',2) and t.requester_id=(select auth.uid())
    )
  );
drop policy if exists support_screenshots_delete_owner_admin on storage.objects;
create policy support_screenshots_delete_owner_admin on storage.objects
  for delete to authenticated using (
    bucket_id='support-attachments' and (
      public.is_admin() or (
        split_part(storage.objects.name,'/',1)=(select auth.uid())::text
        and exists (
          select 1 from public.support_tickets t
          where t.id::text=split_part(storage.objects.name,'/',2) and t.requester_id=(select auth.uid())
        )
      )
    )
  );
