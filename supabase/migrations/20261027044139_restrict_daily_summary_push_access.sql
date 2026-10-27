REVOKE EXECUTE ON FUNCTION public.daily_summary_push() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.daily_summary_push() TO service_role;
