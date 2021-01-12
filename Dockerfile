# vim:set ft=dockerfile:

# Setup A Template Image
FROM centos:8 as template

# Default ENV Variables
ENV MARIADB_VERSION=10.5
ENV MARIADB_ENTERPRISE_TOKEN=deaa8829-2a00-4b1a-a99c-847e772f6833

# Build The Replication UDF
################################################################################
FROM template as udf_builder

# Change The WORKDIR
WORKDIR /udf

# Install Needed Software To Compile The UDF
ADD https://dlm.mariadb.com/enterprise-release-helpers/mariadb_es_repo_setup /tmp

RUN chmod +x /tmp/mariadb_es_repo_setup && \
    /tmp/mariadb_es_repo_setup --mariadb-server-version=${MARIADB_VERSION} --token=${MARIADB_ENTERPRISE_TOKEN} --apply

RUN dnf -y update && \
    dnf -y install gcc MariaDB-devel libcurl-devel

# Copy The UDF's Source
COPY replication_udf/* /udf/

# Compile The UDF
RUN gcc -fPIC -shared -o replication.so cJSON.c replication.c `mariadb_config --include` -lcurl -lm `mariadb_config --libs`

# Compile pcre2grep As It's Needed For HTAP's Backup/Restore
################################################################################
FROM template as pcre2grep-builder

USER root
WORKDIR /opt
ARG PCRE2_VERSION=10.35

# Install The Build Dependencies
RUN dnf -y update && \
    dnf group install -y "Development Tools"

# Compile pcre2grep
RUN curl https://ftp.pcre.org/pub/pcre/pcre2-${PCRE2_VERSION}.tar.gz -o pcre2.tar.gz && \
    tar -xf pcre2.tar.gz && \
    cd pcre2-${PCRE2_VERSION} && \
    ./configure --disable-shared --with-heap-limit=1024 --with-match-limit=500000 --with-match-limit-depth=5000 && \
    make && \
    cp pcre2grep /opt

# Build The ColumnStore Image
################################################################################
FROM template as main

# Default ENV Variables
ENV TINI_VERSION=v0.18.0

# Add A SkySQL Specific PATH Entry
ENV PATH="/mnt/skysql/columnstore-container-scripts:${PATH}"

# Copy The Google Cloud SDK Repo To Image
COPY config/*.repo /etc/yum.repos.d/

# Add MariaDB Enterprise Repo
ADD https://dlm.mariadb.com/enterprise-release-helpers/mariadb_es_repo_setup /tmp

RUN chmod +x /tmp/mariadb_es_repo_setup && \
    /tmp/mariadb_es_repo_setup --mariadb-server-version=${MARIADB_VERSION} --token=${MARIADB_ENTERPRISE_TOKEN} --apply

# Update System
RUN dnf -y install epel-release && \
    dnf -y upgrade

# Install Various Packages/Tools
RUN dnf -y install bind-utils \
    bc \
    boost \
    cracklib \
    cracklib-dicts \
    expect \
    git \
    glibc-langpack-en \
    google-cloud-sdk \
    jemalloc \
    jq \
    less \
    libaio \
    monit \
    nano \
    net-tools \
    openssl \
    perl \
    perl-DBI \
    python3 \
    python3-requests \
    rsyslog \
    snappy \
    sudo \
    tcl \
    vim \
    wget

# Default Locale Variables
ENV LC_ALL=en_US.UTF-8
ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US.UTF-8

# Install MariaDB Packages
RUN dnf -y install \
     MariaDB-shared \
     MariaDB-client \
     MariaDB-server \
     MariaDB-backup \
     MariaDB-cracklib-password-check \
     MariaDB-columnstore-engine

# Add, Unpack & Clean CMAPI Package
RUN mkdir -p /opt/cmapi
ADD https://dlm.mariadb.com/${MARIADB_ENTERPRISE_TOKEN}/mariadb-enterprise-server/10.5.6-4/cmapi/mariadb-columnstore-cmapi-1.1.tar.gz /opt/cmapi
WORKDIR /opt/cmapi
RUN tar -xvzf mariadb-columnstore-cmapi-1.1.tar.gz && \
    rm -f mariadb-columnstore-cmapi.tar.gz && \
    rm -rf /opt/cmapi/service*
WORKDIR /

# Copy Config Files & Scripts To Image
COPY config/etc/ /etc/

COPY config/.boto /root/.boto

COPY scripts/demo \
     scripts/columnstore-init \
     scripts/cmapi-start \
     scripts/cmapi-stop \
     scripts/cmapi-restart \
     scripts/skysql-specific-startup.sh \
     scripts/mcs-process \
     backup_restore/columnstore-backup.sh \
     backup_restore/columnstore_engine_restore.sh \
     backup_restore/columnstore-restore.sh \
     backup_restore/htap-backup.sh \
     backup_restore/htap-restore.sh \
     backup_restore/innodb_engine_restore.sh \
     backup_restore/mariabackup-10.4 \
     backup_restore/restore_user_credentials.sh /usr/bin/

COPY --from=udf_builder /udf/replication.so /usr/lib64/mysql/plugin/replication.so
COPY --from=pcre2grep-builder /opt/pcre2grep /usr/bin/pcre2grep

# Add Tini Init Process
ADD https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini /usr/bin/tini

# Make Scripts Executable
RUN chmod +x /usr/bin/tini \
    /usr/bin/demo \
    /usr/bin/columnstore-init \
    /usr/bin/cmapi-start \
    /usr/bin/cmapi-stop \
    /usr/bin/cmapi-restart \
    /usr/bin/skysql-specific-startup.sh \
    /usr/bin/mcs-process \
    /usr/bin/columnstore-backup.sh \
    /usr/bin/columnstore_engine_restore.sh \
    /usr/bin/columnstore-restore.sh \
    /usr/bin/htap-backup.sh \
    /usr/bin/htap-restore.sh \
    /usr/bin/innodb_engine_restore.sh \
    /usr/bin/mariabackup-10.4 \
    /usr/bin/restore_user_credentials.sh

# Stream Edit Monit Config
RUN sed -i 's|set daemon\s.30|set daemon 5|g' /etc/monitrc && \
    sed -i 's|#.*with start delay\s.*240|  with start delay 60|' /etc/monitrc

# Add A Configuration Directory To my.cnf That Can Be Mounted By SkySQL & Disable The ed25519 Auth Plugin (DBAAS-2701)
RUN echo '!includedir /mnt/skysql/columnstore-container-configuration' >> /etc/my.cnf && \
    mkdir -p /mnt/skysql/columnstore-container-configuration && \
    touch /etc/my.cnf.d/mariadb-enterprise.cnf && \
    sed -i 's|plugin-load-add=auth_ed25519|#plugin-load-add=auth_ed25519|' /etc/my.cnf.d/mariadb-enterprise.cnf

# Create Persistent Volumes
VOLUME ["/etc/columnstore", "/var/lib/mysql", "/var/lib/columnstore"]

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
    cat /dev/null > ~/.bash_history && \
    history -c

# Bootstrap
ENTRYPOINT ["/usr/bin/tini","--","docker-entrypoint.sh"]
CMD cmapi-start && monit -I
