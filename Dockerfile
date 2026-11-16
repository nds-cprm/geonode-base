# GeoNode base image, derived from the SGB/CPRM GDAL image instead of Ubuntu.
#
# Port of GeoNode's docker/base/ubuntu/26/Dockerfile (https://github.com/GeoNode/geonode).
# Differences from upstream, all because the GDAL image already provides them:
#   - Debian trixie + Python 3.12 in /usr/local (python:3.12-slim-trixie), not Ubuntu's python3
#   - GDAL (C library, utilities and Python bindings) comes from /opt/geosgb; Ubuntu's libgdal-dev,
#     gdal-bin and python3-gdal are NOT installed (they would add a second, older GDAL)
#   - the virtualenv is the image's /opt/geosgb/venv (it already holds osgeo, numpy and pyarrow);
#     /usr/src/venv is kept as a symlink for scripts that expect the upstream path
#   - system python3-* and uwsgi packages are dropped: everything Python goes into the venv
#   - multi-stage: packages that need a compiler are built as wheels on the GDAL devel image
#     (same Debian, Python and /opt/geosgb layout), so the final image has no compilers or headers

# base images: ndscprm/gdal (Debian trixie + official Python + GDAL in /opt/geosgb), by full name. The defaults
# are the moving tags, rebuilt in place every week, for local builds; the CI passes the exact images the CI of
# gdal-oci has just published (dated tag and digest: <tag>-<YYYYMMDD>@sha256:...), all of the same build of the base
ARG GDAL_IMAGE_DEVEL=docker.io/ndscprm/gdal:3.12.4-py3.12-devel
ARG GDAL_IMAGE_PY=docker.io/ndscprm/gdal:3.12.4-py3.12

# GeoNode version this base is made for (the Python pins below follow its pyproject.toml); it is the image tag,
# read by the CI workflow (keep this format: ARG GEONODE_VERSION=X.Y.Z)
ARG GEONODE_VERSION=5.2.0

# Python packages of the upstream base, plus psycopg2 (GeoNode requirement that needs libpq to build).
# Keep UWSGI_VERSION and PSYCOPG2_VERSION equal to GeoNode's pyproject.toml pins: if they differ, pip tries
# to build them in the derived image, which has no compiler
ARG UWSGI_VERSION=2.0.30
ARG PSYCOPG2_VERSION=2.9.13
ARG INVOKE_VERSION=2.2.0
ARG SHERLOCK_VERSION=0.4.1
# GeoNode pins numpy 1.x; the image venv ships 2.x. Downgraded here, so the base already has what GeoNode installs.
# The GDAL bindings (built against numpy 2) work with 1.x; pyarrow does not, and is removed
ARG NUMPY_VERSION=1.26.*


FROM ${GDAL_IMAGE_DEVEL} AS build

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG UWSGI_VERSION
ARG PSYCOPG2_VERSION
ARG INVOKE_VERSION
ARG SHERLOCK_VERSION
ARG NUMPY_VERSION

# headers not already in the devel image (libpq-dev comes with the GDAL build; listed to be explicit)
RUN apt-get update -y && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        libpq-dev libpcre2-dev && \
    rm -rf /var/lib/apt/lists/*

# wheels for everything the final stage installs (dependencies included), so it installs offline.
# wheel is not downgraded to 0.38.1 as upstream does: the venv's setuptools (>= 70) needs a newer one
RUN pip wheel --no-cache-dir --wheel-dir /wheels \
        "uWSGI==${UWSGI_VERSION}" \
        "psycopg2==${PSYCOPG2_VERSION}" \
        "invoke==${INVOKE_VERSION}" \
        "sherlock==${SHERLOCK_VERSION}" \
        "numpy==${NUMPY_VERSION}" \
        certifi

# Debian runtime packages of the compiled wheels: install them here, ldd their ELF files and map the
# libraries to the packages that own them (libs under /opt/geosgb and /usr/local exist in the final image)
RUN pip install --no-cache-dir --no-index --find-links /wheels \
        "uWSGI==${UWSGI_VERSION}" "psycopg2==${PSYCOPG2_VERSION}" && \
    SITE_PACKAGES=$(python -c 'import sysconfig; print(sysconfig.get_paths()["platlib"])') && \
    LDD_OUT=$( { ldd "${VIRTUAL_ENV}/bin/uwsgi"; find "${SITE_PACKAGES}/psycopg2" -name '*.so' -exec ldd {} +; } ) && \
    if grep 'not found' <<< "$LDD_OUT" >&2; then exit 1; fi && \
    awk '$2 == "=>" && $3 ~ /^\// {print $3}' <<< "$LDD_OUT" | xargs realpath | sort -u | \
        grep -v -e '^/opt/geosgb/' -e '^/usr/local/' | \
        while read -r LIB; do dpkg -S "$LIB" | cut -d: -f1; done | \
        sort -u > /tmp/runtime-packages.txt && \
    test -s /tmp/runtime-packages.txt && \
    cat /tmp/runtime-packages.txt


FROM ${GDAL_IMAGE_PY} AS release

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ENV DEBIAN_FRONTEND=noninteractive

ARG UWSGI_VERSION
ARG PSYCOPG2_VERSION
ARG INVOKE_VERSION
ARG SHERLOCK_VERSION
ARG NUMPY_VERSION

# PostgreSQL client: Debian's own package, 17 in trixie, the same major as the libpq5 the GDAL image
# links against (upstream uses 15 from PGDG).
# PGDG disabled. To use another major, uncomment the block below and set postgresql-client-${PG_CLIENT_VERSION}
# in the package list. Its pin keeps PGDG's libpq/GIS packages from replacing Debian's; PGDG clients newer
# than 17 need libpq5 >= their major, so the pin would also have to allow libpq5.
# ARG PG_CLIENT_VERSION=15
# RUN apt-get update -y && \
#     apt-get install -y --no-install-recommends curl ca-certificates && \
#     install -d -m 0755 /etc/apt/keyrings && \
#     curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc -o /etc/apt/keyrings/postgresql.asc && \
#     . /etc/os-release && \
#     echo "deb [signed-by=/etc/apt/keyrings/postgresql.asc] https://apt.postgresql.org/pub/repos/apt/ ${VERSION_CODENAME}-pgdg main" \
#         > /etc/apt/sources.list.d/pgdg.list && \
#     printf 'Package: *\nPin: release o=apt.postgresql.org\nPin-Priority: -1\n\nPackage: postgresql-client-%s postgresql-client-common\nPin: release o=apt.postgresql.org\nPin-Priority: 500\n' \
#         "${PG_CLIENT_VERSION}" > /etc/apt/preferences.d/pgdg && \
#     rm -rf /var/lib/apt/lists/*

# Runtime libraries of the wheels built in the build stage, and the tools the upstream base ships.
# libmagic1: loaded via ctypes by python-magic (GeoNode's FileValidationUploadHandler, every file upload);
# upstream gets it indirectly through libgdal-dev, which is not installed here.
# procps, file, less: troubleshooting only (GeoNode does not call them). procps gives ps/top/pkill/free to inspect
# uWSGI and Celery processes; file reads upload types with the same libmagic as python-magic; less for logs.
# Upstream has them via its -dev packages. Safe to drop for a slimmer image
RUN --mount=type=bind,from=build,source=/tmp/runtime-packages.txt,target=/tmp/runtime-packages.txt \
    apt-get update -y && \
    xargs -a /tmp/runtime-packages.txt \
        apt-get install -y --no-install-recommends && \
    apt-get install -y --no-install-recommends \
        libmagic1 \
        procps file less \
        curl ca-certificates wget unzip gnupg2 lsb-release git \
        vim zip gettext geoip-bin cron sharutils \
        postgresql-client && \
    apt-get -y autoremove && \
    rm -rf /var/lib/apt/lists/* && \
    # Non-root hardening: drop setuid/setgid bits (su, passwd, mount, crontab, unix_chkpwd...).
    # The images are meant to run as a non-root UID, where these binaries only serve privilege escalation;
    # root (derived image builds) does not need them. Packages installed later in derived images may add them back
    find / -xdev -type f -perm /6000 -exec chmod a-s {} +

# Python packages, from the build stage's wheels only (no compiler here).
# GDAL is not installed: the bindings in the venv are built against the GDAL in /opt/geosgb.
# pyarrow is removed: it needs numpy >= 2 and is not used; Arrow/Parquet stay available through GDAL's
# drivers, which use the Arrow C++ libraries in /opt/geosgb/lib, not pyarrow
RUN --mount=type=bind,from=build,source=/wheels,target=/wheels \
    pip uninstall -y pyarrow && \
    pip install --no-cache-dir --no-index --find-links /wheels \
        "uWSGI==${UWSGI_VERSION}" \
        "psycopg2==${PSYCOPG2_VERSION}" \
        "invoke==${INVOKE_VERSION}" \
        "sherlock==${SHERLOCK_VERSION}" \
        "numpy==${NUMPY_VERSION}" \
        certifi && \
    pip check && \
    # upstream path compatibility
    ln -s "${VIRTUAL_ENV}" /usr/src/venv && \
    # entrypoint.sh in existing GeoNode projects calls /usr/local/bin/invoke
    ln -s "$(command -v invoke)" /usr/local/bin/invoke && \
    mkdir -p /usr/src/geonode && \
    # the compiled packages must find all their libraries
    uwsgi --version && \
    python -c "import psycopg2; print('psycopg2', psycopg2.__version__, '/ libpq', psycopg2.__libpq_version__)" && \
    # the GDAL bindings must load, match the GDAL library and work with this numpy
    python -c "from osgeo import gdal, gdal_array; import numpy, sys; v = gdal.__version__; r = gdal.VersionInfo('RELEASE_NAME'); print('GDAL', v, '/ lib', r, '/ numpy', numpy.__version__); sys.exit(v != r)" && \
    # GDAL's Arrow/Parquet drivers (independent of pyarrow)
    python -c "from osgeo import ogr; import sys; sys.exit(not all(ogr.GetDriverByName(d) for d in ('Arrow', 'Parquet')))"

WORKDIR /usr/src/geonode

COPY LICENSE /usr/share/doc/geonode-base/

# the base this image was built on: its tags (<version>, and the dated one) do not say
ARG GDAL_IMAGE_PY
ARG GEONODE_VERSION
# every key, or the labels of the ndscprm/gdal base would show through; created and revision are set by the CI,
# for each build
LABEL org.opencontainers.image.title="GeoNode base" \
      org.opencontainers.image.description="Imagem base do GeoNode para instâncias do SGB, sobre GDAL e Python" \
      org.opencontainers.image.version="${GEONODE_VERSION}" \
      org.opencontainers.image.vendor="SGB/CPRM" \
      org.opencontainers.image.authors="Carlos Eduardo Mota <carlos.mota@sgb.gov.br>" \
      org.opencontainers.image.licenses="GPL-3.0" \
      org.opencontainers.image.url="https://hub.docker.com/r/ndscprm/geonode-base" \
      org.opencontainers.image.documentation="https://github.com/nds-cprm/geonode-base#readme" \
      org.opencontainers.image.source="https://github.com/nds-cprm/geonode-base" \
      org.opencontainers.image.base.name="${GDAL_IMAGE_PY}"

SHELL ["/bin/sh", "-c"]
