DO $$ BEGIN
  IF NOT json_matches_schema('{"type": "object", "required": ["a"]}', '{"a": 1}') THEN
    RAISE EXCEPTION 'valid document rejected';
  END IF;
  IF jsonb_matches_schema('{"type": "object", "required": ["a"]}', '{"b": 1}') THEN
    RAISE EXCEPTION 'invalid document accepted';
  END IF;
END $$;
