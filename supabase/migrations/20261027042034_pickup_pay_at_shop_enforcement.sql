-- Pickup orders are pay-at-shop only. Preserve the current RPC signatures and grants,
-- but enforce the same rule in both direct and multi-shop order creation paths.
DO $migration$
DECLARE
  v_signature regprocedure;
  v_definition text;
  v_old text;
  v_new text;
BEGIN
  v_signature := to_regprocedure('public.place_order(uuid,uuid,jsonb,text,text,text,numeric,timestamptz,jsonb)');
  IF v_signature IS NULL THEN
    RAISE EXCEPTION 'Expected public.place_order signature was not found';
  END IF;
  v_definition := pg_get_functiondef(v_signature);
  v_old := '  if v_type = ''pickup'' then v_tip := 0; end if;';
  v_new := E'  if v_type = ''pickup'' then\n    p_payment_method := ''cod'';\n    p_extra := coalesce(p_extra, ''{}''::jsonb) || jsonb_build_object(''use_wallet'', false, ''pay_plan'', ''full'');\n    v_tip := 0;\n  end if;';
  IF (length(v_definition) - length(replace(v_definition, v_old, ''))) / length(v_old) <> 1 THEN
    RAISE EXCEPTION 'place_order Pickup guard anchor did not match exactly once';
  END IF;
  v_definition := replace(v_definition, v_old, v_new);

  v_old := '  if p_payment_method = ''cod'' and coalesce((v_pay_rules->>''on'')::boolean, false) and v_total > coalesce((v_pay_rules->>''advance_threshold'')::numeric, 10000) and v_total > 0 then';
  v_new := '  if v_type = ''delivery'' and p_payment_method = ''cod'' and coalesce((v_pay_rules->>''on'')::boolean, false) and v_total > coalesce((v_pay_rules->>''advance_threshold'')::numeric, 10000) and v_total > 0 then';
  IF (length(v_definition) - length(replace(v_definition, v_old, ''))) / length(v_old) <> 1 THEN
    RAISE EXCEPTION 'place_order delivery-advance guard anchor did not match exactly once';
  END IF;
  v_definition := replace(v_definition, v_old, v_new);
  EXECUTE v_definition;

  v_signature := to_regprocedure('public.place_multi_order_v2(jsonb,uuid,text,text,text,numeric,timestamptz,jsonb,numeric)');
  IF v_signature IS NULL THEN
    RAISE EXCEPTION 'Expected public.place_multi_order_v2 signature was not found';
  END IF;
  v_definition := pg_get_functiondef(v_signature);
  v_old := '  if v_type = ''pickup'' then v_tip := 0; end if;';
  v_new := E'  if v_type = ''pickup'' then\n    p_payment_method := ''cod'';\n    p_points_use := 0;\n    p_extra := coalesce(p_extra, ''{}''::jsonb) || jsonb_build_object(''use_wallet'', false, ''pay_plan'', ''full'');\n    v_tip := 0;\n  end if;';
  IF (length(v_definition) - length(replace(v_definition, v_old, ''))) / length(v_old) <> 1 THEN
    RAISE EXCEPTION 'place_multi_order_v2 Pickup guard anchor did not match exactly once';
  END IF;
  v_definition := replace(v_definition, v_old, v_new);
  EXECUTE v_definition;
END;
$migration$;
