#!/bin/bash
### BEGIN INIT INFO
# Provides:          atl-init-20-instance-store
# Required-Start:    cloud-final
# Required-Stop:
# Default-Start:     2 3 4 5
# Default-Stop:
# Short-Description: Ensures "bitbucket" dir is present on the instance store mount as configured in (/etc/sysconfig/atl)
# Description:       Ensures "bitbucket" dir is present on the instance store mount as configured in (/etc/sysconfig/atl).
#                    Configures the ${SERVICE_NAME} which ensures the "bitbucket" dir is present at the instance store mount. This directory is
#                    used for file operations that benefit from fast IO but which need not be persisted between instance start/stops.
### END INIT INFO

set -e

. /etc/init.d/atl-functions

trap 'atl_error ${LINENO}' ERR

ATL_FACTORY_CONFIG=/etc/sysconfig/atl
ATL_USER_CONFIG=/etc/atl

[[ -r "${ATL_FACTORY_CONFIG}" ]] && . "${ATL_FACTORY_CONFIG}"
[[ -r "${ATL_USER_CONFIG}" ]] && . "${ATL_USER_CONFIG}"

ATL_LOG=${ATL_LOG:?"The Atlassian log location must be supplied in ${ATL_FACTORY_CONFIG}"}
ATL_ENABLED_PRODUCTS=${ATL_ENABLED_PRODUCTS:?"The enabled Atlassian products must be supplied in ${ATL_FACTORY_CONFIG}"}
ATL_INSTANCE_STORE_MOUNT=${ATL_INSTANCE_STORE_MOUNT:?"The instance store mount must be supplied in ${ATL_FACTORY_CONFIG}"}

function start {
    atl_log "=== BEGIN: service atl-init-20-instance-store start ==="
    atl_log "Initialising instance store"

    if [[ -n "${ATL_INSTANCE_STORE_MOUNT}" && -w "${ATL_INSTANCE_STORE_MOUNT}" ]]; then


        for product in $(atl_enabled_products); do
            local LOWER_CASE_PRODUCT="$(atl_toLowerCase ${product})"
            local UPPER_CASE_PRODUCT="$(atl_toUpperCase ${product})"
            local SENTENCE_CASE_PRODUCT="$(atl_toSentenceCase ${product})"

            if [[ ! -e "${ATL_INSTANCE_STORE_MOUNT}/${LOWER_CASE_PRODUCT}" ]]; then
                if [[ "xfunction" == "x$(type -t create${SENTENCE_CASE_PRODUCT}InstanceStoreDirs)" ]]; then
                    atl_log "Creating instance store directories for enabled product \"${SENTENCE_CASE_PRODUCT}\""
                    create${SENTENCE_CASE_PRODUCT}InstanceStoreDirs "${ATL_INSTANCE_STORE_MOUNT}/${LOWER_CASE_PRODUCT}"
                else
                    atl_log "Not creating instance store directories for enabled product \"${SENTENCE_CASE_PRODUCT}\" because no initialisation has been defined"
                fi
            else
                atl_log "Not creating ${ATL_INSTANCE_STORE_MOUNT}/${LOWER_CASE_PRODUCT} because it already exists"
            fi
        done
    else
        atl_log "The instance store mount ${ATL_INSTANCE_STORE_MOUNT} does not exist - not creating product directories"
    fi

    atl_log "=== END:   service atl-init-20-instance-store start ==="
}


case "$1" in
    start)
        $1
        ;;
    stop)
        ;;
    *)
        echo $"Usage: $0 {start}"
        exit 1
esac

