# PostgREST with PostgreSQL Replication

This guide explains how to deploy PostgREST with the PostgreSQL replication setup, automatically routing read queries to replicas and write queries to primary.

## Overview

PostgREST automatically turns your PostgreSQL database into a RESTful API. In this setup, we'll configure it to:
- Use connection pooling
- Route read queries to replicas
- Failover to primary if replica is unavailable
- Expose the API via HTTPS route

## Prerequisites

- Working PostgreSQL replication setup from main README
- OpenShift cluster with access to Docker Hub
- `oc` CLI tool installed
- Sample table created in mydatabase (from main README verification steps)

## Setup

1. **Create anonymous role and grant permissions**
```bash
# Connect to mydatabase
oc rsh deployment/postgres-primary psql -U postgres -d mydatabase -c "
-- Create anonymous role if not exists
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'web_anon') THEN
    CREATE ROLE web_anon NOLOGIN;
  END IF;
END
\$\$;

-- Grant permissions (these are idempotent)
GRANT USAGE ON SCHEMA public TO web_anon;
GRANT ALL ON ALL TABLES IN SCHEMA public TO web_anon;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO web_anon;

-- Grant web_anon role to the connecting user
GRANT web_anon TO myuser;
"
```

2. **Deploy PostgREST**
```bash
# Deploy with connection to both primary and replica
oc new-app docker.io/postgrest/postgrest \
  -e PGRST_DB_URI="postgres://myuser:mypassword@postgres-replica,postgres-primary/mydatabase?target_session_attrs=read-only" \
  -e PGRST_DB_ANON_ROLE="web_anon" \
  -e PGRST_DB_SCHEMA="public" \
  -e PGRST_OPENAPI_SERVER_PROXY_URI=http://0.0.0.0:3000

# Create secure route
oc create route edge --service=postgrest
```

The connection string explained:
- `postgres-replica,postgres-primary`: List of hosts to try connecting to
- `target_session_attrs=read-only`: Prefer connecting to read-only servers (replicas)
- `mydatabase`: Using the database created in initial setup

## Testing

1. **Get the route URL**
```bash
POSTGREST_URL=$(oc get route postgrest -o jsonpath='{.spec.host}')
```

2. **Read Query Test**
```bash
# Should hit replica
curl -k https://$POSTGREST_URL/sample_table?limit=5
```

3. **Write Query Test**
```bash
# Should be routed to primary
curl -k -X POST https://$POSTGREST_URL/sample_table \
  -H "Content-Type: application/json" \
  -d '{"data":"test"}'
```

## Configuration Options

Key environment variables:
- `PGRST_DB_URI`: Database connection string
- `PGRST_DB_ANON_ROLE`: SQL role for anonymous requests (web_anon)
- `PGRST_DB_SCHEMA`: Schema to expose (public)
- `PGRST_OPENAPI_SERVER_PROXY_URI`: Public URL for OpenAPI

## Cleanup

```bash
# Remove PostgREST deployment and route
oc delete all -l app=postgrest
```

## Security Notes

- The edge route terminates TLS at the OpenShift router
- This setup uses anonymous access (no authentication) for testing
- Not recommended for production use without proper authentication

## References

- [PostgREST Documentation](https://postgrest.org/)
- [PostgreSQL Connection URIs](https://www.postgresql.org/docs/current/libpq-connect.html#LIBPQ-CONNSTRING) 