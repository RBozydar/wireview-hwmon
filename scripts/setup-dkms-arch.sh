#!/usr/bin/env bash
set -euo pipefail

if [[ ${TRACE:-0} == 1 ]]; then
    set -x
fi

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd -- "${SCRIPT_DIR}/.." && pwd)

PACKAGE_NAME=$(sed -n 's/^PACKAGE_NAME="\([^"]*\)"/\1/p' "${REPO_DIR}/dkms.conf")
PACKAGE_VERSION=$(sed -n 's/^PACKAGE_VERSION="\([^"]*\)"/\1/p' "${REPO_DIR}/dkms.conf")
MODULE_NAME=$(sed -n 's/^BUILT_MODULE_NAME\[0\]="\([^"]*\)"/\1/p' "${REPO_DIR}/dkms.conf")

MOK_KEY=${MOK_KEY:-/var/lib/shim-signed/mok/MOK.priv}
MOK_CERT=${MOK_CERT:-/var/lib/shim-signed/mok/MOK.der}
DKMS_SIGNING_CONF=${DKMS_SIGNING_CONF:-/etc/dkms/framework.conf.d/wireview-hwmon-signing.conf}
CURRENT_KERNEL=${CURRENT_KERNEL:-$(uname -r)}
SOURCE_DIR="/usr/src/${PACKAGE_NAME}-${PACKAGE_VERSION}"

require_command() {
    local cmd
    for cmd in "$@"; do
        if ! command -v "${cmd}" >/dev/null 2>&1; then
            echo "Missing required command: ${cmd}" >&2
            exit 1
        fi
    done
}

if [[ -z "${PACKAGE_NAME}" || -z "${PACKAGE_VERSION}" || -z "${MODULE_NAME}" ]]; then
    echo "Failed to parse dkms.conf in ${REPO_DIR}" >&2
    exit 1
fi

require_command dkms rsync modprobe depmod install find sed systemctl uname modinfo

if [[ ! -f "${MOK_KEY}" || ! -f "${MOK_CERT}" ]]; then
    echo "Signing key or certificate not found." >&2
    echo "Expected:" >&2
    echo "  ${MOK_KEY}" >&2
    echo "  ${MOK_CERT}" >&2
    exit 1
fi

if [[ ${EUID} -ne 0 ]]; then
    exec sudo --preserve-env=MOK_KEY,MOK_CERT,DKMS_SIGNING_CONF,CURRENT_KERNEL,TRACE "$0" "$@"
fi

mapfile -t INSTALLED_KERNELS < <(
    find /usr/lib/modules -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort
)

if [[ ${#INSTALLED_KERNELS[@]} -eq 0 ]]; then
    echo "No installed kernels found under /usr/lib/modules" >&2
    exit 1
fi

echo "Configuring DKMS signing"
install -d /etc/dkms/framework.conf.d
cat >"${DKMS_SIGNING_CONF}" <<EOF
mok_signing_key=${MOK_KEY}
mok_certificate=${MOK_CERT}
try_sign_modules=true
EOF

echo "Syncing source to ${SOURCE_DIR}"
rm -rf "${SOURCE_DIR}"
mkdir -p "${SOURCE_DIR}"
rsync -a \
    --exclude .git \
    --exclude .codex \
    --exclude scripts/setup-dkms-arch.sh \
    "${REPO_DIR}/" "${SOURCE_DIR}/"
install -d "${SOURCE_DIR}/scripts"
install -m 755 "${SCRIPT_DIR}/setup-dkms-arch.sh" "${SOURCE_DIR}/scripts/setup-dkms-arch.sh"

echo "Refreshing DKMS registration"
dkms remove -m "${PACKAGE_NAME}" -v "${PACKAGE_VERSION}" --all >/dev/null 2>&1 || true
dkms add -m "${PACKAGE_NAME}" -v "${PACKAGE_VERSION}"

for kernelver in "${INSTALLED_KERNELS[@]}"; do
    if [[ ! -d "/usr/lib/modules/${kernelver}/build" ]]; then
        continue
    fi

    echo "Installing ${PACKAGE_NAME}/${PACKAGE_VERSION} for kernel ${kernelver}"
    dkms install -m "${PACKAGE_NAME}" -v "${PACKAGE_VERSION}" -k "${kernelver}" --force

    find "/usr/lib/modules/${kernelver}/updates" \
        -maxdepth 1 \
        -type f \
        \( -name "${MODULE_NAME}.ko" -o -name "${MODULE_NAME}.ko.zst" \) \
        -delete

    depmod -a "${kernelver}"
done

echo "Ensuring boot-time autoload"
install -d /etc/modules-load.d
printf '%s\n' "${MODULE_NAME}" >/etc/modules-load.d/wireview-hwmon.conf

echo "Reloading module and daemon for ${CURRENT_KERNEL}"
systemctl stop wireviewd || true
modprobe -r "${MODULE_NAME}" || true
modprobe "${MODULE_NAME}"
systemctl enable --now wireviewd

echo
echo "Verification"
dkms status -m "${PACKAGE_NAME}" -v "${PACKAGE_VERSION}" || true
echo "Module path: $(modinfo -n "${MODULE_NAME}")"
modinfo "$(modinfo -n "${MODULE_NAME}")" | rg 'signer|sig_hashalgo' || true
systemctl --no-pager --full status wireviewd || true
