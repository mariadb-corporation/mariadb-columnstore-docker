# vim:set ft=dockerfile:

# Setup A Template Image
FROM rockylinux:8

# Define Production ARG Variables
ARG TOKEN=${TOKEN}
ARG VERSION=${VERSION:-10.6}

# Define Development ARG Variables
ARG DEV=${DEV:-false}
ARG ARCH=${ARCH:-amd64}
ARG MCSBRANCH=${MCSBRANCH:-develop}
ARG MCSBUILDPATH=${MCSBUILDPATH:-latest/10.9}
ARG CMAPIBRANCH=${CMAPIBRANCH:-develop}
ARG CMAPIBUILDPATH=${CMAPIBUILDPATH:-latest/amd64}

# Define SkySQL Specific Path
ENV PATH="/mnt/skysql/columnstore-container-scripts:${PATH}"

# Add MariaDB Enterprise Repo
RUN curl -LsS https://dlm.mariadb.com/enterprise-release-helpers/mariadb_es_repo_setup | \
    bash -s -- --mariadb-server-version=${VERSION} --token=${TOKEN} --apply

# Add Drone Repo (Development Use Only)
RUN if [[ "${DEV}" == true ]]; then \
    printf "%s\n" \
    "[Columnstore-Internal-Testing]" \
    "name = Columnstore Drone Build" \
    "baseurl = https://cspkg.s3.amazonaws.com/${MCSBRANCH}/${MCSBUILDPATH}/${ARCH}/rockylinux8" \
    "gpgcheck = 0" \
    "enabled = 1" \
    "module_hotfixes = 1" \
    "" \
    "[CMAPI-Internal-Testing]" \
    "name = CMAPI Drone Build" \
    "baseurl = https://cspkg.s3.amazonaws.com/cmapi/${CMAPIBRANCH}/${CMAPIBUILDPATH}/${ARCH}" \
    "gpgcheck = 0" \
    "enabled = 1" \
    "module_hotfixes = 1" > /etc/yum.repos.d/drone.repo; fi

# Copy The Google Cloud SDK Repo To Image
COPY config/yum.repos.d/google-sdk-${ARCH}.repo /etc/yum.repos.d/

# Copy XMLstarlet to Image
COPY rpms/${ARCH}/xmlstarlet-1.6.1-20.el8.rpm /tmp/

# Update System
RUN dnf -y install epel-release && \
    dnf -y upgrade

# Install Various Packages/Tools
RUN dnf -y install awscli \
    bind-utils \
    bc \
    boost \
    cracklib \
    cracklib-dicts \
    expect \
    gcc \
    git \
    glibc-langpack-en \
    google-cloud-sdk \
    htop \
    jemalloc \
    jq \
    less \
    libaio \
    libffi-devel \
    libxml2-devel \
    libxslt-devel \
    monit \
    nano \
    net-tools \
    openssl \
    perl \
    perl-DBI \
    procps-ng \
    redhat-lsb-core \
    rsync \
    rsyslog \
    snappy \
    tcl \
    tini \
    tzdata \
    vim \
    wget \
    /tmp/xmlstarlet-1.6.1-20.el8.rpm && \
    ln -s /usr/lib/lsb/init-functions /etc/init.d/functions && \
    sed -i 's/-n $\*$/-n $\* \\/' /etc/redhat-lsb/lsb_log_message && \
    rm -rf /usr/share/zoneinfo/tzdata.zi /usr/share/zoneinfo/leapseconds

# Define ENV Variables
ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8
ENV MCSBRANCH=${MCSBRANCH:-develop}
ENV CMAPIBRANCH=${CMAPIBRANCH:-develop}

# Install MariaDB Packages & Load Time Zone Info
RUN dnf -y install \
    MariaDB-shared \
    MariaDB-client \
    MariaDB-server \
    MariaDB-backup \
    MariaDB-cracklib-password-check && \
    cp /usr/share/mysql/mysql.server /etc/init.d/mariadb && \
    /etc/init.d/mariadb start && \
    mysql_tzinfo_to_sql /usr/share/zoneinfo | mariadb mysql && \
    /etc/init.d/mariadb stop && \
    dnf -y install MariaDB-columnstore-engine \
    MariaDB-columnstore-cmapi

# Copy Config Files & Scripts To Image
COPY config/etc/ /etc/
COPY scripts/provision \
    scripts/columnstore-init \
    scripts/cmapi-start \
    scripts/cmapi-stop \
    scripts/cmapi-restart \
    scripts/skysql-specific-startup.sh \
    scripts/start-services \
                       /usr/bin/

# Make Scripts Executable
RUN chmod +x /usr/bin/provision \
    /usr/bin/columnstore-init \
    /usr/bin/cmapi-start \
    /usr/bin/cmapi-stop \
    /usr/bin/cmapi-restart \
    /usr/bin/skysql-specific-startup.sh \
    /usr/bin/start-services 

# Stream Edit Some Configs
RUN sed -i 's|set daemon\s.30|set daemon 5|g' /etc/monitrc && \
    sed -i 's|#.*with start delay\s.*240|  with start delay 60|' /etc/monitrc

# Add A Configuration Directory To my.cnf That Can Be Mounted By SkySQL & Disable The ed25519 Auth Plugin (DBAAS-2701)
RUN echo '!includedir /mnt/skysql/columnstore-container-configuration' >> /etc/my.cnf && \
    mkdir -p /mnt/skysql/columnstore-container-configuration && \
    touch /etc/my.cnf.d/mariadb-enterprise.cnf && \
    sed -i 's|plugin-load-add=auth_ed25519|#plugin-load-add=auth_ed25519|' /etc/my.cnf.d/mariadb-enterprise.cnf

# Customize cmapi_server.conf
RUN printf "%s\n" \
    ""\
    "[Dispatcher]"\
    "name = 'container'"\
    "path = '/usr/share/columnstore/cmapi/mcs_node_control/custom_dispatchers/container.sh'"\
    ""\
    "[application]"\
    "auto_failover = True" >> /etc/columnstore/cmapi_server.conf

# Make Copies Of MariaDB Related Folders
RUN /etc/init.d/mariadb stop && \
    rsync -Rravz --quiet /var/lib/mysql/ /var/lib/columnstore /etc/columnstore /etc/my.cnf.d /opt/ && \
    rm -f /opt/var/lib/mysql/mysql.sock

# Create Persistent Volumes
VOLUME ["/etc/columnstore", "/etc/my.cnf.d","/var/lib/mysql","/var/lib/columnstore"]

# Copy Entrypoint To Image
COPY scripts/docker-entrypoint.sh /usr/bin/

# Do Some Housekeeping
RUN chmod +x /usr/bin/docker-entrypoint.sh && \
    ln -s /usr/bin/docker-entrypoint.sh /docker-entrypoint.sh && \
    sed -i 's|SysSock.Use="off"|SysSock.Use="on"|' /etc/rsyslog.conf && \
    sed -i 's|^.*module(load="imjournal"|#module(load="imjournal"|g' /etc/rsyslog.conf && \
    sed -i 's|^.*StateFile="imjournal.state")|#  StateFile="imjournal.state")|g' /etc/rsyslog.conf && \
    dnf clean all && \
    rm -rf /var/cache/dnf && \
    find /var/log -type f -exec cp /dev/null {} \; && \
    rm -rf /var/lib/mysql/*.err && \
    cat /dev/null > ~/.bash_history && \
    history -c

# Bootstrap
ENTRYPOINT ["/usr/bin/tini","--","docker-entrypoint.sh"]
CMD ["start-services"]
