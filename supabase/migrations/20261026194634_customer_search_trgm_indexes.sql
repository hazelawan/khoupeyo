-- Customer server-side search: index substring searches and expose only the
-- fields used by the public Customer catalog projection.
create extension if not exists pg_trgm with schema extensions;

create index if not exists menu_items_name_trgm_idx
  on public.menu_items using gin (name extensions.gin_trgm_ops)
  where is_available and is_approved;

create index if not exists menu_items_keywords_trgm_idx
  on public.menu_items using gin (keywords extensions.gin_trgm_ops)
  where keywords is not null and is_available and is_approved;

create index if not exists menu_items_description_trgm_idx
  on public.menu_items using gin (description extensions.gin_trgm_ops)
  where description is not null and is_available and is_approved;

create index if not exists menu_categories_name_trgm_idx
  on public.menu_categories using gin (name extensions.gin_trgm_ops)
  where name is not null;

create or replace function public.search_items(p_terms text[], p_region uuid)
returns setof jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
  select jsonb_build_object(
           'id', m.id,
           'name', m.name,
           'price', m.price,
           'compare_price', m.compare_price,
           'photo_url', m.photo_url,
           'description', m.description,
           'keywords', m.keywords,
           'duration_min', m.duration_min,
           'svc', m.svc,
           'avail_from', m.avail_from,
           'avail_to', m.avail_to,
           'restaurant_id', m.restaurant_id,
           'category_id', m.category_id,
           'is_available', m.is_available,
           'is_featured', m.is_featured,
           'created_at', m.created_at,
           'heavy_fee', m.heavy_fee,
           'weight_kg', m.weight_kg,
           'stock_qty', m.stock_qty,
           'photos', m.photos,
           'back_photos', m.back_photos,
           'category', jsonb_build_object('name', c.name),
           'restaurants', jsonb_build_object(
             'id', r.id,
             'name', r.name,
             'logo_url', r.logo_url,
             'is_open', r.is_open,
             'is_active', r.is_active,
             'region_id', r.region_id
           )
         )
    from public.menu_items m
    join public.restaurants r on r.id = m.restaurant_id
    left join public.menu_categories c on c.id = m.category_id
   where r.is_active
     and m.is_available
     and m.is_approved
     and (p_region is null or r.region_id = p_region)
     and coalesce(array_length(p_terms, 1), 0) <= 25
     and exists (
       select 1
         from unnest(p_terms[1:25]) as t(term)
        where length(trim(t.term)) between 2 and 100
          and (
               m.name ilike '%' || trim(t.term) || '%'
            or coalesce(m.keywords, '') ilike '%' || trim(t.term) || '%'
            or coalesce(m.description, '') ilike '%' || trim(t.term) || '%'
            or coalesce(c.name, '') ilike '%' || trim(t.term) || '%'
          )
     )
   order by (
       exists (
         select 1
           from unnest(p_terms[1:25]) as t(term)
          where length(trim(t.term)) between 2 and 100
            and m.name ilike '%' || trim(t.term) || '%'
       )
     ) desc,
     m.is_featured desc,
     m.name
   limit 80
$function$;
