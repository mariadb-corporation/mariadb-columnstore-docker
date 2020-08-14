# vim:set ft=dockerfile:
FROM centos:8

# Default Env Variables
ENV TINI_VERSION=v0.18.0

# Add A SkySQL Specific PATH Entry
ENV PATH="/mnt/skysql/columnstore-container-scripts:${PATH}"

# Copy The Google Cloud SDK Repo To Image
COPY config/*.repo /etc/yum.repos.d/

# Update System
RUN dnf -y install epel-release && \
    dnf -y upgrade

# Install Some Dependencies
RUN dnf -y install bind-utils \
    bc \
    boost \
    expect \
    git \
    glibc-langpack-en \
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
    python3-pip \
    rsyslog \
    snappy \
    sudo \
    tcl \
    vim \
    wget

# Install Cloud Tools
RUN pip3 install awscli --user && \
    dnf -y install google-cloud-sdk

# Default Locale Variables
ENV LC_ALL=en_US.UTF-8
ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US.UTF-8

### BEGIN TEMPORARY BUILD

# Add MariaDB Repo
#RUN wget -O /tmp/mariadb_repo_setup https://downloads.mariadb.com/MariaDB/mariadb_repo_setup && \
#    chmod +x /tmp/mariadb_repo_setup && \
#    ./tmp/mariadb_repo_setup --mariadb-server-version=mariadb-10.5

# Install MariaDB Packages
RUN dnf -y install \
     https://cspkg.s3.amazonaws.com/develop/cron/416/centos8/MariaDB-shared-10.5.6-1.el8.x86_64.rpm \
     https://cspkg.s3.amazonaws.com/develop/cron/416/centos8/MariaDB-common-10.5.6-1.el8.x86_64.rpm \
     https://cspkg.s3.amazonaws.com/develop/cron/416/centos8/MariaDB-client-10.5.6-1.el8.x86_64.rpm \
     https://cspkg.s3.amazonaws.com/develop/cron/416/centos8/MariaDB-server-10.5.6-1.el8.x86_64.rpm \
     https://cspkg.s3.amazonaws.com/develop/cron/416/centos8/MariaDB-backup-10.5.6-1.el8.x86_64.rpm \
     https://cspkg.s3.amazonaws.com/develop/cron/416/centos8/MariaDB-cracklib-password-check-10.5.6-1.el8.x86_64.rpm \
     https://cspkg.s3.amazonaws.com/develop/cron/416/centos8/MariaDB-columnstore-engine-10.5.6-1.el8.x86_64.rpm

### END TEMPORARY BUILD

# Add, Unpack & Clean CMAPI Package
RUN mkdir -p /opt/cmapi
ADD https://cspkg.s3.amazonaws.com/cmapi/master/189/mariadb-columnstore-cmapi.tar.gz /opt/cmapi
WORKDIR /opt/cmapi
RUN tar -xvzf mariadb-columnstore-cmapi.tar.gz && rm -f mariadb-columnstore-cmapi.tar.gz && rm -rf /opt/cmapi/service*
WORKDIR /

# Copy Config Files & Scripts To Image
COPY config/monit.d/ /etc/monit.d/

COPY config/.boto /root/.boto

COPY config/cmapi_server.conf /etc/columnstore/cmapi_server.conf

COPY scripts/demo \
     scripts/columnstore-init \
     scripts/cmapi-start \
     scripts/cmapi-stop \
     scripts/cmapi-restart \
     scripts/columnstore-backup.sh \
     scripts/columnstore-restore.sh \
     scripts/mcs-process /usr/bin/

# Add Tini Init Process
ADD https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini /usr/bin/tini

# Make Scripts Executable
RUN chmod +x /usr/bin/tini \
    /usr/bin/demo \
    /usr/bin/columnstore-init \
    /usr/bin/cmapi-start \
    /usr/bin/cmapi-stop \
    /usr/bin/cmapi-restart \
    /usr/bin/columnstore-backup.sh \
    /usr/bin/columnstore-restore.sh \
    /usr/bin/mcs-process

# Stream Edit Monit Config
RUN sed -i 's|set daemon\s.30|set daemon 5|g' /etc/monitrc && \
    sed -i 's|#.*with start delay\s.*240|  with start delay 60|' /etc/monitrc

# Add A Configuration Directory To my.cnf That Can Be Mounted By SkySQL & Disable The ed25519 Auth Plugin (DBAAS-2701)
RUN echo '!includedir /mnt/skysql/columnstore-container-configuration' >> /etc/my.cnf && \
    mkdir -p /mnt/skysql/columnstore-container-configuration && \
    touch /etc/my.cnf.d/mariadb-enterprise.cnf && \
    sed -i 's|plugin-load-add=auth_ed25519|#plugin-load-add=auth_ed25519|' /etc/my.cnf.d/mariadb-enterprise.cnf

EXPOSE 3306

# Create Persistent Volumes
VOLUME ["/etc/columnstore", "/var/lib/mysql", "/var/lib/columnstore"]

# Copy Entrypoint To Image
COPY scripts/docker-entrypoint.sh /usr/bin/

# Make Entrypoint Executable & Create Legacy Symlink
RUN chmod +x /usr/bin/docker-entrypoint.sh && \
    ln -s /usr/bin/docker-entrypoint.sh /docker-entrypoint.sh

# Clean System & Reduce Size
RUN dnf clean all && \
    rm -rf /var/cache/dnf && \
    find /var/log -type f -exec cp /dev/null {} \; && \
    cat /dev/null > ~/.bash_history && \
    history -c && \
    sed -i 's|SysSock.Use="off"|SysSock.Use="on"|' /etc/rsyslog.conf && \
    sed -i 's|^.*module(load="imjournal"|#module(load="imjournal"|g' /etc/rsyslog.conf && \
    sed -i 's|^.*StateFile="imjournal.state")|#  StateFile="imjournal.state")|g' /etc/rsyslog.conf

# Bootstrap
ENTRYPOINT ["/usr/bin/tini","--","docker-entrypoint.sh"]
CMD cmapi-start && monit -I
