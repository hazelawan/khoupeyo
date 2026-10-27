ALTER TABLE public.reviews
  ADD COLUMN shop_reply text,
  ADD COLUMN shop_replied_at timestamptz,
  ADD CONSTRAINT reviews_shop_reply_length
    CHECK (shop_reply IS NULL OR char_length(shop_reply) <= 500),
  ADD CONSTRAINT reviews_shop_reply_timestamp_pair
    CHECK ((shop_reply IS NULL) = (shop_replied_at IS NULL));

CREATE OR REPLACE FUNCTION public.shop_reply_to_review(p_review_id uuid, p_reply text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth, pg_temp
AS $function$
DECLARE
  v_reply text := btrim(p_reply);
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Authentication required' USING ERRCODE = '42501';
  END IF;
  IF p_review_id IS NULL THEN
    RAISE EXCEPTION 'Review is required' USING ERRCODE = '22023';
  END IF;
  IF v_reply IS NULL OR char_length(v_reply) = 0 THEN
    RAISE EXCEPTION 'Reply cannot be empty' USING ERRCODE = '22023';
  END IF;
  IF char_length(v_reply) > 500 THEN
    RAISE EXCEPTION 'Reply must be 500 characters or fewer' USING ERRCODE = '22023';
  END IF;

  UPDATE public.reviews AS r
     SET shop_reply = v_reply,
         shop_replied_at = statement_timestamp()
   WHERE r.id = p_review_id
     AND public.owns_restaurant(r.restaurant_id);

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Review not found or Shop access denied' USING ERRCODE = '42501';
  END IF;
END
$function$;

REVOKE ALL ON FUNCTION public.shop_reply_to_review(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.shop_reply_to_review(uuid, text) TO authenticated;
