#!/bin/bash
### BEGIN INIT INFO
# Provides:          atl-init-40-products
# Required-Start:    atl-init-10-volume atl-init-20-instance-store atl-init-30-db cloud-final
# Required-Stop:
# Default-Start:     2 3 4 5
# Default-Stop:
# Short-Description: Installs the product, configures it
# Description:       Ensures Bitbucket working directories are present
### END INIT INFO

set -e

. /etc/init.d/atl-functions

trap 'atl_error ${LINENO}' ERR

ATL_FACTORY_CONFIG=/etc/sysconfig/atl
ATL_USER_CONFIG=/etc/atl

[[ -r "${ATL_FACTORY_CONFIG}" ]] && . "${ATL_FACTORY_CONFIG}"
[[ -r "${ATL_USER_CONFIG}" ]] && . "${ATL_USER_CONFIG}"

ATL_LOG=${ATL_LOG:?"The Atlassian log location must be supplied in ${ATL_FACTORY_CONFIG}"}
ATL_APP_DATA_MOUNT=${ATL_APP_DATA_MOUNT:?"The application data mount name must be supplied in ${ATL_FACTORY_CONFIG}"}
ATL_INSTANCE_STORE_MOUNT=${ATL_INSTANCE_STORE_MOUNT:?"The instance store mount must be supplied in ${ATL_FACTORY_CONFIG}"}
if [[ "xtrue" == "x$(atl_toLowerCase ${ATL_NGINX_ENABLED})" ]]; then
    if [[ "xtrue" == "x$(atl_toLowerCase ${ATL_SSL_SELF_CERT_ENABLED})" ]]; then
        ATL_SSL_SELF_CERT_COUNTRY=${ATL_SSL_SELF_CERT_COUNTRY:?"The self-signed certificate country must be supplied in ${ATL_FACTORY_CONFIG}"}
        ATL_SSL_SELF_CERT_STATE=${ATL_SSL_SELF_CERT_STATE:?"The self-signed state country must be supplied in ${ATL_FACTORY_CONFIG}"}
        ATL_SSL_SELF_CERT_LOCALE=${ATL_SSL_SELF_CERT_LOCALE:?"The self-signed locale country must be supplied in ${ATL_FACTORY_CONFIG}"}
        ATL_SSL_SELF_CERT_ORG=${ATL_SSL_SELF_CERT_ORG:?"The self-signed certificate organisation must be supplied in ${ATL_FACTORY_CONFIG}"}
        ATL_SSL_SELF_CERT_ORG_UNIT=${ATL_SSL_SELF_CERT_ORG_UNIT:?"The self-signed certificate organisation unit must be supplied in ${ATL_FACTORY_CONFIG}"}
        ATL_SSL_SELF_CERT_EMAIL_ADDRESS=${ATL_SSL_SELF_CERT_EMAIL_ADDRESS:?"The self-signed certificate email address must be supplied in ${ATL_FACTORY_CONFIG}"}
        ATL_SSL_SELF_CERT_PATH=${ATL_SSL_SELF_CERT_PATH:?"The path to write the self-signed certificate to must be supplied in ${ATL_FACTORY_CONFIG}"}
        ATL_SSL_SELF_CERT_KEY_PATH=${ATL_SSL_SELF_CERT_KEY_PATH:?"The path to write the self-signed certificate key to must be supplied in ${ATL_FACTORY_CONFIG}"}
    else
        ATL_SSL_CERT_PATH=${ATL_SSL_CERT_PATH:?"The path to the certificate must be supplied in ${ATL_FACTORY_CONFIG}"}
        ATL_SSL_CERT_KEY_PATH=${ATL_SSL_CERT_KEY_PATH:?"The path to the certificate key must be supplied in ${ATL_FACTORY_CONFIG}"}
    fi
fi
ATL_HOST_NAME=$(atl_hostName)

function start {
    atl_log "=== BEGIN:  service atl-init-40-products start ==="
    atl_log "Initialising enabled Atlassian products"

    disableThisService

    if [[ "xtrue" == "x$(atl_toLowerCase ${ATL_NGINX_ENABLED})" ]]; then
        if [[ "xtrue" == "x$(atl_toLowerCase ${ATL_SSL_SELF_CERT_ENABLED})" ]]; then
            createSelfCert
        fi
        configureNginx
    else
        stopNginx
    fi

    if [[ "xtrue" == "x$(atl_toLowerCase ${ATL_NGINX_ENABLED})" ]]; then
        reloadNginxConfig
    fi

    initProducts

    if [[ "xtrue" == "x$(atl_toLowerCase ${ATL_NGINX_ENABLED})" ]]; then
        reloadNginxConfig
    fi

    atl_log "=== END:    service atl-init-40-products start ==="
}

function disableThisService {
    atl_log "Disabling atl-init-40-products for future boots"
    chkconfig "atl-init-40-products" off >> "${ATL_LOG}" 2>&1
    atl_log "Done disabling atl-init-40-products for future boots"
}

function createSelfCert {
    mkdir -p $(dirname "${ATL_SSL_SELF_CERT_PATH}") >> "${ATL_LOG}" 2>&1
    mkdir -p $(dirname "${ATL_SSL_SELF_CERT_KEY_PATH}") >> "${ATL_LOG}" 2>&1

    local PASSWORD="$(cat /proc/sys/kernel/random/uuid)"
    local CERT_KEY=$(basename "${ATL_SSL_SELF_CERT_KEY_PATH}")
    local CERT_KEY_STEM="${CERT_KEY%.*}"

    # suppress harmless warning messages from openssl "unable to write 'random state'"
    rm -f ~/.rnd

    atl_log "Writing SSL private key to ${ATL_SSL_SELF_CERT_KEY_PATH}"
    openssl genrsa -des3 -passout pass:"${PASSWORD}" -out "$(atl_tempDir)/${CERT_KEY}" 2048 -noout >> "${ATL_LOG}" 2>&1

    atl_log "Removing password from SSL private key for NGINX"
    openssl rsa -in "$(atl_tempDir)/${CERT_KEY}" -passin pass:"${PASSWORD}" -out "${ATL_SSL_SELF_CERT_KEY_PATH}" >> "${ATL_LOG}" 2>&1
    chmod 600 "${ATL_SSL_SELF_CERT_KEY_PATH}" >> "${ATL_LOG}" 2>&1

    atl_log "Generating certificate signing request"
    openssl req -new -key "${ATL_SSL_SELF_CERT_KEY_PATH}" -out "$(atl_tempDir)/${CERT_KEY_STEM}.csr" -passin pass:"${PASSWORD}" \
    -subj "/C=${ATL_SSL_SELF_CERT_COUNTRY}/ST=${ATL_SSL_SELF_CERT_STATE}/L=${ATL_SSL_SELF_CERT_LOCALE}/O=${ATL_SSL_SELF_CERT_ORG}/OU=${ATL_SSL_SELF_CERT_ORG_UNIT}/CN=${ATL_HOST_NAME}/emailAddress=${ATL_SSL_SELF_CERT_EMAIL_ADDRESS}" >> "${ATL_LOG}" 2>&1
    chmod 600 "$(atl_tempDir)/${CERT_KEY_STEM}.csr" >> "${ATL_LOG}" 2>&1

    atl_log "Fulfilling certificate signing request to x509 and writing to ${ATL_SSL_SELF_CERT_PATH}"
    openssl x509 -req -days 365 -in "$(atl_tempDir)/${CERT_KEY_STEM}.csr" -signkey "${ATL_SSL_SELF_CERT_KEY_PATH}" -out "${ATL_SSL_SELF_CERT_PATH}" >> "${ATL_LOG}" 2>&1

    atl_log "Appending certificate to default system bundle"
    cat ${ATL_SSL_SELF_CERT_PATH} >> /etc/pki/tls/certs/ca-bundle.crt
}

function configureNginx {
    atl_log "Configuring NGINX at /etc/nginx/nginx.conf"

    cat <<EOT > /etc/nginx/nginx.conf
# For more information on configuration, see:
#   * Official English Documentation: http://nginx.org/en/docs/
#   * Official Russian Documentation: http://nginx.org/ru/docs/

user  nginx;
worker_processes  1;

error_log  /var/log/nginx/error.log;
#error_log  /var/log/nginx/error.log  notice;
#error_log  /var/log/nginx/error.log  info;

pid        /var/run/nginx.pid;


events {
  worker_connections  1024;
}


http {
  include       /etc/nginx/mime.types;
  default_type  application/octet-stream;

  log_format  main  '\$remote_addr - \$remote_user [\$time_local] "\$request" '
  '\$status \$body_bytes_sent "\$http_referer" '
  '"\$http_user_agent" "\$http_x_forwarded_for"';

  access_log  /var/log/nginx/access.log  main;

  sendfile        on;
  #tcp_nopush     on;

  #keepalive_timeout  0;
  keepalive_timeout  65;

  client_body_buffer_size 128k;
  client_body_timeout 75s;
  client_header_timeout 75s;
  client_max_body_size 0;
  proxy_buffer_size 16k;
  proxy_buffers 32 16k;
  proxy_busy_buffers_size 64k;
  proxy_connect_timeout 75s;
  proxy_read_timeout 1800s;
  proxy_send_timeout 90s;
  proxy_temp_file_write_size 64k;
  send_timeout 75s;
  server_names_hash_bucket_size 128;

  #gzip  on;

  # Load modular configuration files from the /etc/nginx/conf.d directory.
  # See http://nginx.org/en/docs/ngx_core_module.html#include
  # for more information.
  include /etc/nginx/conf.d/*.conf;

  index   index.html index.htm;

  # Catch-all for unrecognised virtual hosts - most likely to be triggered when the external host name of this EC2
  # instance has changed. If this happens, you should run /opt/atlassian/bin/atl-update-host-name.sh to update the
  # configured host name in NGINX and the installed Atlassian products.
EOT
    if [[ "xtrue" == "x$(atl_toLowerCase ${ATL_SSL_SELF_CERT_ENABLED})" ]]; then
        cat <<EOT >> /etc/nginx/nginx.conf
  server {
    listen      80;
    # ATL server host start
    # ATL server host end

    return      301 https://\$server_name\$request_uri;
  }

  server {
    listen                    443;
    # The contents of the lines between "ATL server host start" and "ATL server host end" will be replaced when
    # atl-update-host-name.sh is run (to reflect when the external host name of this EC2 instance has changed)
    # ATL server host start
    # ATL server host end

    ssl                       on;
    ssl_certificate           ${ATL_SSL_CERT_PATH};
    ssl_certificate_key       ${ATL_SSL_CERT_KEY_PATH};
    ssl_session_timeout       5m;
    ssl_protocols             TLSv1 TLSv1.1 TLSv1.2;
    ssl_ciphers               HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    # Optional optimisation - please refer to http://nginx.org/en/docs/http/configuring_https_servers.html
    # ssl_session_cache   shared:SSL:10m;

    error_page 502 /error.html;
    location /error.html {
        internal;
    }

    # ATL products entries start
    # ATL products entries end
  }

  server {
    listen 443 default_server;
    server_name _ "";

    ssl                       on;
    ssl_certificate           ${ATL_SSL_CERT_PATH};
    ssl_certificate_key       ${ATL_SSL_CERT_KEY_PATH};
    ssl_session_timeout       5m;
    ssl_protocols             TLSv1 TLSv1.1 TLSv1.2;
    ssl_ciphers               HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    location / {
      rewrite ^ /hostnamechanged.html break;
    }
  }
EOT
    else
        cat <<EOT >> /etc/nginx/nginx.conf
  server {
    listen 80;
    # The contents of the lines between "ATL server host start" and "ATL server host end" will be replaced when
    # atl-update-host-name.sh is run (to reflect when the external host name of this EC2 instance has changed)
    # ATL server host start
    # ATL server host end

    error_page 502 /error.html;
    location /error.html {
        internal;
    }

    # ATL products entries start
    # ATL products entries end
  }

  server {
    listen 80 default_server;
    server_name _ "";

    location / {
      rewrite ^ /hostnamechanged.html break;
    }
  }
EOT
    fi
    cat <<EOT >> /etc/nginx/nginx.conf
}
EOT
    atl_setNginxHostName "${ATL_HOST_NAME}"
}

function initProducts {
    for product in $(atl_enabled_products); do
        local LOWER_CASE_PRODUCT="$(atl_toLowerCase ${product})"
        local SENTENCE_CASE_PRODUCT="$(atl_toSentenceCase ${product})"

        if [[ "xfunction" == "x$(type -t init${SENTENCE_CASE_PRODUCT})" ]]; then
            atl_log "Initialising enabled product \"${SENTENCE_CASE_PRODUCT}\""
            init${SENTENCE_CASE_PRODUCT}
        else
            atl_log "Not initialising enabled product \"${SENTENCE_CASE_PRODUCT}\" because no initialisation has been defined"
        fi
    done
}

function initBitbucket {
    atl_log "Starting service atl-init-bitbucket"
    service atl-init-bitbucket start
}

function initJira {
    atl_log "Starting service atl-init-jira"
    service atl-init-jira start
}

function initConfluence {
    atl_log "Starting service atl-init-confluence"
    service atl-init-confluence start
}

function initSynchrony {
    atl_log "Starting service atl-init-synchrony"
    service atl-init-synchrony start
}

function reloadNginxConfig {
    atl_log "Reloading NGINX Configuration"
    service nginx reload
}

function stopNginx {
    atl_log "Stopping NGINX Service"
    service nginx stop
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