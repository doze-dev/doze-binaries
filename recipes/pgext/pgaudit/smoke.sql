-- pgaudit only registers its GUCs when preloaded; setting one proves it is live.
SET pgaudit.log = 'read';
SELECT 1;
SHOW pgaudit.log;
