CREATE OR REPLACE FUNCTION public.parcel_dispatch_tick()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  r record;
  n int := 0;
  v_rid uuid := public.my_rider_id();
  v_region uuid;
  v_trusted boolean := coalesce(auth.role(), '') = 'service_role' OR session_user = 'postgres';
BEGIN
  IF NOT v_trusted THEN
    IF v_rid IS NULL THEN RETURN 0; END IF;
    SELECT x.region_id INTO v_region
      FROM public.riders x
     WHERE x.id = v_rid
       AND x.is_approved
       AND x.is_online
       AND NOT coalesce(x.on_break, false)
       AND NOT coalesce(x.blocked, false)
       AND NOT coalesce(x.suspended_until > now(), false);
    IF v_region IS NULL THEN RETURN 0; END IF;
  END IF;

  FOR r IN
    SELECT id, region_id
      FROM public.parcels
     WHERE status = 'placed'
       AND rider_id IS NULL
       AND NOT dispatch_open
       AND (offered_rider_id IS NULL OR offer_expires_at < now())
       AND created_at > now() - interval '12 hours'
       AND (v_trusted OR region_id = v_region)
  LOOP
    CONTINUE WHEN NOT coalesce((public.setting_val('dispatch_auto', r.region_id) #>> '{}')::boolean, false);
    PERFORM public.parcel_dispatch_next(r.id);
    n := n + 1;
  END LOOP;
  RETURN n;
END
$function$;

REVOKE EXECUTE ON FUNCTION public.parcel_dispatch_next(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.parcel_dispatch_next(uuid) TO service_role;
REVOKE EXECUTE ON FUNCTION public.parcel_dispatch_tick() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.parcel_dispatch_tick() TO authenticated, service_role;
