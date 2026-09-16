#===============================
FROM debian:buster-slim AS base
#===============================

LABEL maintainer="Marius Millea <mariusmillea@gmail.com>"

# fix debian buster sources.list
RUN sed -i 's/deb.debian.org/archive.debian.org/g' /etc/apt/sources.list \
    && sed -i 's/security.debian.org/archive.debian.org/g' /etc/apt/sources.list

# install packages
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        dh-autoreconf \
        g++ \
        git \
        libcurl4-gnutls-dev \
        default-libmysqlclient-dev \
        libssl-dev \
        libzip-dev \
        m4 \
        make \
        default-mysql-client \
        php7.3-cli \
        php7.3-mysql \
        php7.3-xml \
        pkg-config \
        python \
        python3 \
        python-mysqldb \
        python3-mysqldb \
        nlohmann-json3-dev \
    && rm -rf /var/lib/apt/lists

# get source and compile server from fork
COPY --chown=1000 boinc /usr/local/boinc
RUN cd /usr/local/boinc && ./_autosetup && ./configure --disable-client --disable-manager && make

# project-making scripts
COPY images/makeproject/makeproject-step1.sh images/makeproject/makeproject-step2.sh /usr/local/bin/
COPY images/makeproject/secrets.env /usr/local/share/boinc-secrets.env

# some other project files (some of which will be put in the correct place with
# ONBUILD instructions later)
COPY --chown=1000 images/makeproject/db_dump_spec.xml /.project_root/
COPY --chown=1000 images/makeproject/html /.project_root/html/

#===========================
FROM base AS makeproject
#===========================

# everything which depends on build-args is done as ONBUILD in this stage, so
# the user can customize it

ARG TAG
ENV TAG=$TAG
ONBUILD ARG BOINC_USER
ONBUILD ARG PROJECT_ROOT
ONBUILD ENV BOINC_USER=$BOINC_USER \
            PROJECT_ROOT=$PROJECT_ROOT \
            USER=$BOINC_USER \
            HOME=/home/$BOINC_USER \
            MYSQL_HOST=mysql

# set up the non-root user who compiles the server
ONBUILD RUN adduser $BOINC_USER --disabled-password --gecos ""

# ensure the project/secrets volumes have the right permissions when mounted
ONBUILD RUN mkdir $PROJECT_ROOT.dst && chown $BOINC_USER:$BOINC_USER $PROJECT_ROOT.dst
ONBUILD RUN mkdir -p /run/secrets && chown $BOINC_USER:$BOINC_USER /run/secrets

ONBUILD USER $BOINC_USER


# build server
ONBUILD RUN makeproject-step1.sh
ONBUILD CMD makeproject-step2.sh

ONBUILD WORKDIR $PROJECT_ROOT



#==========================================
FROM makeproject AS makeproject-defaultargs
#==========================================

# this triggers the ONBUILD directives using the default ARGs so we also get a
# fully built example image
