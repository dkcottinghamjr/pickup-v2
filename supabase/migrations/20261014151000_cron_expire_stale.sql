-- Expire stale requests, offers and approvals every 5 minutes.
-- (Skipped by the local test runner, which has no pg_cron.)
create extension if not exists pg_cron with schema pg_catalog;
grant usage on schema cron to postgres;
select cron.schedule('pickup-expire-stale', '*/5 * * * *', $$select private.expire_stale()$$);
