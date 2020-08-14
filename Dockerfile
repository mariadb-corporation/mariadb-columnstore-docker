# vim:set ft=dockerfile:
FROM centos:8

# Update system
RUN dnf -y install epel-release && \
    dnf -y upgrade

# Copy the Google Cloud SDK repo to image
COPY config/*.repo /etc/yum.repos.d/

# Install some basic dependencies
RUN dnf -y install bind-utils \
    bc \
    boost \
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

# Default env variables
ENV LC_ALL en_US.UTF-8
ENV LANG en_US.UTF-8
ENV LANGUAGE en_US.UTF-8
ENV TINI_VERSION=v0.18.0

# Add MariaDB Repo
#RUN wget -O /tmp/mariadb_repo_setup https://downloads.mariadb.com/MariaDB/mariadb_repo_setup && \
#    chmod +x /tmp/mariadb_repo_setup && \
#    ./tmp/mariadb_repo_setup --mariadb-server-version=mariadb-10.5

# Add Tini Init Process
ADD https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini /usr/bin/tini

# Add CMAPI Package
RUN mkdir -p /opt/cmapi
ADD https://cspkg.s3.amazonaws.com/cmapi/master/169/mariadb-columnstore-cmapi.tar.gz /opt/cmapi
WORKDIR /opt/cmapi
RUN tar -xvzf mariadb-columnstore-cmapi.tar.gz && rm -f mariadb-columnstore-cmapi.tar.gz && rm -rf /opt/cmapi/service*
WORKDIR /

# Install MariaDB/ColumnStore packages
RUN dnf -y install \
     https://cspkg.s3.amazonaws.com/develop/cron/416/centos8/MariaDB-shared-10.5.6-1.el8.x86_64.rpm \
     https://cspkg.s3.amazonaws.com/develop/cron/416/centos8/MariaDB-common-10.5.6-1.el8.x86_64.rpm \
     https://cspkg.s3.amazonaws.com/develop/cron/416/centos8/MariaDB-client-10.5.6-1.el8.x86_64.rpm \
     https://cspkg.s3.amazonaws.com/develop/cron/416/centos8/MariaDB-server-10.5.6-1.el8.x86_64.rpm \
     https://cspkg.s3.amazonaws.com/develop/cron/416/centos8/MariaDB-columnstore-engine-10.5.6-1.el8.x86_64.rpm

# Copy files to image
COPY config/monit.d/ /etc/monit.d/

COPY config/.boto /root/.boto

COPY config/cmapi_server.conf /etc/columnstore/cmapi_server.conf

COPY scripts/demo \
     scripts/columnstore-init \
     scripts/cmapi-start \
     scripts/cmapi-stop \
     scripts/cmapi-restart \
     scripts/mcs-process /usr/bin/

# Chmod some files
RUN chmod +x /usr/bin/tini \
    /usr/bin/demo \
    /usr/bin/columnstore-init \
    /usr/bin/cmapi-start \
    /usr/bin/cmapi-stop \
    /usr/bin/cmapi-restart \
    /usr/bin/mcs-process

# Stream edit some files

RUN sed -i 's|set daemon\s.30|set daemon 5|g' /etc/monitrc && \
    sed -i 's|#.*with start delay\s.*240|  with start delay 60|g' /etc/monitrc

# Create persistent volumes
VOLUME ["/etc/columnstore", "/var/lib/mysql", "/var/lib/columnstore"]

# Copy entrypoint to image
COPY scripts/docker-entrypoint.sh /usr/bin/

# Make entrypoint executable & create legacy symlink
RUN chmod +x /usr/bin/docker-entrypoint.sh && \
    ln -s /usr/bin/docker-entrypoint.sh /docker-entrypoint.sh

# Clean system and reduce size
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
