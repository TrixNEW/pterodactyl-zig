#!/bin/bash
set -euo pipefail

cd /home/container

if [[ -n ${STARTUP:-} ]]; then
    startup=${STARTUP//\{\{/\$\{}
    startup=${startup//\}\}/\}}
    exec /bin/bash --noprofile --norc -e -o pipefail -c "
trap 'exit 143' TERM
trap 'exit 130' INT
$startup"
fi

exec "$@"
