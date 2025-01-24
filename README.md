# PostgreSQL Replication on OpenShift

⚠️ **IMPORTANT WARNING**
This configuration is intended for Proof of Concept (POC) and learning purposes only. It is NOT production-ready.

## Prerequisites

- OpenShift 4.x cluster
- Access to registry.redhat.io
- `oc` CLI tool installed
- Storage class available for persistent volumes

## Installation

### 1. Deploy Primary Instance
```bash
# Deploy primary PostgreSQL
oc new-app registry.redhat.io/rhel9/postgresql-16~https://github.com/fjcloud/psql-repl.git \
  --name=postgres-primary \
  -e POSTGRESQL_USER=myuser \
  -e POSTGRESQL_PASSWORD=mypassword \
  -e POSTGRESQL_DATABASE=mydatabase \
  -e POSTGRESQL_REPLICATION_USER=replicator \
  -e POSTGRESQL_REPLICATION_PASSWORD=replpassword \
  -e POSTGRESQL_REPLICA_HOST=postgres-replica \
  -e POSTGRESQL_ADMIN_PASSWORD=adminpassword \
  -e IS_PRIMARY=true

# Create and attach PVC to primary
oc set volume deployment/postgres-primary --add \
  --name=postgres-data \
  --type=pvc \
  --claim-size=10Gi \
  --mount-path=/var/lib/pgsql/data

# Wait for primary to be ready
oc wait --for=condition=available deployment/postgres-primary --timeout=120s
```

### 2. Deploy Replica Instance
```bash
# Deploy replica PostgreSQL
oc new-app registry.redhat.io/rhel9/postgresql-16~https://github.com/fjcloud/psql-repl.git \
  --name=postgres-replica \
  -e POSTGRESQL_REPLICATION_USER=replicator \
  -e POSTGRESQL_REPLICATION_PASSWORD=replpassword \
  -e POSTGRESQL_PRIMARY_HOST=postgres-primary \
  -e IS_PRIMARY=false \
  -e POSTGRESQL_MIGRATION_REMOTE_HOST=postgres-primary \
  -e POSTGRESQL_MIGRATION_ADMIN_PASSWORD=mypassword \
  -e POSTGRESQL_MIGRATION_IGNORE_ERRORS=yes

# Create and attach PVC to replica
oc set volume deployment/postgres-replica --add \
  --name=postgres-data \
  --type=pvc \
  --claim-size=10Gi \
  --mount-path=/var/lib/pgsql/data

# Wait for replica to be ready
oc wait --for=condition=available deployment/postgres-replica --timeout=120s
```

## Verification

### Create Test Data Function
```bash
# Create test table and function on primary
oc rsh deployment/postgres-primary psql -d mydatabase -c "
-- Create table if not exists
CREATE TABLE IF NOT EXISTS sample_table (
    id SERIAL PRIMARY KEY,
    data TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Create function to generate sample data
CREATE OR REPLACE FUNCTION add_sample_data(num_rows integer DEFAULT 1000)
RETURNS void AS \$\$
BEGIN
    INSERT INTO sample_table (data)
    SELECT 
        md5(random()::text)
    FROM generate_series(1, num_rows);
END;
\$\$ LANGUAGE plpgsql;"

# Generate test data
oc rsh deployment/postgres-primary psql -d mydatabase -c "SELECT add_sample_data();"

# Verify data on primary
oc rsh deployment/postgres-primary psql -d mydatabase -c "SELECT count(*) FROM sample_table;"

# Verify data on replica
oc rsh deployment/postgres-replica psql -d mydatabase -c "SELECT count(*) FROM sample_table;"
```

### Test Replication with New Data
```bash
# Add more data on primary
oc rsh deployment/postgres-primary psql -d mydatabase -c "SELECT add_sample_data(500);"

# Check counts on both servers
echo "Primary count:"
oc rsh deployment/postgres-primary psql -d mydatabase -c "SELECT count(*) FROM sample_table;"
echo "Replica count:"
oc rsh deployment/postgres-replica psql -d mydatabase -c "SELECT count(*) FROM sample_table;"
```

### Check Replication Status
```bash
# On primary
oc rsh deployment/postgres-primary psql -c "SELECT application_name, state, sync_state FROM pg_stat_replication;"
oc rsh deployment/postgres-primary psql -c "SELECT slot_name, active FROM pg_replication_slots;"

# On replica
oc rsh deployment/postgres-replica psql -c "SELECT pg_is_in_recovery();"
```

### Check Replication Lag
```bash
# On replica
oc rsh deployment/postgres-replica psql -c "SELECT now() - pg_last_xact_replay_timestamp() AS replication_lag;"
```

## Failover Procedures

### When Primary Fails

1. **Promote replica to primary:**
```bash
# Verify replica is ready
oc rsh deployment/postgres-replica psql -c "SELECT pg_is_in_recovery();"

# Promote replica
oc rsh deployment/postgres-replica pg_ctl promote -D /var/lib/pgsql/data/userdata

# Verify promotion succeeded
oc rsh deployment/postgres-replica psql -c "SELECT pg_is_in_recovery();"  # Should return 'f'
```

2. **Clean up failed primary :**
```bash
oc delete pvc $(oc get deployment postgres-primary -o jsonpath='{.spec.template.spec.volumes[*].persistentVolumeClaim.claimName}') --wait=false
oc delete all -l app=postgres-primary
```

### When Ready to Restore Original Setup

1. **Set current primary (former replica) to read-only:**
```bash
# Set database to read-only mode
oc rsh deployment/postgres-replica psql -c "ALTER SYSTEM SET default_transaction_read_only = on;"
oc rsh deployment/postgres-replica psql -c "SELECT pg_reload_conf();"

# Verify read-only status
oc rsh deployment/postgres-replica psql -c "SHOW default_transaction_read_only;"  # Should return 'on'
```

2. **Deploy new primary using replica's data:**
```bash
# Deploy primary with migration from current primary (former replica)
oc new-app registry.redhat.io/rhel9/postgresql-16~https://github.com/fjcloud/psql-repl.git \
  --name=postgres-primary \
  -e POSTGRESQL_REPLICATION_USER=replicator \
  -e POSTGRESQL_REPLICATION_PASSWORD=replpassword \
  -e IS_PRIMARY=true \
  -e POSTGRESQL_MIGRATION_REMOTE_HOST=postgres-replica \
  -e POSTGRESQL_MIGRATION_ADMIN_PASSWORD=adminpassword \
  -e POSTGRESQL_MIGRATION_IGNORE_ERRORS=yes

# Create and attach PVC to primary
oc set volume deployment/postgres-primary --add \
  --name=postgres-data \
  --type=pvc \
  --claim-size=10Gi \
  --mount-path=/var/lib/pgsql/data

oc wait --for=condition=available deployment/postgres-primary --timeout=120s
```

2. **Reconfigure replica:**
```bash
# If primary ready you can reconfigure replica
oc delete pvc $(oc get deployment postgres-replica -o jsonpath='{.spec.template.spec.volumes[*].persistentVolumeClaim.claimName}') --wait=false
oc delete all -l app=postgres-replica

oc new-app registry.redhat.io/rhel9/postgresql-16~https://github.com/fjcloud/psql-repl.git \
  --name=postgres-replica \
  -e POSTGRESQL_REPLICATION_USER=replicator \
  -e POSTGRESQL_REPLICATION_PASSWORD=replpassword \
  -e POSTGRESQL_PRIMARY_HOST=postgres-primary \
  -e IS_PRIMARY=false \
  -e POSTGRESQL_MIGRATION_REMOTE_HOST=postgres-primary \
  -e POSTGRESQL_MIGRATION_ADMIN_PASSWORD=adminpassword \
  -e POSTGRESQL_MIGRATION_IGNORE_ERRORS=yes

oc set volume deployment/postgres-replica --add \
  --name=postgres-data \
  --type=pvc \
  --claim-size=10Gi \
  --mount-path=/var/lib/pgsql/data
```

## Cleanup

### Complete Cleanup
Remove everything:
```bash
# Remove primary
oc delete pvc $(oc get deployment postgres-primary -o jsonpath='{.spec.template.spec.volumes[*].persistentVolumeClaim.claimName}') --wait=false
oc delete all -l app=postgres-primary

# Remove replica
oc delete pvc $(oc get deployment postgres-replica -o jsonpath='{.spec.template.spec.volumes[*].persistentVolumeClaim.claimName}') --wait=false
oc delete all -l app=postgres-replica
```

## Troubleshooting

### Check Logs
```bash
oc logs deployment/postgres-primary
oc logs deployment/postgres-replica
```

### Check Configuration
```bash
# On primary
oc rsh deployment/postgres-primary
cat $PGDATA/pg_hba.conf | grep replication
psql -c "SELECT * FROM pg_replication_slots;"

# On replica
oc rsh deployment/postgres-replica
cat $PGDATA/postgresql.auto.conf
```

## Technical Details

### Environment Variables

#### Required Variables
- `IS_PRIMARY`: Set to "true" for primary, "false" for replica

#### Primary Node Variables
- `POSTGRESQL_USER`: Database user
- `POSTGRESQL_PASSWORD`: Database password
- `POSTGRESQL_DATABASE`: Database name
- `POSTGRESQL_REPLICATION_USER`: Replication user (default: replicator)
- `POSTGRESQL_REPLICATION_PASSWORD`: Replication password
- `POSTGRESQL_REPLICA_HOST`: Replica hostname (optional for primary)
- `POSTGRESQL_ADMIN_PASSWORD`: Password for 'postgres' admin user (required)

#### Replica Node Variables
- `POSTGRESQL_REPLICATION_USER`: Must match primary's replication user
- `POSTGRESQL_REPLICATION_PASSWORD`: Must match primary's replication password
- `POSTGRESQL_PRIMARY_HOST`: Primary server hostname
- `POSTGRESQL_MIGRATION_REMOTE_HOST`: Primary server hostname for initial sync
- `POSTGRESQL_MIGRATION_ADMIN_PASSWORD`: Password for migration user
- `POSTGRESQL_MIGRATION_IGNORE_ERRORS`: Set to "yes" to continue despite migration errors

### Repository Structure
```
.
├── postgresql-cfg/          # Configuration files loaded at container start
│   ├── replication.conf    # PostgreSQL replication settings
│   └── logging.conf        # PostgreSQL logging configuration
├── postgresql-pre-start/   # Scripts run before PostgreSQL starts
│   └── prepare-replica.sh  # Replica initialization script
└── postgresql-start/       # Scripts run after PostgreSQL starts
    └── configure-replication.sh  # Primary configuration script
```

## References

- [PostgreSQL 16 Replication Documentation](https://www.postgresql.org/docs/16/high-availability.html)
- [Red Hat PostgreSQL Container](https://catalog.redhat.com/software/containers/rhel9/postgresql-16/657b03866783e1b1fb87e142)
- [OpenShift Container Platform Documentation](https://docs.openshift.com/)
- [PostgREST Documentation](https://postgrest.org/en/stable/references/api.html) - For REST API access to PostgreSQL
+ 
+ See [POSTGREST.md](POSTGREST.md) for instructions on setting up PostgREST with this replication configuration.