#!/bin/bash

. /etc/init.d/atl-functions

trap 'atl_error ${LINENO}' ERR

ATL_FACTORY_CONFIG=/etc/sysconfig/atl
ATL_USER_CONFIG=/etc/atl

[[ -r "${ATL_FACTORY_CONFIG}" ]] && . "${ATL_FACTORY_CONFIG}"
[[ -r "${ATL_USER_CONFIG}" ]] && . "${ATL_USER_CONFIG}"

if [[ "x${ATL_BITBUCKET_VERSION}" == "xlatest" ]]; then
    ATL_BITBUCKET_INSTALLER="atlassian-${ATL_BITBUCKET_NAME}-linux-x64.bin"
else
    ATL_BITBUCKET_INSTALLER="atlassian-${ATL_BITBUCKET_NAME}-${ATL_BITBUCKET_VERSION}-linux-x64.bin"
fi
ATL_BITBUCKET_INSTALLER_S3_PATH="${ATL_RELEASE_S3_PATH}/${ATL_BITBUCKET_NAME}/${ATL_BITBUCKET_VERSION}/${ATL_BITBUCKET_INSTALLER}"
ATL_BITBUCKET_INSTALLER_DOWNLOAD_URL="${ATL_BITBUCKET_INSTALLER_DOWNLOAD_URL:-"https://s3.amazonaws.com/${ATL_RELEASE_S3_BUCKET}/${ATL_BITBUCKET_INSTALLER_S3_PATH}"}"

ATL_LOG=${ATL_LOG:?"The Atlassian log location must be supplied in ${ATL_FACTORY_CONFIG}"}
ATL_APP_DATA_MOUNT=${ATL_APP_DATA_MOUNT:?"The application data mount name must be supplied in ${ATL_FACTORY_CONFIG}"}
ATL_INSTANCE_STORE_MOUNT=${ATL_INSTANCE_STORE_MOUNT:?"The instance store mount must be supplied in ${ATL_FACTORY_CONFIG}"}
ATL_HOST_NAME=$(atl_hostName)
ATL_FORCE_HOST_NAME=${ATL_FORCE_HOST_NAME:-"false"}

ATL_BITBUCKET_NAME=${ATL_BITBUCKET_NAME:?"The Bitbucket name must be supplied in ${ATL_FACTORY_CONFIG}"}
ATL_BITBUCKET_SHORT_DISPLAY_NAME=${ATL_BITBUCKET_SHORT_DISPLAY_NAME:?"The ${ATL_BITBUCKET_NAME} short display name must be supplied in ${ATL_FACTORY_CONFIG}"}
ATL_BITBUCKET_FULL_DISPLAY_NAME=${ATL_BITBUCKET_FULL_DISPLAY_NAME:?"The ${ATL_BITBUCKET_SHORT_DISPLAY_NAME} short display name must be supplied in ${ATL_FACTORY_CONFIG}"}
ATL_BITBUCKET_VERSION=${ATL_BITBUCKET_VERSION:?"The ${ATL_BITBUCKET_SHORT_DISPLAY_NAME} version must be supplied in ${ATL_FACTORY_CONFIG}"}
ATL_BITBUCKET_USER=${ATL_BITBUCKET_USER:?"The ${ATL_BITBUCKET_SHORT_DISPLAY_NAME} user account must be supplied in ${ATL_FACTORY_CONFIG}"}
ATL_BITBUCKET_DB_NAME=${ATL_BITBUCKET_DB_NAME:?"The ${ATL_BITBUCKET_SHORT_DISPLAY_NAME} db name must be supplied in ${ATL_FACTORY_CONFIG}"}
ATL_BITBUCKET_DB_USER=${ATL_BITBUCKET_DB_USER:?"The ${ATL_BITBUCKET_SHORT_DISPLAY_NAME} db user must be supplied in ${ATL_FACTORY_CONFIG}"}
ATL_BITBUCKET_INSTALL_DIR=${ATL_BITBUCKET_INSTALL_DIR:?"The ${ATL_BITBUCKET_SHORT_DISPLAY_NAME} install dir must be supplied in ${ATL_FACTORY_CONFIG}"}
ATL_BITBUCKET_INSTALLER_DOWNLOAD_URL=${ATL_BITBUCKET_INSTALLER_DOWNLOAD_URL:?"The ${ATL_BITBUCKET_SHORT_DISPLAY_NAME} installer download URL must be supplied in ${ATL_FACTORY_CONFIG}"}
ATL_BITBUCKET_HOME=${ATL_BITBUCKET_HOME:?"The ${ATL_BITBUCKET_SHORT_DISPLAY_NAME} home dir must be supplied in ${ATL_FACTORY_CONFIG}"}
if [[ "xtrue" == "x$(atl_toLowerCase ${ATL_NGINX_ENABLED})" ]]; then
    ATL_BITBUCKET_NGINX_PATH=${ATL_BITBUCKET_NGINX_PATH:?"The ${ATL_BITBUCKET_SHORT_DISPLAY_NAME} home dir must be supplied in ${ATL_FACTORY_CONFIG}"}
fi
ATL_BITBUCKET_BUNDLED_ELASTICSEARCH_ENABLED=${ATL_BITBUCKET_BUNDLED_ELASTICSEARCH_ENABLED:-true}
ATL_BITBUCKET_SHARED_HOME="${ATL_BITBUCKET_HOME}/shared"
ATL_BITBUCKET_SERVICE_NAME="atlbitbucket"

function start {
    atl_log "=== BEGIN: service atl-init-bitbucket start ==="
    atl_log "Initialising ${ATL_BITBUCKET_FULL_DISPLAY_NAME}"

    createBitbucketHome
    if [[ "x${ATL_POSTGRES_ENABLED}" == "xtrue" ]]; then
        createBitbucketDbAndRole
    elif [[ -n "${ATL_DB_NAME}" ]]; then
        configureRemoteDb
    fi

    appendBitbucketProperties "${ATL_BITBUCKET_PROPERTIES}"

    appendBitbucketProperties "
plugin.search.elasticsearch.aws.region=${PLUGIN_SEARCH_ELASTICSEARCH_AWS_REGION}
"

    appendBitbucketProperties "
hazelcast.network.aws=${HAZELCAST_NETWORK_AWS}
hazelcast.network.aws.iam.role=${HAZELCAST_NETWORK_AWS_IAM_ROLE}
hazelcast.network.aws.region=${HAZELCAST_NETWORK_AWS_REGION}
hazelcast.network.aws.tag.key=${HAZELCAST_NETWORK_AWS_TAG_KEY}
hazelcast.network.aws.tag.value=${HAZELCAST_NETWORK_AWS_TAG_VALUE}
hazelcast.network.multicast=${HAZELCAST_NETWORK_MULTICAST}
hazelcast.group.name=${HAZELCAST_GROUP_NAME}
hazelcast.group.password=${HAZELCAST_GROUP_PASSWORD}
"

    installBitbucket
    startBitbucket

    atl_log "=== END:   service atl-init-bitbucket start ==="
}

function appendBitbucketProperties {
    local PROP_PATH="${ATL_BITBUCKET_SHARED_HOME}/${ATL_BITBUCKET_NAME}.properties"
    if [ ! -f "${PROP_PATH}" ]; then
        su "${ATL_BITBUCKET_USER}" -c "touch \"${PROP_PATH}\"" >> "${ATL_LOG}" 2>&1
    fi
    local EDIT_PATH="${PROP_PATH}.tmp"
    set -C
    if  >"${EDIT_PATH}"; then
        atl_log "Initialising config properties ${ATL_BITBUCKET_FULL_DISPLAY_NAME}"    
        declare -a PROP_ARR
        readarray -t PROP_ARR <<<"$1"
        su "${ATL_BITBUCKET_USER}" -c "cp -f \"${PROP_PATH}\" \"${EDIT_PATH}\"" >> "${ATL_LOG}" 2>&1
        for prop in "${PROP_ARR[@]}"
        do
            addOrReplaceProperty "${prop}" "${EDIT_PATH}"
        done
        su "${ATL_BITBUCKET_USER}" -c "mv -f \"${EDIT_PATH}\" \"${PROP_PATH}\"" >> "${ATL_LOG}" 2>&1
        su "${ATL_BITBUCKET_USER}" -c "chmod -f 600 \"${PROP_PATH}\"" >> "${ATL_LOG}" 2>&1
        
        atl_log "Done initialising config properties ${ATL_BITBUCKET_FULL_DISPLAY_NAME}"        
    else
        atl_log "Not initialising ${PROP_PATH}, a file ${PROP_PATH}.tmp already exists."
    fi
    set +C
}

function add_bitbucket_user {
    atl_log "Making sure that the user ${ATL_BITBUCKET_USER} exists."
    getent passwd ${ATL_BITBUCKET_USER} > /dev/null 2&>1

    if [ $? -eq 0 ]; then
        if [ $(id -u ${ATL_BITBUCKET_USER}) == ${ATL_BITBUCKET_UID} ]; then
            atl_log "User already exists not, skipping creation."
            return
        else
            atl_log "User already exists, fixing UID."
            userdel ${ATL_BITBUCKET_USER}
        fi
    else
        atl_log "User does not exists, adding."
    fi
    groupadd --gid ${ATL_BITBUCKET_UID} ${ATL_BITBUCKET_USER}
    useradd -m --uid ${ATL_BITBUCKET_UID} -g ${ATL_BITBUCKET_USER} ${ATL_BITBUCKET_USER}
    chown -R ${ATL_BITBUCKET_USER}:${ATL_BITBUCKET_USER} /home/${ATL_BITBUCKET_USER}

}

function addOrReplaceProperty {
    local PROP="${1}"
    local EDIT_PATH="${2}"
    local PROP_KEY="${PROP%%=*}"
    if egrep -q "^(# )?${PROP_KEY}[= \t]" "${EDIT_PATH}"; then
        if egrep -q "^${PROP_KEY}=" "${EDIT_PATH}"; then
            su "${ATL_BITBUCKET_USER}" -c "sed -i \"/^${PROP_KEY}=.*$/d\" ${EDIT_PATH}" >> "${ATL_LOG}" 2>&1
            su "${ATL_BITBUCKET_USER}" -c "echo \"${PROP}\" >> ${EDIT_PATH}" >> "${ATL_LOG}" 2>&1
        elif ! egrep -q "# ${PROP_KEY}" "${PROP_PATH}"; then
            su "${ATL_BITBUCKET_USER}" -c "echo \"${PROP}\" >> ${EDIT_PATH}" >> "${ATL_LOG}" 2>&1
        fi
    else
        su "${ATL_BITBUCKET_USER}" -c "echo \"${PROP}\" >> ${EDIT_PATH}" >> "${ATL_LOG}" 2>&1
    fi
}

function createInstanceStoreDirs {
    atl_log "=== BEGIN: service atl-init-bitbucket create-instance-store-dirs ==="
    atl_log "Initialising ${ATL_BITBUCKET_FULL_DISPLAY_NAME}"

    local BITBUCKET_DIR=${1:?"The instance store directory for ${ATL_BITBUCKET_NAME} must be supplied"}

    if [[ ! -e "${BITBUCKET_DIR}" ]]; then
        atl_log "Creating ${BITBUCKET_DIR}"
        mkdir -p "${BITBUCKET_DIR}" >> "${ATL_LOG}" 2>&1
    else
        atl_log "Not creating ${BITBUCKET_DIR} because it already exists"
    fi
    atl_log "Creating ${BITBUCKET_DIR}/caches"
    mkdir -p "${BITBUCKET_DIR}/caches" >> "${ATL_LOG}" 2>&1
    atl_log "Creating ${BITBUCKET_DIR}/tmp"
    mkdir -p "${BITBUCKET_DIR}/tmp" >> "${ATL_LOG}" 2>&1

    atl_log "Changing ownership of the contents of ${BITBUCKET_DIR} to ${ATL_BITBUCKET_USER}"
    chown -R "${ATL_BITBUCKET_USER}":"${ATL_BITBUCKET_USER}" "${BITBUCKET_DIR}"

    atl_log "=== END:   service atl-init-bitbucket create-instance-store-dirs ==="
}

function createBitbucketHome {
    atl_log "Creating ${ATL_BITBUCKET_HOME}"
    mkdir -p "${ATL_BITBUCKET_HOME}" >> "${ATL_LOG}" 2>&1
    mkdir -p "${ATL_APP_DATA_MOUNT}/${ATL_BITBUCKET_NAME}" >> "${ATL_LOG}" 2>&1
    chown "${ATL_BITBUCKET_USER}":"${ATL_BITBUCKET_USER}" "${ATL_BITBUCKET_HOME}" >> "${ATL_LOG}" 2>&1
    chown -R "${ATL_BITBUCKET_USER}":"${ATL_BITBUCKET_USER}" "${ATL_APP_DATA_MOUNT}/${ATL_BITBUCKET_NAME}" >> "${ATL_LOG}" 2>&1

    if mountpoint -q "${ATL_APP_DATA_MOUNT}" || mountpoint -q "${ATL_APP_DATA_MOUNT}/${ATL_BITBUCKET_NAME}/shared"; then
        atl_log "Linking ${ATL_BITBUCKET_SHARED_HOME} to ${ATL_APP_DATA_MOUNT}/${ATL_BITBUCKET_NAME}/shared"
        su "${ATL_BITBUCKET_USER}" -c "ln -s \"${ATL_APP_DATA_MOUNT}/${ATL_BITBUCKET_NAME}/shared\" \"${ATL_BITBUCKET_SHARED_HOME}\"" >> "${ATL_LOG}" 2>&1
    else
        atl_log "Creating ${ATL_BITBUCKET_SHARED_HOME}"
        su "${ATL_BITBUCKET_USER}" -c "mkdir -p \"${ATL_BITBUCKET_SHARED_HOME}\"" >> "${ATL_LOG}" 2>&1
    fi

    if [[ -d "${ATL_INSTANCE_STORE_MOUNT}/${ATL_BITBUCKET_NAME}/caches" && $(( $(atl_freeSpace "${ATL_INSTANCE_STORE_MOUNT}") > 10485760 )) ]]; then
        atl_log "Linking ${ATL_BITBUCKET_HOME}/caches to ${ATL_INSTANCE_STORE_MOUNT}/${ATL_BITBUCKET_NAME}/caches"
        su "${ATL_BITBUCKET_USER}" -c "ln -s \"${ATL_INSTANCE_STORE_MOUNT}/${ATL_BITBUCKET_NAME}/caches\" \"${ATL_BITBUCKET_HOME}/caches\"" >> "${ATL_LOG}" 2>&1
    else
        atl_log "Creating ${ATL_BITBUCKET_HOME}/caches because ${ATL_INSTANCE_STORE_MOUNT}/${ATL_BITBUCKET_NAME}/caches does not exist or has insufficient free space"
        su "${ATL_BITBUCKET_USER}" -c "mkdir -p \"${ATL_BITBUCKET_HOME}/caches\"" >> "${ATL_LOG}" 2>&1
    fi

    if [[ -d "${ATL_INSTANCE_STORE_MOUNT}/${ATL_BITBUCKET_NAME}/tmp" ]]; then
        atl_log "Linking ${ATL_BITBUCKET_HOME}/tmp to ${ATL_INSTANCE_STORE_MOUNT}/${ATL_BITBUCKET_NAME}/tmp"
        su "${ATL_BITBUCKET_USER}" -c "ln -s \"${ATL_INSTANCE_STORE_MOUNT}/${ATL_BITBUCKET_NAME}/tmp\" \"${ATL_BITBUCKET_HOME}/tmp\"" >> "${ATL_LOG}" 2>&1
    else
        atl_log "Creating ${ATL_BITBUCKET_HOME}/tmp because ${ATL_INSTANCE_STORE_MOUNT}/${ATL_BITBUCKET_NAME}/tmp does not exist"
        su "${ATL_BITBUCKET_USER}" -c "mkdir -p \"${ATL_BITBUCKET_HOME}/tmp\"" >> "${ATL_LOG}" 2>&1
    fi
}

function configureDbProperties {
    atl_log "Configuring ${ATL_BITBUCKET_SHORT_DISPLAY_NAME} DB settings"
    local JDBC_PROPS="jdbc.driver=${1}\n"
    JDBC_PROPS+="jdbc.url=${2}\n"
    JDBC_PROPS+="jdbc.user=${3}\n"
    JDBC_PROPS+="jdbc.passworgit stad=${4}\n"
    # Command substitution will strip trailing newlines, so we need to include it after the assignment
    ATL_BITBUCKET_PROPERTIES="$(echo -e ${JDBC_PROPS})
${ATL_BITBUCKET_PROPERTIES}"
    atl_log "Done configuring ${ATL_BITBUCKET_SHORT_DISPLAY_NAME} to use the ${ATL_BITBUCKET_SHORT_DISPLAY_NAME} DB role ${ATL_BITBUCKET_DB_USER}"
}

function createBitbucketDbAndRole {
    if atl_roleExists ${ATL_BITBUCKET_DB_USER}; then
        atl_log "${ATL_BITBUCKET_DB_USER} role already exists. Skipping database and role creation."
    else
        local PASSWORD=$(cat /proc/sys/kernel/random/uuid)

        atl_createRole "${ATL_BITBUCKET_SHORT_DISPLAY_NAME}" "${ATL_BITBUCKET_DB_USER}" "${PASSWORD}"
        atl_createDb "${ATL_BITBUCKET_SHORT_DISPLAY_NAME}" "${ATL_BITBUCKET_DB_NAME}" "${ATL_BITBUCKET_DB_USER}"
        configureDbProperties "org.postgresql.Driver" "jdbc:postgresql://localhost/${ATL_BITBUCKET_DB_NAME}" "${ATL_BITBUCKET_DB_USER}" "${PASSWORD}"
    fi
}

function configureRemoteDb {
    atl_log "Configuring remote DB for use with ${ATL_BITBUCKET_SHORT_DISPLAY_NAME}"

    if [[ -n "${ATL_DB_PASSWORD}" ]]; then
        atl_configureDbPassword "${ATL_DB_PASSWORD}" "*" "${ATL_DB_HOST}" "${ATL_DB_PORT}"
        if atl_roleExists ${ATL_JDBC_USER} ${ATL_DB_NAME} ${ATL_DB_HOST} ${ATL_DB_PORT}; then
            atl_log "${ATL_BITBUCKET_DB_USER} role already exists. Skipping role creation."
        else
            atl_createRole "${ATL_BITBUCKET_SHORT_DISPLAY_NAME}" "${ATL_JDBC_USER}" "${ATL_JDBC_PASSWORD}" "${ATL_DB_HOST}" "${ATL_DB_PORT}"
            atl_createRemoteDb "${ATL_BITBUCKET_SHORT_DISPLAY_NAME}" "${ATL_DB_NAME}" "${ATL_JDBC_USER}" "${ATL_DB_HOST}" "${ATL_DB_PORT}" "C" "C" "template0"
        fi
    fi
    configureDbProperties "${ATL_JDBC_DRIVER}" "${ATL_JDBC_URL}" "${ATL_JDBC_USER}" "${ATL_JDBC_PASSWORD}"
}

function configureNginx {
    updateHostName "${ATL_HOST_NAME}" "${ATL_FORCE_HOST_NAME}"
    atl_addNginxProductMapping "${ATL_BITBUCKET_NGINX_PATH}" 7990
}

function installBitbucket {
    atl_log "Checking if ${ATL_BITBUCKET_SHORT_DISPLAY_NAME} has already been installed"
    if [[ -d "${ATL_BITBUCKET_INSTALL_DIR}" ]]; then
        local ERROR_MESSAGE="${ATL_BITBUCKET_SHORT_DISPLAY_NAME} install directory ${ATL_BITBUCKET_INSTALL_DIR} already exists - aborting installation"
        atl_log "${ERROR_MESSAGE}"
        atl_fatal_error "${ERROR_MESSAGE}"
    fi

    atl_log "Downloading ${ATL_BITBUCKET_SHORT_DISPLAY_NAME} ${ATL_BITBUCKET_VERSION} from ${ATL_BITBUCKET_INSTALLER_DOWNLOAD_URL}"
    if ! curl -L -f --silent "${ATL_BITBUCKET_INSTALLER_DOWNLOAD_URL}" -o "$(atl_tempDir)/installer" >> "${ATL_LOG}" 2>&1
    then
        local ERROR_MESSAGE="Could not download installer from ${ATL_BITBUCKET_INSTALLER_DOWNLOAD_URL} - aborting installation"
        atl_log "${ERROR_MESSAGE}"
        atl_fatal_error "${ERROR_MESSAGE}"
    fi
    chmod +x "$(atl_tempDir)/installer" >> "${ATL_LOG}" 2>&1
    cat <<EOT >> "$(atl_tempDir)/installer.varfile"
app.install.service\$Boolean=true
app.service.account=${ATL_BITBUCKET_USER}
portChoice=defaults
app.bitbucketHome=${ATL_BITBUCKET_HOME}
app.defaultInstallDir=${ATL_BITBUCKET_INSTALL_DIR}
launch.application\$Boolean=false
executeLauncherAction\$Boolean=false
elasticsearch.install.service\$Boolean=${ATL_BITBUCKET_BUNDLED_ELASTICSEARCH_ENABLED}
confirm.disable.plugins\$Boolean=true
container.configuration.ignore\$Boolean=true
EOT

    cp $(atl_tempDir)/installer.varfile /tmp/installer.varfile.bkp

    atl_log "Installing ${ATL_BITBUCKET_SHORT_DISPLAY_NAME} to ${ATL_BITBUCKET_INSTALL_DIR}"
    "$(atl_tempDir)/installer" -q -varfile "$(atl_tempDir)/installer.varfile" >> "${ATL_LOG}" 2>&1
    atl_log "Installed ${ATL_BITBUCKET_SHORT_DISPLAY_NAME} to ${ATL_BITBUCKET_INSTALL_DIR}"

    add_bitbucket_user

    for folder in ${ATL_BITBUCKET_INSTALL_DIR} ${ATL_BITBUCKET_HOME} ${ATL_BITBUCKET_SHARED_HOME} ; do
        atl_log "Making Sure that bitbucket is using the proper user in ${folder}"
        chown -R "${ATL_BITBUCKET_USER}":"${ATL_BITBUCKET_UID}" "${folder}"
    done

    sed -i -e "s/BITBUCKET_USER=.*/BITBUCKET_USER=${ATL_BITBUCKET_USER}/g" "${ATL_BITBUCKET_INSTALL_DIR}/bin/set-bitbucket-user.sh"

    atl_log "Cleaning up"
    rm -rf "$(atl_tempDir)"/installer* >> "${ATL_LOG}" 2>&1

    if [[ "xtrue" == "x$(atl_toLowerCase ${ATL_NGINX_ENABLED})" ]]; then
        configureNginx
    elif [[ -n "${ATL_PROXY_NAME}" ]]; then
        updateHostName "${ATL_PROXY_NAME}" "${ATL_FORCE_HOST_NAME}"
    fi

    atl_log "Creating dependency between atl-init-20-instance-store and ${ATL_BITBUCKET_SERVICE_NAME} services"
    sed -i "s/Required-Start:/Required-Start:    atl-init-20-instance-store postgresql%%POSTGRES_SHORT_VERSION%%/g" "/etc/init.d/${ATL_BITBUCKET_SERVICE_NAME}" >> "${ATL_LOG}" 2>&1
    chkconfig "${ATL_BITBUCKET_SERVICE_NAME}" reset >> "${ATL_LOG}" 2>&1
    atl_log "Done creating dependency between atl-init-20-instance-store and ${ATL_BITBUCKET_SERVICE_NAME} services"

    atl_log "${ATL_BITBUCKET_SHORT_DISPLAY_NAME} installation completed"
}

function isSpringBoot {
    if [ "latest" = "${ATL_BITBUCKET_VERSION}" ]; then
        return 0
    fi
    declare -a semver
    IFS='.'; read -ra semver <<< "${ATL_BITBUCKET_VERSION}"
    if [[ ${semver[0]} -ge 5 ]]; then
        # 0 = true
        return 0
    else
        # non-0 = false
        return 1
    fi
}

function startBitbucket {
    if ! isSpringBoot; then
        if [[ "x${ATL_BITBUCKET_BUNDLED_ELASTICSEARCH_ENABLED}" == "xtrue" ]]; then
            atl_log "Starting ${ATL_BITBUCKET_SHORT_DISPLAY_NAME} Search service"
            service "${ATL_BITBUCKET_SERVICE_NAME}_search" start >> "${ATL_LOG}" 2>&1 || echo "${ATL_BITBUCKET_SERVICE_NAME}_search failed to start" >> ${ATL_LOG}
        fi
    fi
    atl_log "Starting ${ATL_BITBUCKET_SHORT_DISPLAY_NAME} service"
    service "${ATL_BITBUCKET_SERVICE_NAME}" start >> "${ATL_LOG}" 2>&1
}

function configureSpringBootConnector {
    local hostname="$1" 
    local secure=false
    local scheme=http
    local proxyPort=80
    local additionalConnector=""
    if [[ "xtrue" == "x$(atl_toLowerCase ${ATL_SSL_SELF_CERT_ENABLED})" || "xtrue" == "x$(atl_toLowerCase ${ATL_SSL_PROXY})" ]]; then
        secure=true
        scheme=https
        proxyPort=443
        additionalConnector="server.additional-connector.1.port=7991"
    fi

    appendBitbucketProperties "
server.proxy-port=${proxyPort}
server.proxy-name=${hostname}
server.scheme=${scheme}
server.secure=${secure}
server.require-ssl=${secure}
${additionalConnector}
"
}

function updateHostName {   
    if isSpringBoot; then
            configureSpringBootConnector "${1}"
    else
        atl_configureTomcatConnector "${1}" "7990" "7991" "${ATL_BITBUCKET_USER}" \
            "${ATL_APP_DATA_MOUNT}/${ATL_BITBUCKET_NAME}/shared" \
            "${ATL_BITBUCKET_INSTALL_DIR}/atlassian-bitbucket/WEB-INF" \
            "${2}"
    fi

    STATUS="$(service "${ATL_BITBUCKET_SERVICE_NAME}" status || true)"
    if [[ "${STATUS}" =~ .*\ is\ running ]]; then
        atl_log "Restarting ${ATL_BITBUCKET_SHORT_DISPLAY_NAME} to pick up host name change"
        service "${ATL_BITBUCKET_SERVICE_NAME}" restart >> "${ATL_LOG}" 2>&1
    fi
}

case "$1" in
    start)
        $1
        ;;
    create-instance-store-dirs)
        createInstanceStoreDirs $2
        ;;
    update-host-name)
        updateHostName $2 "true"
        ;;
    stop)
        ;;
    *)
        echo "Usage: $0 {start|init-instance-store-dirs|update-host-name}"
        RETVAL=1
esac
exit ${RETVAL}
