#!/bin/bash
### BEGIN INIT INFO
# Provides:          atl-init-10-volume
# Required-Start:    cloud-final
# Required-Stop:
# X-Start-Before:    atl-init-30-db atl-init-40-products
# Default-Start:     2 3 4 5
# Default-Stop:
# Short-Description: Ensures the Atlassian application data volume has been formatted and mounted.
# Description:       Ensures the Atlassian application data volume has been formatted and mounted.
### END INIT INFO

set -e

. /etc/init.d/atl-functions

trap 'atl_error ${LINENO}' ERR

ATL_FACTORY_CONFIG=/etc/sysconfig/atl
ATL_USER_CONFIG=/etc/atl

[[ -r "${ATL_FACTORY_CONFIG}" ]] && . "${ATL_FACTORY_CONFIG}"
[[ -r "${ATL_USER_CONFIG}" ]] && . "${ATL_USER_CONFIG}"

ATL_LOG=${ATL_LOG:?"The Atlassian log location must be supplied in ${ATL_FACTORY_CONFIG}"}
ATL_APP_DATA_MOUNT=${ATL_APP_DATA_MOUNT:?"The application data mount must be supplied in ${ATL_FACTORY_CONFIG}"}

function start {
    atl_log "=== BEGIN: service atl-init-10-volume start ==="

    disableThisService

    initSharedHomes

    atl_log "=== END:   service atl-init-10-volume start ==="
}

function disableThisService {
    atl_log "Disabling atl-init-10-volume for future boots"
    chkconfig "atl-init-10-volume" off >> "${ATL_LOG}" 2>&1
    atl_log "Done disabling atl-init-10-volume for future boots"
}

function initSharedHomes {
    for product in $(atl_enabled_shared_homes); do
        local LOWER_CASE_PRODUCT="$(atl_toLowerCase ${product})"
        local UPPER_CASE_PRODUCT="$(atl_toUpperCase ${product})"
        local USER_VAR="ATL_${UPPER_CASE_PRODUCT}_USER"
        local USER="${!USER_VAR}"
        local CONFIG_PROPERTIES_VAR="ATL_${UPPER_CASE_PRODUCT}_PROPERTIES"
        local CONFIG_PROPERTIES="${!CONFIG_PROPERTIES_VAR}"

        atl_log "Creating ${ATL_APP_DATA_MOUNT}/${LOWER_CASE_PRODUCT}"
        mkdir -p "${ATL_APP_DATA_MOUNT}/${LOWER_CASE_PRODUCT}" >> "${ATL_LOG}" 2>&1
        chown ${USER}:${USER} "${ATL_APP_DATA_MOUNT}/${LOWER_CASE_PRODUCT}" >> "${ATL_LOG}" 2>&1

        atl_log "Creating ${ATL_APP_DATA_MOUNT}/${LOWER_CASE_PRODUCT}/shared"
        mkdir -p "${ATL_APP_DATA_MOUNT}/${LOWER_CASE_PRODUCT}/shared" >> "${ATL_LOG}" 2>&1
        chown ${USER}:${USER} "${ATL_APP_DATA_MOUNT}/${LOWER_CASE_PRODUCT}/shared" >> "${ATL_LOG}" 2>&1

        if [[ -f "${CONFIG_PROPERTIES}" ]]; then
            local CONFIG_PROPERTIES_FILENAME="$(basename "${CONFIG_PROPERTIES}")"
            local DEST_CONFIG_PROPERTIES="${ATL_APP_DATA_MOUNT}/${LOWER_CASE_PRODUCT}/shared/${CONFIG_PROPERTIES_FILENAME}"
            atl_log "Appending ${CONFIG_PROPERTIES} to ${DEST_CONFIG_PROPERTIES}"
            su ${USER} -c "cat \"${CONFIG_PROPERTIES}\" >> \"${DEST_CONFIG_PROPERTIES}\"" >> "${ATL_LOG}" 2>&1
            rm -f "${CONFIG_PROPERTIES}" >> "${ATL_LOG}" 2>&1
        fi
    done
}


case "$1" in
    start)
        $1
        ;;
    stop)
        ;;
    *)
        echo "Usage: $0 {start}"
        exit 1
esac
