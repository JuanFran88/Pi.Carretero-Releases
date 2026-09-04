#!/bin/bash

set -Eeuo pipefail

readonly APP_NAME="Pi.Carretero"
readonly INSTALL_ROOT="/opt/pi-carretero"
readonly MANIFEST_URL="https://raw.githubusercontent.com/JuanFran88/Pi.Carretero-Releases/main/latest.json"

CHECK_ONLY=false
TEMP_DIR=""

log() {
    printf '\n==> %s\n' "$*"
}

ok() {
    printf 'OK: %s\n' "$*"
}

warn() {
    printf 'AVISO: %s\n' "$*" >&2
}

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    if [[ -n "${TEMP_DIR}" && -d "${TEMP_DIR}" ]]; then
        rm -rf "${TEMP_DIR}"
    fi
}

trap cleanup EXIT

usage() {
    cat <<'USAGE'
Instalador público de Pi.Carretero Backend.

Uso:

  ./install.sh
  ./install.sh --check
  ./install.sh --help

Opciones:

  --check    Descarga y valida la última versión estable sin modificar
             el sistema ni ejecutar el instalador.

  -h,
  --help     Muestra esta ayuda.

Instalación rápida:

  curl -fsSL https://raw.githubusercontent.com/JuanFran88/Pi.Carretero-Releases/main/install.sh | bash
USAGE
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --check)
                CHECK_ONLY=true
                shift
                ;;

            -h|--help)
                usage
                exit 0
                ;;

            *)
                fail "Opción desconocida: $1"
                ;;
        esac
    done
}

require_command() {
    local command_name="$1"

    command -v "${command_name}" >/dev/null 2>&1 \
        || fail "Falta el comando requerido: ${command_name}"
}

check_commands() {
    log "Comprobando herramientas necesarias"

    local commands=(
        bash
        curl
        grep
        sed
        sha256sum
        tar
        mktemp
    )

    local command_name

    for command_name in "${commands[@]}"; do
        require_command "${command_name}"
    done

    if [[ "${CHECK_ONLY}" == false ]]; then
        require_command sudo
    fi

    ok "Herramientas necesarias disponibles."
}

json_string_value() {
    local key="$1"
    local file="$2"

    sed -nE \
        "s/^[[:space:]]*\"${key}\"[[:space:]]*:[[:space:]]*\"([^\"]*)\"[[:space:]]*,?[[:space:]]*$/\\1/p" \
        "${file}" \
        | head -n 1
}

download_manifest() {
    local manifest_file="$1"

    log "Consultando última versión estable"

    curl \
        --fail \
        --silent \
        --show-error \
        --location \
        --retry 3 \
        --connect-timeout 15 \
        "${MANIFEST_URL}" \
        --output "${manifest_file}"

    [[ -s "${manifest_file}" ]] \
        || fail "El manifiesto descargado está vacío."

    ok "Manifiesto descargado."
}

read_manifest() {
    local manifest_file="$1"

    PRODUCT="$(json_string_value "product" "${manifest_file}")"
    COMPONENT="$(json_string_value "component" "${manifest_file}")"
    VERSION="$(json_string_value "version" "${manifest_file}")"
    CHANNEL="$(json_string_value "channel" "${manifest_file}")"
    ARTIFACT_URL="$(json_string_value "artifact_url" "${manifest_file}")"
    EXPECTED_SHA256="$(json_string_value "sha256" "${manifest_file}")"

    [[ "${PRODUCT}" == "${APP_NAME}" ]] \
        || fail "Producto inesperado en latest.json: ${PRODUCT:-vacío}"

    [[ "${COMPONENT}" == "backend" ]] \
        || fail "Componente inesperado en latest.json: ${COMPONENT:-vacío}"

    [[ "${CHANNEL}" == "stable" ]] \
        || fail "El manifiesto no apunta al canal estable."

    [[ -n "${VERSION}" ]] \
        || fail "El manifiesto no contiene una versión válida."

    [[ "${ARTIFACT_URL}" == https://* ]] \
        || fail "La URL del artefacto no es HTTPS."

    [[ "${EXPECTED_SHA256}" =~ ^[0-9A-Fa-f]{64}$ ]] \
        || fail "El SHA-256 publicado no es válido."

    ok "Versión estable detectada: ${VERSION}"
}

download_artifact() {
    local artifact_file="$1"

    log "Descargando Pi.Carretero Backend ${VERSION}"

    curl \
        --fail \
        --silent \
        --show-error \
        --location \
        --retry 3 \
        --connect-timeout 15 \
        "${ARTIFACT_URL}" \
        --output "${artifact_file}"

    [[ -s "${artifact_file}" ]] \
        || fail "El paquete descargado está vacío."

    ok "Backend ${VERSION} descargado."
}

verify_sha256() {
    local artifact_file="$1"

    log "Verificando integridad SHA-256"

    local actual_sha256

    actual_sha256="$(
        sha256sum "${artifact_file}" \
            | awk '{print $1}'
    )"

    [[ "${actual_sha256,,}" == "${EXPECTED_SHA256,,}" ]] \
        || fail "El SHA-256 del paquete no coincide con el publicado."

    ok "SHA-256 correcto."
}

verify_archive() {
    local artifact_file="$1"
    local archive_list="${TEMP_DIR}/archive-contents.txt"

    log "Validando estructura del paquete"

    tar -tzf "${artifact_file}" > "${archive_list}" \
        || fail "No se ha podido leer la estructura del paquete."

    [[ -s "${archive_list}" ]] \
        || fail "El paquete no contiene archivos."

    if grep -Eq '(^/|(^|/)\.\.(/|$))' "${archive_list}"; then
        fail "El paquete contiene rutas no seguras."
    fi

    grep -Fxq 'installer/install.sh' "${archive_list}" \
        || fail "El paquete no contiene installer/install.sh."

    grep -Fxq 'backend/main.py' "${archive_list}" \
        || fail "El paquete no contiene backend/main.py."

    grep -Fxq 'backend/requirements.txt' "${archive_list}" \
        || fail "El paquete no contiene backend/requirements.txt."

    ok "Estructura del paquete correcta."
}

check_existing_installation() {
    if [[ -e "${INSTALL_ROOT}" ]]; then
        fail "Ya existe ${INSTALL_ROOT}. Este comando es solo para una primera instalación. Usa el sistema de actualización de Pi.Carretero para actualizar una instalación existente."
    fi
}

install_backend() {
    local artifact_file="$1"

    check_existing_installation

    if [[ "${EUID}" -eq 0 ]]; then
        fail "No ejecutes este bootstrap directamente como root. Ejecútalo con tu usuario normal; el instalador solicitará sudo cuando sea necesario."
    fi

    log "Preparando ${INSTALL_ROOT}"

    sudo install \
        -d \
        -o root \
        -g root \
        -m 0755 \
        "${INSTALL_ROOT}"

    log "Extrayendo Pi.Carretero Backend ${VERSION}"

    sudo tar \
        -xzf "${artifact_file}" \
        -C "${INSTALL_ROOT}"

    sudo chmod \
        0755 \
        "${INSTALL_ROOT}/installer/install.sh"

    ok "Backend preparado en ${INSTALL_ROOT}."

    log "Iniciando instalador de Pi.Carretero"

    sudo "${INSTALL_ROOT}/installer/install.sh"

    ok "Instalación de Pi.Carretero Backend finalizada."
}

main() {
    parse_arguments "$@"

    printf '%s\n' "Pi.Carretero Backend - Instalador público"

    check_commands

    TEMP_DIR="$(mktemp -d)"

    local manifest_file="${TEMP_DIR}/latest.json"
    local artifact_file="${TEMP_DIR}/pi-carretero-backend.tar.gz"

    download_manifest "${manifest_file}"
    read_manifest "${manifest_file}"
    download_artifact "${artifact_file}"
    verify_sha256 "${artifact_file}"
    verify_archive "${artifact_file}"

    if [[ "${CHECK_ONLY}" == true ]]; then
        echo
        ok "Comprobación finalizada."
        printf '%s\n' "Versión validada: ${VERSION}"
        printf '%s\n' "No se ha modificado el sistema."
        exit 0
    fi

    install_backend "${artifact_file}"
}

main "$@"
