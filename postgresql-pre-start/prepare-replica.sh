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

    # Extract ordinal from replica pod hostname (last dash-separated field)
    ORDINAL=$(echo "$HOSTNAME" | awk -F'-' '{print $NF}')
    SLOT_NAME="replica_${ORDINAL}_slot"
    APP_NAME="replica_${ORDINAL}"

    if [ -z "${POSTGRESQL_PRIMARY_HOST}" ]; then
        echo "ERROR: POSTGRESQL_PRIMARY_HOST is not set!"
        exit 1
    fi

    echo "Primary host: ${POSTGRESQL_PRIMARY_HOST}"
    echo "Replication user: ${POSTGRESQL_REPLICATION_USER}"
    echo "Using replication slot: ${SLOT_NAME}"
    echo "Application name: ${APP_NAME}"

    # Remove existing data directory if it exists
    if [ -d "${PGDATA}" ]; then
        echo "Removing existing data directory..."
        rm -rf "${PGDATA}"
    fi

    # Create password file for pg_basebackup
    echo "Creating temporary password file..."
    export PGPASSFILE=$(mktemp)
    echo "${POSTGRESQL_PRIMARY_HOST}:5432:*:${POSTGRESQL_REPLICATION_USER}:${POSTGRESQL_REPLICATION_PASSWORD}" > "$PGPASSFILE"
    chmod 600 "$PGPASSFILE"

    # Ensure replication slot exists on primary
    echo "Ensuring replication slot ${SLOT_NAME} exists on primary..."
    PGPASSWORD="${POSTGRESQL_REPLICATION_PASSWORD}" psql \
        -h ${POSTGRESQL_PRIMARY_HOST} \
        -U ${POSTGRESQL_REPLICATION_USER} \
        -d postgres \
        -c "SELECT pg_create_physical_replication_slot('${SLOT_NAME}');" \
        || echo "Slot ${SLOT_NAME} may already exist, continuing..."

    # Create fresh directory and perform base backup
    echo "Creating fresh PGDATA directory..."
    mkdir -p "${PGDATA}"

    echo "Starting base backup from primary..."
    pg_basebackup -h "${POSTGRESQL_PRIMARY_HOST}" \
                  -D "${PGDATA}" \
                  -U "${POSTGRESQL_REPLICATION_USER}" \
                  -P -v -R \
                  -X stream \
                  -S "${SLOT_NAME}"

    # Clean up password file
    rm -f "$PGPASSFILE"
    
    # Configure streaming replication
    echo "Configuring streaming replication..."
    cat >> "${PGDATA}/postgresql.auto.conf" << EOF
primary_conninfo = 'host=${POSTGRESQL_PRIMARY_HOST} port=5432 user=${POSTGRESQL_REPLICATION_USER} password=${POSTGRESQL_REPLICATION_PASSWORD} application_name=${APP_NAME}'
primary_slot_name = '${SLOT_NAME}'
EOF
    echo "Streaming replication configured"

    # Create standby signal file
    echo "Creating standby.signal file..."
    touch "${PGDATA}/standby.signal"
    
    # Set permissions
    echo "Setting directory permissions..."
    chmod 700 "${PGDATA}"

    echo "=== Replica preparation completed successfully ==="
else
    if [ "${IS_PRIMARY}" = "true" ]; then
        echo "Running as primary node, skipping replica preparation"
    else
        echo "Standby signal file exists, skipping replica preparation"
    fi
fi