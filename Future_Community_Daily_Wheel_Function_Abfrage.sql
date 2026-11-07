-- Bitte separat im Supabase SQL Editor ausführen und das Ergebnis zurückschicken.
-- Damit kann die Zufallsauswahl des täglichen Glücksrads passend zu deiner
-- tatsächlich installierten Tabellenstruktur korrigiert werden.
SELECT pg_get_functiondef('public.spin_daily_wheel()'::regprocedure);
