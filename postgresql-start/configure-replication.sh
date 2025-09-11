#!/bin/bash
set -e

echo "Starting replication configuration..."

# Default values for unset variables
IS_PRIMARY=${IS_PRIMARY:-false}
POSTGRESQL_REPLICATION_USER=${POSTGRESQL_REPLICATION_USER:-replicator}

echo "Running as primary: ${IS_PRIMARY}"

if [ "${IS_PRIMARY}" = "true" ]; then

    echo "Ensuring role permissions for ${POSTGRESQL_USER}..."
    psql -U postgres -c "ALTER ROLE ${POSTGRESQL_USER} CREATEDB CREATEROLE;" || echo "⚠️ Failed to alter role ${POSTGRESQL_USER}" 

    echo "=== Configuring primary node ==="
    
    # Configure pg_hba.conf for replication
    if [ -f "${PGDATA}/pg_hba.conf" ]; then
        echo "Configuring pg_hba.conf..."
        
        echo "Removing existing replication entries..."
        sed -i '/^host[[:space:]]*replication/d' "${PGDATA}/pg_hba.conf"
        
        echo "Adding replication access..."
        echo "host replication ${POSTGRESQL_REPLICATION_USER} all scram-sha-256" >> "${PGDATA}/pg_hba.conf"
        
        echo "Setting pg_hba.conf permissions..."
        chmod 600 "${PGDATA}/pg_hba.conf"
        echo "pg_hba.conf configuration completed"
    else
        echo "WARNING: pg_hba.conf not found in ${PGDATA}"
    fi
    
    # Create replication user if it doesn't exist
    echo "Checking for replication user..."
    if ! psql -U postgres -tAc "SELECT 1 FROM pg_roles WHERE rolname='${POSTGRESQL_REPLICATION_USER}'" | grep -q 1; then
        echo "Creating replication user: ${POSTGRESQL_REPLICATION_USER}"
        psql -v ON_ERROR_STOP=1 --username postgres <<-EOSQL
            CREATE USER ${POSTGRESQL_REPLICATION_USER} WITH REPLICATION ENCRYPTED PASSWORD '${POSTGRESQL_REPLICATION_PASSWORD}';
EOSQL
        echo "Replication user created successfully"
    else
        echo "Replication user already exists"
    fi
    
    # Create replication slot if it doesn't exist
    echo "Checking for replication slot..."
    if ! psql -U postgres -tAc "SELECT 1 FROM pg_replication_slots WHERE slot_name='replica_0_slot'" | grep -q 1; then
        echo "Creating replication slot: replica_0_slot"
        psql -U postgres -c "SELECT pg_create_physical_replication_slot('replica_0_slot');"
        echo "Replication slot created successfully"
    else
        echo "Replication slot already exists"
    fi
    
    echo "=== Primary node configuration completed successfully ==="
else
    echo "=== Replica node already configured ==="
fi 