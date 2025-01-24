#!/bin/bash
set -e

# Log function for consistent formatting
log() {
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] $1"
}

# Function to configure primary node
configure_primary() {
    log "=== Configuring primary node ==="
    
    # Configure pg_hba.conf for replication
    log "Configuring pg_hba.conf..."
    sed -i '/^host[[:space:]]*replication/d' "${PGDATA}/pg_hba.conf"
    echo "host replication ${POSTGRESQL_REPLICATION_USER} all scram-sha-256" >> "${PGDATA}/pg_hba.conf"
    chmod 600 "${PGDATA}/pg_hba.conf"
    
    # Create replication user
    log "Setting up replication user..."
    if ! psql -U postgres -tAc "SELECT 1 FROM pg_roles WHERE rolname='${POSTGRESQL_REPLICATION_USER}'" | grep -q 1; then
        psql -U postgres -c "CREATE USER ${POSTGRESQL_REPLICATION_USER} WITH REPLICATION ENCRYPTED PASSWORD '${POSTGRESQL_REPLICATION_PASSWORD}';"
    fi
    
    # Create replication slot
    log "Setting up replication slot..."
    if ! psql -U postgres -tAc "SELECT 1 FROM pg_replication_slots WHERE slot_name='replica_1_slot'" | grep -q 1; then
        psql -U postgres -c "SELECT pg_create_physical_replication_slot('replica_1_slot');"
    fi
    
    log "Primary configuration completed"
}

# Function to configure replica node
configure_replica() {
    log "=== Configuring replica node ==="
    
    # Get primary's system identifier
    PRIMARY_SYSTEM_ID=$(psql -h ${POSTGRESQL_PRIMARY_HOST} -U ${POSTGRESQL_REPLICATION_USER} -d postgres -tAc "SELECT system_identifier FROM pg_control_system()")
    log "Primary system identifier: ${PRIMARY_SYSTEM_ID}"
    
    # Set up replication configuration
    touch "${PGDATA}/standby.signal"
    cat > "${PGDATA}/postgresql.auto.conf" << EOF
primary_conninfo = 'host=${POSTGRESQL_PRIMARY_HOST} port=5432 user=${POSTGRESQL_REPLICATION_USER} password=${POSTGRESQL_REPLICATION_PASSWORD} application_name=replica_1'
primary_slot_name = 'replica_1_slot'
system_identifier = '${PRIMARY_SYSTEM_ID}'
EOF
    
    log "Replica configuration completed"
}

# Main execution
log "Starting replication configuration..."

# Set default values
IS_PRIMARY=${IS_PRIMARY:-false}
POSTGRESQL_REPLICATION_USER=${POSTGRESQL_REPLICATION_USER:-replicator}

# Validate configuration
if [ "${IS_PRIMARY}" = "false" ] && [ -z "${POSTGRESQL_PRIMARY_HOST}" ]; then
    log "ERROR: POSTGRESQL_PRIMARY_HOST is required for replica setup"
    exit 1
fi

if [ -z "${POSTGRESQL_REPLICATION_PASSWORD}" ]; then
    log "ERROR: POSTGRESQL_REPLICATION_PASSWORD is required"
    exit 1
fi

# Configure based on node type
if [ "${IS_PRIMARY}" = "true" ]; then
    configure_primary
else
    configure_replica
fi

log "Configuration completed successfully" 