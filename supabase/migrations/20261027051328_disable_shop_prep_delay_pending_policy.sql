-- Owner has not approved the provisional delay values. Disable app execution until
-- replacement minutes, extension limit and notification behavior are supplied.
REVOKE ALL ON FUNCTION public.shop_extend_prep_time(uuid) FROM PUBLIC, anon, authenticated, service_role;
