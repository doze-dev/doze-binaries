-- The hint table exists and the preloaded module answers its GUC.
SELECT count(*) FROM hint_plan.hints;
SHOW pg_hint_plan.enable_hint;
