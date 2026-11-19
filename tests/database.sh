#!/bin/sh
set -eu

# Ephemeral test instance: no published port, named volume or production credentials.
container=$(docker run -d --rm --network none -e POSTGRES_HOST_AUTH_METHOD=trust postgres:18)
trap 'docker stop "$container" >/dev/null 2>&1 || true' EXIT
tries=0
until docker exec "$container" pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1; do
    tries=$((tries + 1))
    if [ "$tries" -ge 60 ]; then echo "Postgres did not start" >&2; exit 1; fi
    sleep 1
done
docker exec -i "$container" psql -X -U postgres -v ON_ERROR_STOP=1 < server/db/001_profile.sql
docker exec -i "$container" psql -X -U postgres -v ON_ERROR_STOP=1 < tests/profile-isolation.sql
