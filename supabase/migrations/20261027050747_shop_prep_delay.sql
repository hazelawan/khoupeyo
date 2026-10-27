-- Shop preparation delays: allow up to two 15-minute extensions per order.
-- Customer-facing prices are never changed by this RPC.

ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS prep_delay_count smallint NOT NULL DEFAULT 0;

ALTER TABLE public.orders
  ALTER COLUMN prep_delay_count SET DEFAULT 0,
  ALTER COLUMN prep_delay_count SET NOT NULL;

DO $migration$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conrelid = 'public.orders'::regclass
      AND conname = 'orders_prep_delay_count_range'
  ) THEN
    ALTER TABLE public.orders
      ADD CONSTRAINT orders_prep_delay_count_range
      CHECK (prep_delay_count BETWEEN 0 AND 2);
  END IF;
END
$migration$;

CREATE OR REPLACE FUNCTION public.guard_order_prep_delay_count()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public'
AS $function$
BEGIN
  IF current_user NOT IN ('postgres', 'service_role') AND (
       (TG_OP = 'INSERT' AND coalesce(NEW.prep_delay_count, 0) <> 0)
       OR (TG_OP = 'UPDATE' AND NEW.prep_delay_count IS DISTINCT FROM OLD.prep_delay_count)
     ) THEN
    RAISE EXCEPTION 'Preparation delay count is controlled by the Shop delay RPC';
  END IF;
  RETURN NEW;
END
$function$;

REVOKE ALL ON FUNCTION public.guard_order_prep_delay_count() FROM PUBLIC, anon, authenticated, service_role;
DROP TRIGGER IF EXISTS orders_guard_prep_delay_count ON public.orders;
CREATE TRIGGER orders_guard_prep_delay_count
  BEFORE INSERT OR UPDATE ON public.orders
  FOR EACH ROW
  EXECUTE FUNCTION public.guard_order_prep_delay_count();

CREATE OR REPLACE FUNCTION public.shop_extend_prep_time(p_order_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_order public.orders%ROWTYPE;
  v_default_prep integer;
  v_prep_now integer;
  v_prep_next integer;
  v_used integer;
  v_user uuid := auth.uid();
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'Please log in first';
  END IF;

  SELECT * INTO v_order
  FROM public.orders
  WHERE id = p_order_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Order not found';
  END IF;

  IF NOT public.owns_restaurant(v_order.restaurant_id) THEN
    RAISE EXCEPTION 'You cannot change this order';
  END IF;

  IF v_order.status <> 'preparing' THEN
    RAISE EXCEPTION 'Only orders being prepared can be delayed';
  END IF;

  v_used := coalesce(v_order.prep_delay_count, 0);
  IF v_used >= 2 THEN
    RAISE EXCEPTION 'The maximum of two preparation delays has been reached';
  END IF;

  SELECT prep_time_minutes INTO v_default_prep
  FROM public.restaurants
  WHERE id = v_order.restaurant_id;

  v_prep_now := greatest(coalesce(v_order.prep_minutes, v_default_prep, 25), 5);
  v_prep_next := v_prep_now + 15;

  UPDATE public.orders
  SET prep_minutes = v_prep_next,
      prep_delay_count = v_used + 1
  WHERE id = p_order_id;

  PERFORM public.push_notify(
    ARRAY[v_order.customer_id],
    'Order preparation update | آرڈر کی تیاری کی اطلاع',
    'The shop needs 15 more minutes to prepare your order. No extra charge. دکان کو آرڈر تیار کرنے کے لیے 15 منٹ مزید درکار ہیں۔ کوئی اضافی چارج نہیں۔',
    'customer.html',
    'order-prep-delay-' || p_order_id::text || '-' || (v_used + 1)::text
  );

  RETURN jsonb_build_object(
    'prep_minutes', v_prep_next,
    'delays_used', v_used + 1,
    'delay_minutes', 15
  );
END
$function$;

REVOKE ALL ON FUNCTION public.shop_extend_prep_time(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.shop_extend_prep_time(uuid) TO authenticated, service_role;
