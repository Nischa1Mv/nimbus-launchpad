SHELL := /bin/bash

.PHONY: reset-project-schemas
# Wipes the per-project data schemas so switching Nimbus projects never leaves
# the previous project's rows behind (e.g. a stale admin user row surviving
# because its table's structure didn't change between projects — atlas's
# schema apply only reconciles DDL, never row data). accesscontrol is left
# alone on purpose: it's the shared RBAC catalog every project reuses.
reset-project-schemas:
	docker compose -p nimbus-shared -f docker-compose.yml exec -T db psql -U postgres -v ON_ERROR_STOP=1 -c "\
		DROP SCHEMA IF EXISTS application CASCADE; CREATE SCHEMA application; \
		DROP SCHEMA IF EXISTS core CASCADE; CREATE SCHEMA core; \
		DROP SCHEMA IF EXISTS cron CASCADE; CREATE SCHEMA cron; \
		DROP SCHEMA IF EXISTS event CASCADE; CREATE SCHEMA event;"
