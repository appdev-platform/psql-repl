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

# PostgREST Integration

This document describes how to set up PostgREST with the PostgreSQL replication configuration.

## Kubernetes OAuth Integration

PostgREST can be configured to work with Kubernetes OAuth for authentication and authorization. This setup allows using Kubernetes service accounts to control access to the PostgreSQL database through PostgREST.

### 1. Database Role Setup

First, create a PostgreSQL role that matches your service account name:

```bash
# Connect to primary and create the database role
oc rsh deployment/postgres-primary psql -U postgres -d mydatabase -c "
CREATE ROLE dbreader NOLOGIN;
GRANT USAGE ON SCHEMA public TO dbreader;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO dbreader;
GRANT dbreader TO myuser;
"
```

This creates a role `dbreader` with read-only access to all tables in the public schema.

### 2. Service Account Creation

Create a Kubernetes service account that will be used for authentication:

```bash
oc create sa dbreader
```

### 3. PostgREST Deployment

Deploy PostgREST with Kubernetes OAuth configuration:

```bash
oc new-app docker.io/postgrest/postgrest \
  --name=postgrest \
  -e PGRST_DB_URI="postgres://myuser:mypassword@postgres-replica,postgres-primary/mydatabase?target_session_attrs=read-only" \
  -e PGRST_DB_SCHEMA="public" \
  -e PGRST_SERVER_HOST="0.0.0.0" \
  -e PGRST_SERVER_PORT="3000" \
  -e PGRST_JWT_SECRET="$(oc get --raw /openid/v1/jwks)" \
  -e PGRST_JWT_ROLE_CLAIM_KEY=".\"kubernetes.io\".serviceaccount.name" \
  -e PGRST_DB_POOL="10" \
  -e PGRST_DB_POOL_TIMEOUT="10" \
  -e PGRST_DB_MAX_ROWS="1000" \
  -e PGRST_LOG_LEVEL="debug"
```

Key configuration parameters:
- `PGRST_JWT_SECRET`: Uses Kubernetes JWKS endpoint for JWT validation
- `PGRST_JWT_ROLE_CLAIM_KEY`: Maps the service account name from the JWT to PostgreSQL role
- `PGRST_DB_URI`: Configures connection to both primary and replica with read-only preference

### 4. Create Route

Expose PostgREST through an OpenShift route:

```bash
oc create route edge postgrest --service=postgrest
```

### 5. Testing the Setup

Test the API using a service account token:

```bash
# Get the route hostname
POSTGREST_HOST=$(oc get route postgrest -o jsonpath='{.spec.host}')

# Test with service account token
curl -k "https://${POSTGREST_HOST}/sample_table" \
  -H "Authorization: Bearer $(oc create token dbreader)"
```

### How it Works

1. The client requests a token for the service account (`dbreader`)
2. The token contains the service account name in its claims
3. PostgREST validates the token using Kubernetes JWKS
4. PostgREST extracts the service account name using `PGRST_JWT_ROLE_CLAIM_KEY`
5. PostgREST connects to PostgreSQL assuming the matching role
6. PostgreSQL permissions are enforced based on the role grants

This setup provides secure, OAuth-based authentication while maintaining PostgreSQL's role-based access control.

## References

- [PostgREST Documentation](https://postgrest.org/)
- [PostgreSQL Connection URIs](https://www.postgresql.org/docs/current/libpq-connect.html#LIBPQ-CONNSTRING) 