#!/bin/bash
set -e

echo "Starting pre-start configuration..."

# Default values for unset variables
IS_PRIMARY=${IS_PRIMARY:-false}
POSTGRESQL_REPLICATION_USER=${POSTGRESQL_REPLICATION_USER:-replicator}
POSTGRESQL_PRIMARY_HOST=${POSTGRESQL_PRIMARY_HOST:-}

echo "Running as primary: ${IS_PRIMARY}"

if [ "${IS_PRIMARY}" = "false" ]; then
    echo "=== Preparing replica node ==="
    
    if [ -z "${POSTGRESQL_PRIMARY_HOST}" ]; then
        echo "ERROR: POSTGRESQL_PRIMARY_HOST is not set!"
        exit 1
    fi
    
    echo "Primary host: ${POSTGRESQL_PRIMARY_HOST}"
    echo "Replication user: ${POSTGRESQL_REPLICATION_USER}"

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
    
    # Perform base backup without -R since S2I will restart anyway
    pg_basebackup -h ${POSTGRESQL_PRIMARY_HOST} \
                 -D ${PGDATA} \
                 -U ${POSTGRESQL_REPLICATION_USER} \
                 -P -v \
                 -X stream \
                 -S replica_1_slot
    
    # Clean up password file
    rm -f "$PGPASSFILE"

    # Configure streaming replication
    echo "Configuring streaming replication..."
    cat >> "${PGDATA}/postgresql.auto.conf" << EOF
primary_conninfo = 'host=${POSTGRESQL_PRIMARY_HOST} port=5432 user=${POSTGRESQL_REPLICATION_USER} password=${POSTGRESQL_REPLICATION_PASSWORD} application_name=replica_1'
primary_slot_name = 'replica_1_slot'
EOF
    
    # Create standby signal file
    echo "Creating standby.signal file..."
    touch "${PGDATA}/standby.signal"
    
    echo "=== Replica preparation completed successfully ==="
else
    echo "Running as primary node, skipping replica preparation"
fi 