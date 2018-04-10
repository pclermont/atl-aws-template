#!/bin/bash


. /etc/init.d/atl-functions
. /etc/init.d/atl-confluence-common

trap 'atl_error ${LINENO}' ERR

ATL_HAZELCAST_NETWORK_AWS_HOST_HEADER="${ATL_HAZELCAST_NETWORK_AWS_HOST_HEADER:-"ec2.${ATL_HAZELCAST_NETWORK_AWS_IAM_REGION}.amazonaws.com"}"

# We are using ALB so Confluence will startup without Synchrony-Proxy and using Synchrony at port 8091 of LB
function start {
    atl_log "=== BEGIN: service atl-init-confluence start ==="
    atl_log "Initialising ${ATL_CONFLUENCE_FULL_DISPLAY_NAME}"

    installConfluence
    configureJVMMermory
    if [[ "xtrue" == "x$(atl_toLowerCase ${ATL_NGINX_ENABLED})" ]]; then
        configureNginx
    elif [[ -n "${ATL_PROXY_NAME}" ]]; then
        updateHostName "${ATL_PROXY_NAME}"
    fi
    configureConfluenceHome
    exportCatalinaOpts
    configureConfluenceEnvironmentVariables
    if [[ "x${ATL_POSTGRES_ENABLED}" == "xtrue" ]]; then
        createConfluenceDbAndRole
    elif [[ -n "${ATL_DB_NAME}" ]]; then
        configureRemoteDb
    fi

    goCONF

    atl_log "=== END:   service atl-init-confluence start ==="
}

function configureJVMMermory {
    atl_log "Configuring JVM Memory for ${ATL_CONFLUENCE_SHORT_DISPLAY_NAME}"

    sed -i -e "s/\(.*\)-Xms1024m\(.*\)/\1-Xms${ATL_JVM_MINIMUM_MEMORY}\2/g" ${ATL_CONFLUENCE_INSTALL_DIR}/bin/setenv.sh
    sed -i -e "s/\(.*\)-Xmx1024m\(.*\)/\1-Xms${ATL_JVM_MAXIMUM_MEMORY}\2/g" ${ATL_CONFLUENCE_INSTALL_DIR}/bin/setenv.sh

    atl_log "Configuring JVM Memory of ${ATL_CONFLUENCE_SHORT_DISPLAY_NAME} Done."
}

function configureConfluenceEnvironmentVariables (){
   atl_log "=== BEGIN: service configureConfluenceEnvironmentVariables ==="
   cat <<EOT | su "${ATL_CONFLUENCE_USER}" -c "tee -a \"${ATL_CONFLUENCE_INSTALL_DIR}/bin/setenv.sh\"" > /dev/null

CATALINA_OPTS="\${CATALINA_OPTS} -Dsynchrony.service.url=${ATL_SYNCHRONY_SERVICE_URL} -Dsynchrony.proxy.enabled=false ${ATL_CATALINA_OPTS}"
export CATALINA_OPTS
EOT
   atl_log "=== END: service configureConfluenceEnvironmentVariables ==="
}

function createInstanceStoreDirs {
    atl_log "=== BEGIN: service atl-init-confluence create-instance-store-dirs ==="
    atl_log "Initialising ${ATL_CONFLUENCE_FULL_DISPLAY_NAME}"

    local CONFLUENCE_DIR=${1:?"The instance store directory for ${ATL_CONFLUENCE_NAME} must be supplied"}

    if [[ ! -e "${CONFLUENCE_DIR}" ]]; then
        atl_log "Creating ${CONFLUENCE_DIR}"
        mkdir -p "${CONFLUENCE_DIR}" >> "${ATL_LOG}" 2>&1
    else
        atl_log "Not creating ${CONFLUENCE_DIR} because it already exists"
    fi
    atl_log "Creating ${CONFLUENCE_DIR}/caches"
    mkdir -p "${CONFLUENCE_DIR}/caches" >> "${ATL_LOG}" 2>&1
    atl_log "Creating ${CONFLUENCE_DIR}/tmp"
    mkdir -p "${CONFLUENCE_DIR}/tmp" >> "${ATL_LOG}" 2>&1

    atl_log "Changing ownership of the contents of ${CONFLUENCE_DIR} to ${ATL_CONFLUENCE_USER}"
        atl_ChangeFolderOwnership "${ATL_CONFLUENCE_USER}" "${ATL_CONFLUENCE_USER}" "${CONFLUENCE_DIR}"


    atl_log "=== END:   service atl-init-confluence create-instance-store-dirs ==="
}

function configureSharedHome {
    atl_log "=== BEGIN: service atl-init-confluence configureSharedHome ==="
    local CONFLUENCE_SHARED="${ATL_APP_DATA_MOUNT}/${ATL_CONFLUENCE_SERVICE_NAME}/shared-home"
    if mountpoint -q "${ATL_APP_DATA_MOUNT}" || mountpoint -q "${CONFLUENCE_SHARED}"; then
        atl_log "Linking ${CONFLUENCE_SHARED} to ${ATL_CONFLUENCE_SHARED_HOME}"
        mkdir -p "${CONFLUENCE_SHARED}"
        atl_ChangeFolderOwnership "${ATL_CONFLUENCE_USER}" "${ATL_CONFLUENCE_USER}" "${CONFLUENCE_SHARED}"
        su "${ATL_CONFLUENCE_USER}" -c "ln -s \"${CONFLUENCE_SHARED}\" \"${ATL_CONFLUENCE_SHARED_HOME}\"" >> "${ATL_LOG}" 2>&1
        if [ "x${ATL_STANDALONE_MODE}" == "xtrue" ] ; then
            rm ${CONFLUENCE_SHARED}/cluster.properties
        fi
    else
        atl_log "No mountpoint for shared home exists. Failed to create cluster.properties file."
    fi
    atl_log "=== END:   service atl-init-confluence configureSharedHome ==="
}

function configureConfluenceHome {
    atl_log "Configuring ${ATL_CONFLUENCE_HOME}"
    mkdir -p "${ATL_CONFLUENCE_HOME}" >> "${ATL_LOG}" 2>&1

    if [[ "x${ATL_CONFLUENCE_DATA_CENTER}" = "xtrue" ]]; then 
        configureSharedHome
    fi
    
    atl_log "Setting ownership of ${ATL_CONFLUENCE_HOME} to '${ATL_CONFLUENCE_USER}' user"
    atl_ChangeFolderOwnership "${ATL_CONFLUENCE_USER}" "${ATL_CONFLUENCE_USER}" "${ATL_CONFLUENCE_HOME}"
    atl_log "Done configuring ${ATL_CONFLUENCE_HOME}"
}

function configureDbProperties {
    atl_log "Configuring ${ATL_CONFLUENCE_SHORT_DISPLAY_NAME} DB settings"
    local PRODUCT_CONFIG_NAME="confluence"
    local CONFLUENCE_SETUP_STEP="setupstart"
    local CONFLUENCE_SETUP_TYPE="custom"
    local CONFLUENCE_BUILD_NUMBER="0"
    cat <<EOT | su "${ATL_CONFLUENCE_USER}" -c "tee -a \"${ATL_CONFLUENCE_HOME}/confluence.cfg.xml\"" > /dev/null
<?xml version="1.0" encoding="UTF-8"?>

<${PRODUCT_CONFIG_NAME}-configuration>
  <setupStep>${CONFLUENCE_SETUP_STEP}</setupStep>
  <setupType>${CONFLUENCE_SETUP_TYPE}</setupType>
  <buildNumber>${CONFLUENCE_BUILD_NUMBER}</buildNumber>
  <properties>
    <property name="confluence.database.choice">postgresql</property>
    <property name="confluence.database.connection.type">database-type-standard</property>
    <property name="hibernate.connection.driver_class">${ATL_JDBC_DRIVER}</property>
    <property name="hibernate.connection.url">${ATL_JDBC_URL}</property>
    <property name="hibernate.connection.password">${ATL_JDBC_PASSWORD}</property>
    <property name="hibernate.connection.username">${ATL_JDBC_USER}</property>
    <property name="hibernate.dialect">com.atlassian.confluence.impl.hibernate.dialect.PostgreSQLDialect</property>
    <property name="webwork.multipart.saveDir">\${localHome}/temp</property>
    <property name="attachments.dir">\${confluenceHome}/attachments</property>
EOT

    if [[ "x${ATL_CONFLUENCE_DATA_CENTER}" = "xtrue" ]]; then
        cat <<EOT | su "${ATL_CONFLUENCE_USER}" -c "tee -a \"${ATL_CONFLUENCE_HOME}/confluence.cfg.xml\"" > /dev/null
    <property name="shared-home">${ATL_CONFLUENCE_SHARED_HOME}</property>
    <property name="confluence.cluster.home">${ATL_CONFLUENCE_SHARED_HOME}</property>
    <property name="confluence.cluster.aws.iam.role">${ATL_HAZELCAST_NETWORK_AWS_IAM_ROLE}</property>
    <property name="confluence.cluster.aws.region">${ATL_HAZELCAST_NETWORK_AWS_IAM_REGION}</property>
    <property name="confluence.cluster.aws.host.header">${ATL_HAZELCAST_NETWORK_AWS_HOST_HEADER}</property>
    <property name="confluence.cluster.aws.tag.key">${ATL_HAZELCAST_NETWORK_AWS_TAG_KEY}</property>
    <property name="confluence.cluster.aws.tag.value">${ATL_HAZELCAST_NETWORK_AWS_TAG_VALUE}</property>
    <property name="confluence.cluster.join.type">aws</property>
    <property name="confluence.cluster.name">${ATL_AWS_STACK_NAME}</property>
    <property name="confluence.cluster.ttl">1</property>
EOT
    fi
    appendExternalConfigs
     cat <<EOT | su "${ATL_CONFLUENCE_USER}" -c "tee -a \"${ATL_CONFLUENCE_HOME}/confluence.cfg.xml\"" > /dev/null
  </properties>
</${PRODUCT_CONFIG_NAME}-configuration>
EOT

    su "${ATL_CONFLUENCE_USER}" -c "chmod 600 \"${ATL_CONFLUENCE_HOME}/confluence.cfg.xml\"" >> "${ATL_LOG}" 2>&1
    atl_log "Done configuring ${ATL_CONFLUENCE_SHORT_DISPLAY_NAME} to use the ${ATL_CONFLUENCE_SHORT_DISPLAY_NAME} DB role ${ATL_CONFLUENCE_DB_USER}"
}

function appendExternalConfigs {
    if [[ -n "${ATL_CONFLUENCE_PROPERTIES}" ]]; then
        declare -a PROP_ARR
        readarray -t PROP_ARR <<<"${ATL_CONFLUENCE_PROPERTIES}"
        for prop in PROP_ARR; do
            su "${ATL_CONFLUENCE_USER}" -c "echo \"${prop}\" >> "${ATL_CONFLUENCE_HOME}/confluence.cfg.xml\" >> "${ATL_LOG}" 2>&1
        done
    fi
}

function createConfluenceDbAndRole {
    if atl_roleExists ${ATL_CONFLUENCE_DB_USER}; then
        atl_log "${ATL_CONFLUENCE_DB_USER} role already exists. Skipping database and role creation. Skipping dbconfig.xml update"
    else
        local PASSWORD=$(cat /proc/sys/kernel/random/uuid)

        atl_createRole "${ATL_CONFLUENCE_SHORT_DISPLAY_NAME}" "${ATL_CONFLUENCE_DB_USER}" "${PASSWORD}"
        atl_createDb "${ATL_CONFLUENCE_SHORT_DISPLAY_NAME}" "${ATL_CONFLUENCE_DB_NAME}" "${ATL_CONFLUENCE_DB_USER}"
        configureDbProperties "org.postgresql.Driver" "jdbc:postgresql://localhost/${ATL_CONFLUENCE_DB_NAME}" "${ATL_CONFLUENCE_DB_USER}" "${PASSWORD}"
    fi
}

function configureRemoteDb {
    atl_log "Configuring remote DB for use with ${ATL_CONFLUENCE_SHORT_DISPLAY_NAME}"

    if [[ -n "${ATL_DB_PASSWORD}" ]]; then
        atl_configureDbPassword "${ATL_DB_PASSWORD}" "*" "${ATL_DB_HOST}" "${ATL_DB_PORT}"
        
        if atl_roleExists ${ATL_JDBC_USER} "postgres" ${ATL_DB_HOST} ${ATL_DB_PORT}; then
            atl_log "${ATL_JDBC_USER} role already exists. Skipping role creation."
        else
            atl_createRole "${ATL_CONFLUENCE_SHORT_DISPLAY_NAME}" "${ATL_JDBC_USER}" "${ATL_JDBC_PASSWORD}" "${ATL_DB_HOST}" "${ATL_DB_PORT}"
            atl_createRemoteDb "${ATL_CONFLUENCE_SHORT_DISPLAY_NAME}" "${ATL_DB_NAME}" "${ATL_JDBC_USER}" "${ATL_DB_HOST}" "${ATL_DB_PORT}" "C" "C" "template0"
        fi

        configureDbProperties "${ATL_JDBC_DRIVER}" "${ATL_JDBC_URL}" "${ATL_JDBC_USER}" "${ATL_JDBC_PASSWORD}"
    fi
}

function configureNginx {
    updateHostName "${ATL_HOST_NAME}"
    atl_addNginxProductMapping "${ATL_CONFLUENCE_NGINX_PATH}" 8080
}

function add_confluence_user {
    atl_log "Making sure that the user ${ATL_CONFLUENCE_USER} exists."
    getent passwd ${ATL_CONFLUENCE_USER} > /dev/null 2&>1

    if [ $? -eq 0 ]; then
        if [ $(id -u ${ATL_CONFLUENCE_USER}) == ${ATL_CONFLUENCE_UID} ]; then
            atl_log "User already exists, skipping."
            return
        else
            atl_log "User already exists, fixing UID."
            userdel ${ATL_CONFLUENCE_USER}
        fi
    else
        atl_log "User does not exists, adding."
    fi
    groupadd --gid ${ATL_CONFLUENCE_UID} ${ATL_CONFLUENCE_USER}
    useradd -m --uid ${ATL_CONFLUENCE_UID} -g ${ATL_CONFLUENCE_USER} ${ATL_CONFLUENCE_USER}
    atl_ChangeFolderOwnership "${ATL_CONFLUENCE_USER}" "${ATL_CONFLUENCE_USER}" "/home/${ATL_CONFLUENCE_USER}"


}

function installConfluence {
    atl_log "Checking if ${ATL_CONFLUENCE_SHORT_DISPLAY_NAME} has already been installed"

    atl_log "Creating file /etc/ld.so.conf.d/confluence.conf"
    echo /usr/lib/jvm/jre-1.7.0-openjdk.x86_64/lib/amd64/server/ > /etc/ld.so.conf.d/confluence.conf
    sudo ldconfig
    atl_log "Creating file /etc/ld.so.conf.d/confluence.conf ==> done"

    if [[ -d "${ATL_CONFLUENCE_INSTALL_DIR}" ]]; then
        local ERROR_MESSAGE="${ATL_CONFLUENCE_SHORT_DISPLAY_NAME} install directory ${ATL_CONFLUENCE_INSTALL_DIR} already exists - aborting installation"
        atl_log "${ERROR_MESSAGE}"
        atl_fatal_error "${ERROR_MESSAGE}"
    fi

    atl_log "Downloading ${ATL_CONFLUENCE_SHORT_DISPLAY_NAME} ${ATL_CONFLUENCE_VERSION} from ${ATL_CONFLUENCE_INSTALLER_DOWNLOAD_URL}"
    if ! curl -L -f --silent "${ATL_CONFLUENCE_INSTALLER_DOWNLOAD_URL}" -o "$(atl_tempDir)/installer" >> "${ATL_LOG}" 2>&1
    then
        local ERROR_MESSAGE="Could not download installer from ${ATL_CONFLUENCE_INSTALLER_DOWNLOAD_URL} - aborting installation"
        atl_log "${ERROR_MESSAGE}"
        atl_fatal_error "${ERROR_MESSAGE}"
    fi
    chmod +x "$(atl_tempDir)/installer" >> "${ATL_LOG}" 2>&1
    cat <<EOT >> "$(atl_tempDir)/installer.varfile"
launch.application\$Boolean=false
rmiPort\$Long=8005
app.defaultHome=${ATL_CONFLUENCE_HOME}
app.install.service\$Boolean=true
existingInstallationDir=${ATL_CONFLUENCE_INSTALL_DIR}
sys.confirmedUpdateInstallationString=false
sys.languageId=en
sys.installationDir=${ATL_CONFLUENCE_INSTALL_DIR}
executeLauncherAction\$Boolean=true
httpPort\$Long=8080
portChoice=default
executeLauncherAction\$Boolean=false
EOT

    cp $(atl_tempDir)/installer.varfile /tmp/installer.varfile.bkp

    atl_log "Creating ${ATL_CONFLUENCE_SHORT_DISPLAY_NAME} install directory"
    mkdir -p "${ATL_CONFLUENCE_INSTALL_DIR}"

    atl_log "Installing ${ATL_CONFLUENCE_SHORT_DISPLAY_NAME} to ${ATL_CONFLUENCE_INSTALL_DIR}"
    "$(atl_tempDir)/installer" -q -varfile "$(atl_tempDir)/installer.varfile" >> "${ATL_LOG}" 2>&1
    atl_log "Installed ${ATL_CONFLUENCE_SHORT_DISPLAY_NAME} to ${ATL_CONFLUENCE_INSTALL_DIR}"

    atl_log "Cleaning up"
    rm -rf "$(atl_tempDir)"/installer* >> "${ATL_LOG}" 2>&1

#    if [[ -n "${ATL_SSLKeystore}" ]] ; then
#        atl_fetch_s3_file "${ATL_SSLKeystoreBucket}" "${ATL_SSLKeystore}" "/root/"
#        mv /root/${ATL_SSLKeystore} ${ATL_CONFLUENCE_USER}/.keystore
#        atl_sslKeystore_install "${ATL_CONFLUENCE_INSTALL_DIR}/jre" "confluence" "${ATL_CONFLUENCE_USER}/.keystore" "${ATL_SSLKeystorePassword}"
#    fi

    add_confluence_user

    atl_ChangeFolderOwnership "${ATL_CONFLUENCE_USER}" "${ATL_CONFLUENCE_USER}" "${ATL_CONFLUENCE_HOME}"
    atl_ChangeFolderOwnership "${ATL_CONFLUENCE_USER}" "${ATL_CONFLUENCE_USER}" "${ATL_APP_DATA_MOUNT}/${ATL_CONFLUENCE_SERVICE_NAME}"
    atl_ChangeFolderOwnership "${ATL_CONFLUENCE_USER}" "${ATL_CONFLUENCE_USER}" "${ATL_CONFLUENCE_INSTALL_DIR}"
    atl_ChangeFolderOwnership "${ATL_CONFLUENCE_USER}" "${ATL_CONFLUENCE_USER}" "/opt/atlassian"
    atl_ChangeFolderOwnership "${ATL_CONFLUENCE_USER}" "${ATL_CONFLUENCE_USER}" "/var/atlassian"

    sed -i -e "s/CONF_USER=.*/CONF_USER=${ATL_CONFLUENCE_USER}/g" ${ATL_CONFLUENCE_INSTALL_DIR}/bin/user.sh
    configureJVMMermory
    atl_log "${ATL_CONFLUENCE_SHORT_DISPLAY_NAME} installation completed"
}

function noCONF {
    atl_log "Stopping ${ATL_CONFLUENCE_SERVICE_NAME} service"
    service "${ATL_CONFLUENCE_SERVICE_NAME}" stop >> "${ATL_LOG}" 2>&1
}

function goCONF {
    atl_log "Starting ${ATL_CONFLUENCE_SERVICE_NAME} service"
    service "${ATL_CONFLUENCE_SERVICE_NAME}" start >> "${ATL_LOG}" 2>&1
}

function updateHostName {
    atl_configureTomcatConnector "${1}" "8080" "8081" "${ATL_CONFLUENCE_USER}" \
        "${ATL_CONFLUENCE_INSTALL_DIR}/conf" \
        "${ATL_CONFLUENCE_INSTALL_DIR}/confluence/WEB-INF"

    STATUS="$(service "${ATL_CONFLUENCE_SERVICE_NAME}" status || true)"
    if [[ "${STATUS}" =~ .*\ is\ running ]]; then
        atl_log "Restarting ${ATL_CONFLUENCE_SHORT_DISPLAY_NAME} to pick up host name change"
        noCONF
        goCONF
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
    *)
        echo "Usage: $0 {start|init-instance-store-dirs|update-host-name}"
        RETVAL=1
esac
exit ${RETVAL}

