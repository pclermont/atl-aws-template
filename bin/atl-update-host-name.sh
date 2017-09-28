#!/bin/bash
set -e

. /etc/init.d/atl-functions

ATL_FACTORY_CONFIG=/etc/sysconfig/atl
ATL_USER_CONFIG=/etc/atl

[[ -r "${ATL_FACTORY_CONFIG}" ]] && . "${ATL_FACTORY_CONFIG}"
[[ -r "${ATL_USER_CONFIG}" ]] && . "${ATL_USER_CONFIG}"

function usage {
    cat << EOF
usage: sudo $0 <new host name>

This script updates references to the ec2 instance's host name. It must be run as root or via sudo.
If <new host name> is omitted, it defaults to $(atl_hostName).

EOF
}

if [[ "root" != "$(whoami)" ]]; then
    usage
    exit 1
fi

HOST_NAME="$1"
case ${HOST_NAME} in
"")
    HOST_NAME=$(atl_hostName)
    echo "Using ${HOST_NAME} as default host name"
    ;;
-*)
    usage
    exit 1
    ;;
esac

atl_setNginxHostName "${HOST_NAME}"

for product in $(atl_enabled_products); do
    LOWER_CASE_PRODUCT="$(atl_toLowerCase ${product})"
    service atl-init-${LOWER_CASE_PRODUCT} update-host-name "$HOST_NAME"
done

service nginx reload

echo "Done"



