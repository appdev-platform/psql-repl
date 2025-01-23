#!/bin/bash
set -e

echo "Starting pre-start configuration..."

# Default values for unset variables
IS_PRIMARY=${IS_PRIMARY:-false}
POSTGRESQL_REPLICATION_USER=${POSTGRESQL_REPLICATION_USER:-replicator}
POSTGRESQL_PRIMARY_HOST=${POSTGRESQL_PRIMARY_HOST:-}

echo "Running as primary: ${IS_PRIMARY}"

if [ "${IS_PRIMARY}" = "false" ] && [ ! -f "${PGDATA}/standby.signal" ]; then
    echo "=== Preparing replica node ==="
    
    if [ -z "${POSTGRESQL_PRIMARY_HOST}" ]; then
        echo "ERROR: POSTGRESQL_PRIMARY_HOST is not set!"
        exit 1
    fi
    
    echo "Primary host: ${POSTGRESQL_PRIMARY_HOST}"
    echo "Replication user: ${POSTGRESQL_REPLICATION_USER}"
    
    
    # Configure streaming replication
    echo "Configuring streaming replication..."
    cat >> "${PGDATA}/postgresql.auto.conf" << EOF
primary_conninfo = 'host=${POSTGRESQL_PRIMARY_HOST} port=5432 user=${POSTGRESQL_REPLICATION_USER} password=${POSTGRESQL_REPLICATION_PASSWORD} application_name=replica_1'
primary_slot_name = 'replica_1_slot'
EOF
    echo "Streaming replication configured"
    
    # Create standby signal file
    echo "Creating standby.signal file..."
    touch "${PGDATA}/standby.signal"
    
    
    echo "=== Replica preparation completed successfully ==="
else
    if [ "${IS_PRIMARY}" = "true" ]; then
        echo "Running as primary node, skipping replica preparation"
    else
        echo "Standby signal file exists, skipping replica preparation"
    fi
fi 