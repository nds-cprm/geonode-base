#!/bin/sh
# Smoke test of the image, run by the CI on the native runner of each architecture (and locally:
# DOCKER=podman .github/scripts/smoke-test.sh <image>). The image is a base for the GeoNode image, with no
# application of its own: it checks the image configuration, then starts a container as the derived images
# run in production (arbitrary UID, read-only root filesystem with a writable /tmp) and checks the nss_wrapper
# of the base, the Python environment GeoNode builds on (GDAL bindings, numpy, psycopg2, uWSGI, invoke),
# libmagic, the PostgreSQL client, the hardening (no setuid/setgid files, no compiler) and that only /tmp is
# writable. The GDAL and Python versions must be those of the ARGs of the Dockerfile, which make the image tag:
# the CI builds on the base images gdal-oci passes, so a new GDAL or Python there fails here, before any tag.
set -eu

IMAGE=${1:?usage: $0 <image>}
DOCKER=${DOCKER:-docker}

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

DOCKERFILE=$(dirname "$0")/../../Dockerfile
GDAL_VERSION=$(sed -nE 's/^ARG GDAL_VERSION=([0-9]+\.[0-9]+\.[0-9]+)$/\1/p' "$DOCKERFILE")
PYTHON_VERSION=$(sed -nE 's/^ARG PYTHON_VERSION=([0-9]+\.[0-9]+)$/\1/p' "$DOCKERFILE")
[ -n "$GDAL_VERSION" ] && [ -n "$PYTHON_VERSION" ] \
    || fail "no lines ARG GDAL_VERSION=X.Y.Z and ARG PYTHON_VERSION=X.Y in $DOCKERFILE"

# no USER on purpose: the GeoNode Dockerfile still runs apt-get after FROM, and sets the USER of the final image
echo "## image configuration"
[ -z "$("$DOCKER" image inspect "$IMAGE" --format '{{.Config.User}}')" ] || fail "the base image must not set USER"
[ "$("$DOCKER" image inspect "$IMAGE" --format '{{.Config.WorkingDir}}')" = /usr/src/geonode ] \
    || fail "WORKDIR is not /usr/src/geonode"
[ "$("$DOCKER" image inspect "$IMAGE" --format '{{join .Config.Entrypoint " "}}')" = /docker-entrypoint.sh ] \
    || fail "ENTRYPOINT is not the /docker-entrypoint.sh of the base image"
version=$("$DOCKER" image inspect "$IMAGE" --format '{{index .Config.Labels "org.opencontainers.image.version"}}')
[ "$version" = "${GDAL_VERSION}-py${PYTHON_VERSION}" ] \
    || fail "label org.opencontainers.image.version is '$version', not ${GDAL_VERSION}-py${PYTHON_VERSION}"

# Podman adds the UID to /etc/passwd by default, so the nss_wrapper of the base image would not be used;
# --passwd=false keeps the passwd of the image, as Docker and OpenShift do.
# Podman also fills a --tmpfs with what the image has at that path, unless notmpcopyup is given
RUN_ARGS=
TMPFS_OPTS=
if "$DOCKER" --version | grep -qi podman; then
    RUN_ARGS=--passwd=false
    TMPFS_OPTS=:notmpcopyup
fi

echo "## container (--user 12345:0, --read-only, --tmpfs /tmp)"
# shellcheck disable=SC2086
"$DOCKER" run --rm -i --user 12345:0 --read-only --tmpfs "/tmp$TMPFS_OPTS" --cap-drop ALL \
    --security-opt no-new-privileges $RUN_ARGS -e ENTRYPOINT_QUIET_LOGS=1 \
    -e EXPECTED_GDAL="$GDAL_VERSION" -e EXPECTED_PYTHON="$PYTHON_VERSION" "$IMAGE" bash -s << 'EOF' \
    || fail "container checks"
set -euo pipefail

check() {
    echo "### $1"
}

check "nss_wrapper (10-enable-nss-wrapper.sh)"
[ "$(id -un)" = sgb ] || { echo "user is '$(id -un)', not sgb" >&2; exit 1; }
[ "$HOME" = /tmp ] || { echo "HOME is '$HOME', not /tmp" >&2; exit 1; }
id

check "paths and commands expected by GeoNode"
[ "$(readlink /usr/src/venv)" = "$VIRTUAL_ENV" ] || { echo "/usr/src/venv is not a link to $VIRTUAL_ENV" >&2; exit 1; }
/usr/local/bin/invoke --version
uwsgi --version
for c in psql pg_dump pg_restore gdalinfo ogr2ogr msgfmt git curl unzip zip file ps; do
    command -v "$c" > /dev/null || { echo "missing command: $c" >&2; exit 1; }
done

check "Python environment"
pip check
python - << 'PY'
import ctypes
import ctypes.util
import importlib.util
import os
import sys

import numpy
import psycopg2
from osgeo import gdal, gdal_array, ogr  # noqa: F401 (gdal_array needs numpy)

failed = False


def error(message):
    global failed
    print(message, file=sys.stderr)
    failed = True


# the versions of the tag (ARGs of the Dockerfile)
expected_gdal = os.environ['EXPECTED_GDAL']
expected_python = os.environ['EXPECTED_PYTHON']
python = f'{sys.version_info.major}.{sys.version_info.minor}'
print('Python', sys.version.split()[0], '/ expected', expected_python, '| GDAL expected', expected_gdal)
if python != expected_python:
    error(f'Python {python} is not the PYTHON_VERSION of the Dockerfile ({expected_python})')
if gdal.VersionInfo('RELEASE_NAME') != expected_gdal:
    error(f"GDAL {gdal.VersionInfo('RELEASE_NAME')} is not the GDAL_VERSION of the Dockerfile ({expected_gdal})")

print('GDAL', gdal.__version__, '/ lib', gdal.VersionInfo('RELEASE_NAME'), '/ numpy', numpy.__version__)
if gdal.__version__ != gdal.VersionInfo('RELEASE_NAME'):
    error('the GDAL bindings do not match the GDAL library')
# GeoNode pins numpy 1.x; pyarrow (numpy >= 2) is removed from the base venv
if not numpy.__version__.startswith('1.'):
    error(f'numpy {numpy.__version__} is not 1.x')
if importlib.util.find_spec('pyarrow'):
    error('pyarrow is installed')
for name in ('Arrow', 'Parquet', 'GPKG', 'ESRI Shapefile', 'KML', 'LIBKML', 'GeoJSON', 'CSV', 'GTiff', 'PostgreSQL'):
    if not ogr.GetDriverByName(name) and not gdal.GetDriverByName(name):
        error(f'GDAL driver missing: {name}')

# psycopg2 compiled against the system libpq (not psycopg2-binary, which bundles its own)
print('psycopg2', psycopg2.__version__, '/ libpq', psycopg2.__libpq_version__)
loaded = sorted({line.split()[-1] for line in open('/proc/self/maps') if '.so' in line.split()[-1]})
libpq = [path for path in loaded if '/libpq' in path]
print('libpq loaded:', ', '.join(libpq))
if not libpq or any('.libs/' in path for path in libpq):
    error('psycopg2 does not use the libpq of the system')

# python-magic (GeoNode's FileValidationUploadHandler) loads libmagic through ctypes
magic = ctypes.util.find_library('magic')
print('libmagic:', magic)
if not magic:
    error('libmagic not found')
else:
    ctypes.CDLL(magic)
sys.exit(failed)
PY

check "PostgreSQL client and libpq of the same major"
libpq=$(python -c 'import psycopg2; print(psycopg2.__libpq_version__ // 10000)')
psql_major=$(psql --version | sed -E 's/^psql \(PostgreSQL\) ([0-9]+).*/\1/')
echo "psql $psql_major / libpq $libpq"
[ "$psql_major" = "$libpq" ] || { echo "psql $psql_major and libpq $libpq differ" >&2; exit 1; }

check "GDAL writes to /tmp, nothing else is writable"
echo '{"type":"FeatureCollection","features":[{"type":"Feature","properties":{"n":1},"geometry":{"type":"Point","coordinates":[-43.2,-22.9]}}]}' \
    | ogr2ogr -f GPKG /tmp/smoke.gpkg /vsistdin/
file --brief --mime-type /tmp/smoke.gpkg
for dir in /usr/src/geonode "$VIRTUAL_ENV" /var/log /etc; do
    if touch "$dir/.smoke-test" 2> /dev/null; then
        echo "$dir is writable on a read-only root filesystem" >&2
        exit 1
    fi
done

check "hardening"
setid=$(find / -xdev -type f -perm /6000 2> /dev/null || :)
[ -z "$setid" ] || { echo "setuid/setgid files: $setid" >&2; exit 1; }
for c in gcc cc g++ make; do
    if command -v "$c" > /dev/null; then
        echo "compiler in the image: $c" >&2
        exit 1
    fi
done
EOF

echo "OK"
