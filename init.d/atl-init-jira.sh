#!/bin/bash

# set -e

. /etc/init.d/atl-functions

trap 'atl_error ${LINENO}' ERR

ATL_FACTORY_CONFIG=/etc/sysconfig/atl
ATL_USER_CONFIG=/etc/atl

[[ -r "${ATL_FACTORY_CONFIG}" ]] && . "${ATL_FACTORY_CONFIG}"
[[ -r "${ATL_USER_CONFIG}" ]] && . "${ATL_USER_CONFIG}"


ATL_LOG=${ATL_LOG:?"The Atlassian log location must be supplied in ${ATL_FACTORY_CONFIG}"}
ATL_APP_DATA_MOUNT=${ATL_APP_DATA_MOUNT:?"The application data mount name must be supplied in ${ATL_FACTORY_CONFIG}"}
ATL_INSTANCE_STORE_MOUNT=${ATL_INSTANCE_STORE_MOUNT:?"The instance store mount must be supplied in ${ATL_FACTORY_CONFIG}"}
ATL_HOST_NAME=$(atl_hostName)

ATL_JIRA_NAME=${ATL_JIRA_NAME:?"The JIRA name must be supplied in ${ATL_FACTORY_CONFIG}"}
ATL_JIRA_SHORT_DISPLAY_NAME=${ATL_JIRA_SHORT_DISPLAY_NAME:?"The ${ATL_JIRA_NAME} short display name must be supplied in ${ATL_FACTORY_CONFIG}"}
ATL_JIRA_FULL_DISPLAY_NAME=${ATL_JIRA_FULL_DISPLAY_NAME:?"The ${ATL_JIRA_SHORT_DISPLAY_NAME} short display name must be supplied in ${ATL_FACTORY_CONFIG}"}
ATL_JIRA_DB_NAME=${ATL_DB_NAME:?"The ${ATL_JIRA_SHORT_DISPLAY_NAME} db name must be supplied in ${ATL_FACTORY_CONFIG}"}
ATL_JIRA_DB_USER=${ATL_DB_USER:?"The ${ATL_JIRA_SHORT_DISPLAY_NAME} db user must be supplied in ${ATL_FACTORY_CONFIG}"}
ATL_JIRA_INSTALL_DIR=${ATL_JIRA_INSTALL_DIR:?"The ${ATL_JIRA_SHORT_DISPLAY_NAME} install dir must be supplied in ${ATL_FACTORY_CONFIG}"}
ATL_JIRA_HOME=${ATL_JIRA_HOME:?"The ${ATL_JIRA_SHORT_DISPLAY_NAME} home dir must be supplied in ${ATL_FACTORY_CONFIG}"}
ATL_JIRA_SHARED_HOME="${ATL_JIRA_HOME}/shared"
ATL_JIRA_SERVICE_NAME="jira"
ATL_JIRA_VERSION=${ATL_JIRA_VERSION:?"The ${ATL_JIRA_SHORT_DISPLAY_NAME} version must be supplied in ${ATL_FACTORY_CONFIG}"}
ATL_JIRA_USER=${ATL_JIRA_USER:?"The ${ATL_JIRA_SHORT_DISPLAY_NAME} user must be supplied in ${ATL_FACTORY_CONFIG}"}
ATL_JIRA_UID="400"

ATL_JIRA_RELEASES_S3_URL="https://s3.amazonaws.com/${ATL_RELEASE_S3_BUCKET}/${ATL_RELEASE_S3_PATH}/${ATL_JIRA_NAME}"

function start {
    atl_log "=== BEGIN: service atl-init-jira start ==="
    atl_log "Initialising ${ATL_JIRA_FULL_DISPLAY_NAME}"

    installJIRA

    if [[ -n "${ATL_PROXY_NAME}" ]]; then
        updateHostName "${ATL_PROXY_NAME}"
    fi

    configureJIRAHome
    if [[ -n "${ATL_DB_NAME}" ]]; then
        configureRemoteDb
    fi

    goJIRA

    atl_log "=== END:   service atl-init-jira start ==="
}

function add_jira_user {
    atl_log "Making sure that the user ${ATL_JIRA_USER} exists."
    getent passwd ${ATL_JIRA_USER} > /dev/null 2&>1

    if [ $? -eq 0 ]; then
        atl_log "User already exists not, skipping creation."
    else
        atl_log "User does not exists, adding."
        useradd -m --uid ${ATL_JIRA_UID} -g ${ATL_JIRA_USER} ${ATL_JIRA_USER}
    fi
}

function createInstanceStoreDirs {
    atl_log "=== BEGIN: service atl-init-jira create-instance-store-dirs ==="
    atl_log "Initialising ${ATL_JIRA_FULL_DISPLAY_NAME}"

    local JIRA_DIR=${1:?"The instance store directory for ${ATL_JIRA_NAME} must be supplied"}

    if [[ ! -e "${JIRA_DIR}" ]]; then
        atl_log "Creating ${JIRA_DIR}"
        mkdir -p "${JIRA_DIR}" >> "${ATL_LOG}" 2>&1
    else
        atl_log "Not creating ${JIRA_DIR} because it already exists"
    fi
    atl_log "Creating ${JIRA_DIR}/caches"
    mkdir -p "${JIRA_DIR}/caches" >> "${ATL_LOG}" 2>&1
    atl_log "Creating ${JIRA_DIR}/tmp"
    mkdir -p "${JIRA_DIR}/tmp" >> "${ATL_LOG}" 2>&1

    atl_log "=== END:   service atl-init-jira create-instance-store-dirs ==="
}

function ownMount {
    if mountpoint -q "${ATL_APP_DATA_MOUNT}" || mountpoint -q "${ATL_APP_DATA_MOUNT}/${ATL_JIRA_SERVICE_NAME}"; then
        atl_log "Setting ownership of ${ATL_APP_DATA_MOUNT}/${ATL_JIRA_SERVICE_NAME} to '${ATL_JIRA_USER}' user"
        mkdir -p "${ATL_APP_DATA_MOUNT}/${ATL_JIRA_SERVICE_NAME}"
        chown -R "${ATL_JIRA_USER}":"${ATL_JIRA_USER}" "${ATL_APP_DATA_MOUNT}/${ATL_JIRA_SERVICE_NAME}"
    fi
}

function linkAppData {
    local LINK_DIR_NAME=${1:?"The name of the directory to link must be supplied"}
    if mountpoint -q "${ATL_APP_DATA_MOUNT}" || mountpoint -q "${ATL_APP_DATA_MOUNT}/${ATL_JIRA_SERVICE_NAME}/${LINK_DIR_NAME}"; then
        atl_log "Linking ${ATL_JIRA_HOME}/${LINK_DIR_NAME} to ${ATL_APP_DATA_MOUNT}/${ATL_JIRA_SERVICE_NAME}/${LINK_DIR_NAME}"
        su "${ATL_JIRA_USER}" -c "mkdir -p \"${ATL_APP_DATA_MOUNT}/${ATL_JIRA_SERVICE_NAME}/${LINK_DIR_NAME}\""
        su "${ATL_JIRA_USER}" -c "ln -s \"${ATL_APP_DATA_MOUNT}/${ATL_JIRA_SERVICE_NAME}/${LINK_DIR_NAME}\" \"${ATL_JIRA_HOME}/${LINK_DIR_NAME}\"" >> "${ATL_LOG}" 2>&1
    fi
}

function initInstanceData {
    local LINK_DIR_NAME=${1:?"The name of the directory to mount must be supplied"}
    local INSTANCE_DIR="${ATL_INSTANCE_STORE_MOUNT}/${ATL_JIRA_SERVICE_NAME}/${LINK_DIR_NAME}"
    if [[ -d "${INSTANCE_DIR}" && $(( $(atl_freeSpace "${ATL_INSTANCE_STORE_MOUNT}") > 10485760 )) ]]; then
        atl_log "Linking ${ATL_JIRA_HOME}/${LINK_DIR_NAME} to ${INSTANCE_DIR}"
        su "${ATL_JIRA_USER}" -c "ln -s \"${INSTANCE_DIR}\" \"${ATL_JIRA_HOME}/${LINK_DIR_NAME}\"" >> "${ATL_LOG}" 2>&1
    fi
}

function configureSharedHome {
    local JIRA_SHARED="${ATL_APP_DATA_MOUNT}/${ATL_JIRA_SERVICE_NAME}/shared"
    if mountpoint -q "${ATL_APP_DATA_MOUNT}" || mountpoint -q "${JIRA_SHARED}"; then
        mkdir -p "${JIRA_SHARED}"
        chown -R -H "${ATL_JIRA_USER}":"${ATL_JIRA_USER}" "${JIRA_SHARED}" >> "${ATL_LOG}" 2>&1 
        cat <<EOT | su "${ATL_JIRA_USER}" -c "tee -a \"${ATL_JIRA_HOME}/cluster.properties\"" > /dev/null
jira.node.id = $(curl -f --silent http://169.254.169.254/latest/meta-data/instance-id)
jira.shared.home = ${JIRA_SHARED}
EOT
    else
        atl_log "No mountpoint for shared home exists. Failed to create cluster.properties file."
    fi
}

function configureJIRAHome {
    atl_log "Configuring ${ATL_JIRA_HOME}"
    mkdir -p "${ATL_JIRA_HOME}" >> "${ATL_LOG}" 2>&1

    configureSharedHome

    initInstanceData "caches"
    initInstanceData "tmp"

    atl_log "Setting ownership of ${ATL_JIRA_HOME} to '${ATL_JIRA_USER}' user"
    chown -R -H "${ATL_JIRA_USER}":"${ATL_JIRA_USER}" "${ATL_JIRA_HOME}" >> "${ATL_LOG}" 2>&1 
    atl_log "Done configuring ${ATL_JIRA_HOME}"
}

function configureDbProperties {
    atl_log "Configuring ${ATL_JIRA_SHORT_DISPLAY_NAME} DB settings"
    cat <<EOT | su "${ATL_JIRA_USER}" -c "tee -a \"${ATL_JIRA_HOME}/dbconfig.xml\"" > /dev/null
<?xml version="1.0" encoding="UTF-8"?>

<jira-database-config>
  <name>defaultDS</name>
  <delegator-name>default</delegator-name>
  <database-type>postgres72</database-type>
  <schema-name>public</schema-name>
  <jdbc-datasource>
    <url>$2</url>
    <driver-class>$1</driver-class>
    <username>$3</username>
    <password>$4</password>
    <pool-min-size>20</pool-min-size>
    <pool-max-size>20</pool-max-size>
    <pool-max-wait>30000</pool-max-wait>
    <validation-query>select 1</validation-query>
    <min-evictable-idle-time-millis>60000</min-evictable-idle-time-millis>
    <time-between-eviction-runs-millis>300000</time-between-eviction-runs-millis>
    <pool-max-idle>20</pool-max-idle>
    <pool-remove-abandoned>true</pool-remove-abandoned>
    <pool-remove-abandoned-timeout>300</pool-remove-abandoned-timeout>
    <pool-test-on-borrow>false</pool-test-on-borrow>
    <pool-test-while-idle>true</pool-test-while-idle>
  </jdbc-datasource>
</jira-database-config>
EOT
    su "${ATL_JIRA_USER}" -c "chmod 600 \"${ATL_JIRA_HOME}/dbconfig.xml\"" >> "${ATL_LOG}" 2>&1
    atl_log "Done configuring ${ATL_JIRA_SHORT_DISPLAY_NAME} to use the ${ATL_JIRA_SHORT_DISPLAY_NAME} DB role ${ATL_JIRA_DB_USER}"
}

function configureRemoteDb {
    atl_log "Configuring remote DB for use with ${ATL_JIRA_SHORT_DISPLAY_NAME}"

    if [[ -n "${ATL_DB_PASSWORD}" ]]; then
        atl_configureDbPassword "${ATL_DB_PASSWORD}" "*" "${ATL_DB_HOST}" "${ATL_DB_PORT}"
        
        if atl_roleExists ${ATL_JDBC_USER} "postgres" ${ATL_DB_HOST} ${ATL_DB_PORT}; then
            atl_log "${ATL_JDBC_USER} role already exists. Skipping role creation."
        else
            atl_createRole "${ATL_JIRA_SHORT_DISPLAY_NAME}" "${ATL_JDBC_USER}" "${ATL_JDBC_PASSWORD}" "${ATL_DB_HOST}" "${ATL_DB_PORT}"
            atl_createRemoteDb "${ATL_JIRA_SHORT_DISPLAY_NAME}" "${ATL_DB_NAME}" "${ATL_JDBC_USER}" "${ATL_DB_HOST}" "${ATL_DB_PORT}" "C" "C" "template0"
        fi

        configureDbProperties "${ATL_JDBC_DRIVER}" "${ATL_JDBC_URL}" "${ATL_JDBC_USER}" "${ATL_JDBC_PASSWORD}"
    fi
}

function preserveInstaller {
    local ATL_LOG_HEADER="[preserveInstaller]:"

    local JIRA_VERSION=$(cat $(atl_tempDir)/version)
    local JIRA_INSTALLER="atlassian-${ATL_JIRA_NAME}-${JIRA_VERSION}-x64.bin"

    atl_log "${ATL_LOG_HEADER} preserving ${ATL_JIRA_SHORT_DISPLAY_NAME} installer ${JIRA_INSTALLER} and metadata"
    cp $(atl_tempDir)/installer $ATL_APP_DATA_MOUNT/$JIRA_INSTALLER
    cp $(atl_tempDir)/version $ATL_APP_DATA_MOUNT/$ATL_JIRA_NAME.version
    atl_log "${ATL_LOG_HEADER} ${ATL_JIRA_SHORT_DISPLAY_NAME} installer ${JIRA_INSTALLER} and metadata has been preserved"
}

function restoreInstaller {
    local ATL_LOG_HEADER="[restoreInstaller]:"

    local JIRA_VERSION=$(cat $ATL_APP_DATA_MOUNT/$ATL_JIRA_NAME.version)
    local JIRA_INSTALLER="atlassian-${ATL_JIRA_NAME}-${JIRA_VERSION}-x64.bin"
    atl_log "${ATL_LOG_HEADER} Using existing installer ${JIRA_INSTALLER} from ${ATL_APP_DATA_MOUNT} mount"

    atl_log "${ATL_LOG_HEADER} Ready to restore ${ATL_JIRA_SHORT_DISPLAY_NAME} installer ${JIRA_INSTALLER}"

    if [[ -f $ATL_APP_DATA_MOUNT/$JIRA_INSTALLER ]]; then
        cp $ATL_APP_DATA_MOUNT/$JIRA_INSTALLER $(atl_tempDir)/installer
    else
        local msg="${ATL_LOG_HEADER} ${ATL_JIRA_SHORT_DISPLAY_NAME} installer $JIRA_INSTALLER has been requested, but unable to locate it in shared mount directory"
        atl_log "${msg}" 
        atl_fatal_error "${msg}"
    fi

    atl_log "${ATL_LOG_HEADER} Restoration of ${ATL_JIRA_SHORT_DISPLAY_NAME} installer ${JIRA_INSTALLER} completed"
}

function downloadInstaller {
    local ATL_LOG_HEADER="[downloadInstaller]: "

    echo ${ATL_JIRA_VERSION} > "$(atl_tempDir)/version"


    local JIRA_VERSION=$(cat $(atl_tempDir)/version)
    local JIRA_INSTALLER="atlassian-${ATL_JIRA_NAME}-${JIRA_VERSION}-x64.bin"
    local JIRA_INSTALLER_URL="${ATL_JIRA_RELEASES_S3_URL}/${JIRA_INSTALLER}"

    atl_log "${ATL_LOG_HEADER} Downloading ${ATL_JIRA_SHORT_DISPLAY_NAME} installer ${JIRA_INSTALLER} from ${ATL_JIRA_RELEASES_S3_URL}"
    if ! curl -L -f --silent "${JIRA_INSTALLER_URL}" \
        -o "$(atl_tempDir)/installer" >> "${ATL_LOG}" 2>&1
    then
        local ERROR_MESSAGE="Could not download ${ATL_JIRA_SHORT_DISPLAY_NAME} installer from  - aborting installation"
        atl_log "${ATL_LOG_HEADER} ${ERROR_MESSAGE}"
        atl_fatal_error "${ERROR_MESSAGE}"
    fi
}

function prepareInstaller {
    local ATL_LOG_HEADER="[prepareInstaller]: "
    atl_log "${ATL_LOG_HEADER} Preparing an installer"

    atl_log "${ATL_LOG_HEADER} Checking if installer has been downloaded already"
    if [[ -f $ATL_APP_DATA_MOUNT/$ATL_JIRA_NAME.version ]]; then
        restoreInstaller
    else
        downloadInstaller
        preserveInstaller
    fi

    chmod +x "$(atl_tempDir)/installer" >> "${ATL_LOG}" 2>&1

    atl_log "${ATL_LOG_HEADER} Preparing installer configuration"

    cat <<EOT >> "$(atl_tempDir)/installer.varfile"
launch.application\$Boolean=false
rmiPort\$Long=8005
app.jiraHome=${ATL_JIRA_HOME}
app.install.service\$Boolean=true
existingInstallationDir=${ATL_JIRA_INSTALL_DIR}
sys.confirmedUpdateInstallationString=false
sys.languageId=en
sys.installationDir=${ATL_JIRA_INSTALL_DIR}
executeLauncherAction\$Boolean=true
httpPort\$Long=8080
portChoice=default
executeLauncherAction\$Boolean=false
EOT

    cp $(atl_tempDir)/installer.varfile /tmp/installer.varfile.bkp

    atl_log "${ATL_LOG_HEADER} Installer configuration preparation completed"
}

function installJIRA {
    atl_log "Checking if ${ATL_JIRA_SHORT_DISPLAY_NAME} has already been installed"
    if [[ -d "${ATL_JIRA_INSTALL_DIR}" ]]; then
        local ERROR_MESSAGE="${ATL_JIRA_SHORT_DISPLAY_NAME} install directory ${ATL_JIRA_INSTALL_DIR} already exists - aborting installation"
        atl_log "${ERROR_MESSAGE}"
        atl_fatal_error "${ERROR_MESSAGE}"
    fi
    add_jira_user

    prepareInstaller

    atl_log "Creating ${ATL_JIRA_SHORT_DISPLAY_NAME} install directory"
    mkdir -p "${ATL_JIRA_INSTALL_DIR}"

    atl_log "Installing ${ATL_JIRA_SHORT_DISPLAY_NAME} to ${ATL_JIRA_INSTALL_DIR}"
    "$(atl_tempDir)/installer" -q -varfile "$(atl_tempDir)/installer.varfile" >> "${ATL_LOG}" 2>&1
    atl_log "Installed ${ATL_JIRA_SHORT_DISPLAY_NAME} to ${ATL_JIRA_INSTALL_DIR}"

    atl_log "Cleaning up"
    rm -rf "$(atl_tempDir)"/installer* >> "${ATL_LOG}" 2>&1

    chown -R "${ATL_JIRA_USER}":"${ATL_JIRA_USER}" "${ATL_JIRA_INSTALL_DIR}"
    atl_log "Making Sure that Jira is using the proper user"
    sed -i -e "s/JIRA_USER=.*/JIRA_USER=${ATL_JIRA_USER}/g" ${ATL_JIRA_INSTALL_DIR}/bin/user.sh

    atl_log "${ATL_JIRA_SHORT_DISPLAY_NAME} installation completed"
}

function noJIRA {
    atl_log "Stopping ${ATL_JIRA_SERVICE_NAME} service"
    service "${ATL_JIRA_SERVICE_NAME}" stop >> "${ATL_LOG}" 2>&1
}

function goJIRA {
    atl_log "Starting ${ATL_JIRA_SERVICE_NAME} service"
    service "${ATL_JIRA_SERVICE_NAME}" start >> "${ATL_LOG}" 2>&1
}

function updateHostName {
    atl_configureTomcatConnector "${1}" "8080" "8081" "${ATL_JIRA_USER}" \
        "${ATL_JIRA_INSTALL_DIR}/conf" \
        "${ATL_JIRA_INSTALL_DIR}/atlassian-jira/WEB-INF"

    STATUS="$(service "${ATL_JIRA_SERVICE_NAME}" status || true)"
    if [[ "${STATUS}" =~ .*\ is\ running ]]; then
        atl_log "Restarting ${ATL_JIRA_SHORT_DISPLAY_NAME} to pick up host name change"
        noJIRA
        goJIRA
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
        updateHostName $2
        ;;
    stop)
        ;;
    *)
        echo "Usage: $0 {start|init-instance-store-dirs|update-host-name}"
        exit 1
esac
