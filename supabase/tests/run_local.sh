#!/usr/bin/env bash
# Rebuild a scratch database from the migrations and run the SQL tests.
set -euo pipefail
cd "$(dirname "$0")/.."
PG="psql -X -q -v ON_ERROR_STOP=1 -h ${PGHOST:-/tmp/pgdata} -p ${PGPORT:-54329} -U postgres"
$PG -d postgres -c 'drop database if exists pickup_test' -c 'create database pickup_test'
$PG -d postgres -c 'drop role if exists anon, authenticated, service_role' 2>/dev/null || true
$PG -d pickup_test -f tests/supabase_stub.sql
for f in migrations/*.sql; do case "$f" in *cron*|*push_hook*) continue;; esac; $PG -d pickup_test -f "$f"; done
for t in tests/test_*.sql; do echo "== $t"; $PG -d pickup_test -f "$t"; done
if command -v deno >/dev/null; then echo "== tests/mcp_e2e.ts"; deno run -A tests/mcp_e2e.ts; echo "MCP E2E PASSED"; fi
echo "ALL TESTS PASSED"
