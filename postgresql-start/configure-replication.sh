#!/bin/bash
set -e

echo "Starting replication configuration..."

# Default values for unset variables
IS_PRIMARY=${IS_PRIMARY:-false}
POSTGRESQL_REPLICATION_USER=${POSTGRESQL_REPLICATION_USER:-replicator}

echo "Running as primary: ${IS_PRIMARY}"

if [ "${IS_PRIMARY}" = "true" ]; then
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
    if ! psql -U postgres -tAc "SELECT 1 FROM pg_replication_slots WHERE slot_name='replica_1_slot'" | grep -q 1; then
        echo "Creating replication slot: replica_1_slot"
        psql -U postgres -c "SELECT pg_create_physical_replication_slot('replica_1_slot');"
        echo "Replication slot created successfully"
    else
        echo "Replication slot already exists"
    fi
    
    echo "=== Primary node configuration completed successfully ==="
else
    echo "Configuring replica node..."

    if [ ! -f "${PGDATA}/standby.signal" ]; then
        echo "No standby.signal found, performing initial backup..."
        
        # Stop PostgreSQL if running
        pg_ctl -D ${PGDATA} stop || true
        
        # Backup existing data directory if it exists
        if [ -d "${PGDATA}" ]; then
            mv ${PGDATA} ${PGDATA}.bak.$(date +%Y%m%d_%H%M%S)
        fi
        
        # Create fresh directory
        mkdir -p ${PGDATA}
        
        # Create password file for pg_basebackup
        export PGPASSFILE=$(mktemp)
        echo "${POSTGRESQL_PRIMARY_HOST}:5432:*:${POSTGRESQL_REPLICATION_USER}:${POSTGRESQL_REPLICATION_PASSWORD}" > "$PGPASSFILE"
        chmod 600 "$PGPASSFILE"
        
        # Perform base backup
        pg_basebackup -h ${POSTGRESQL_PRIMARY_HOST} \
                     -D ${PGDATA} \
                     -U ${POSTGRESQL_REPLICATION_USER} \
                     -P -v -R \
                     -X stream \
                     -S replica_1_slot
        
        # Clean up password file
        rm -f "$PGPASSFILE"
    fi

    # Configure streaming replication
    echo "Configuring streaming replication..."
    cat >> "${PGDATA}/postgresql.auto.conf" << EOF
primary_conninfo = 'host=${POSTGRESQL_PRIMARY_HOST} port=5432 user=${POSTGRESQL_REPLICATION_USER} password=${POSTGRESQL_REPLICATION_PASSWORD} application_name=replica_1'
primary_slot_name = 'replica_1_slot'
EOF
    echo "Streaming replication configured"
    
    # Create standby signal file if it doesn't exist
    if [ ! -f "${PGDATA}/standby.signal" ]; then
        echo "Creating standby.signal file..."
        touch "${PGDATA}/standby.signal"
    fi
    
    echo "=== Replica configuration completed successfully ==="
fi 