#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

log() {
  printf '\n[%s] %s\n' "$(date -Is)" "$*"
}

die() {
  printf '\n[ERROR] %s\n' "$*" >&2
  exit 1
}

require_root() {
  [[ "$(id -u)" -eq 0 ]] || die "Ejecuta este script como root o con sudo."
}

install_packages() {
  local missing=0
  for cmd in git ssh ssh-keygen curl gh; do
    command -v "$cmd" >/dev/null 2>&1 || missing=1
  done
  [[ "$missing" -eq 0 ]] && return

  log "Instalando Git, OpenSSH, curl y GitHub CLI..."
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y ca-certificates curl git openssh-client gh
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y ca-certificates curl git openssh-clients gh
  elif command -v yum >/dev/null 2>&1; then
    yum install -y ca-certificates curl git openssh-clients gh
  else
    die "No pude detectar un gestor de paquetes compatible."
  fi
}

ask_repository() {
  local input
  printf '\nRepositorio privado a instalar. Ejemplo: programandoweb/gaspronal\n'
  read -rp "Repositorio (owner/repo): " input
  input="${input#https://github.com/}"
  input="${input#git@github.com:}"
  input="${input%.git}"
  input="${input%/}"
  [[ "$input" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "Repositorio inválido. Usa owner/repo."
  REPOSITORY="$input"
}

ask_target() {
  local current input
  current="$(pwd -P)"
  read -rp "Ruta destino [$current]: " input
  TARGET_DIR="${input:-$current}"
  if [[ "$TARGET_DIR" != /* ]]; then
    TARGET_DIR="$(realpath -m "$TARGET_DIR")"
  fi
}

prepare_identity() {
  local slug owner name
  owner="${REPOSITORY%%/*}"
  name="${REPOSITORY##*/}"
  slug="$(printf '%s-%s' "$owner" "$name" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9._-' '-')"

  KEY_DIR="/root/.ssh/deploy-keys/$slug"
  KEY_FILE="$KEY_DIR/id_ed25519"
  HOST_ALIAS="github-$slug"
  SSH_CONFIG="/root/.ssh/config"

  mkdir -p "$KEY_DIR" /root/.ssh
  chmod 700 /root/.ssh "$KEY_DIR"

  if [[ ! -f "$KEY_FILE" ]]; then
    log "Generando Deploy Key SSH exclusiva para $REPOSITORY..."
    ssh-keygen -q -t ed25519 -C "$slug@$(hostname)" -f "$KEY_FILE" -N ""
  fi

  chmod 600 "$KEY_FILE"
  chmod 644 "$KEY_FILE.pub"
  touch /root/.ssh/known_hosts
  chmod 600 /root/.ssh/known_hosts
  ssh-keygen -F github.com -f /root/.ssh/known_hosts >/dev/null 2>&1 || ssh-keyscan -t ed25519 github.com >> /root/.ssh/known_hosts 2>/dev/null

  if ! grep -q "^Host $HOST_ALIAS$" "$SSH_CONFIG" 2>/dev/null; then
    cat >> "$SSH_CONFIG" <<EOF

Host $HOST_ALIAS
    HostName github.com
    User git
    IdentityFile $KEY_FILE
    IdentitiesOnly yes
    StrictHostKeyChecking yes
EOF
  fi
  chmod 600 "$SSH_CONFIG"
}

authenticate_github() {
  if gh auth status --hostname github.com >/dev/null 2>&1; then
    log "GitHub CLI ya está autenticado."
    return
  fi
  log "Se requiere autenticación inicial para registrar la Deploy Key."
  printf 'GitHub mostrará un código de un solo uso.\n'
  printf 'Abre https://github.com/login/device en tu PC o celular, introduce el código y autoriza el VPS.\n\n'
  GH_BROWSER=/bin/true BROWSER=/bin/true gh auth login --hostname github.com --web
}

register_deploy_key() {
  local title public_key normalized_key existing tmp_file http_code
  title="$(basename "$TARGET_DIR")-$(hostname)"
  public_key="$(cat "$KEY_FILE.pub")"
  normalized_key="$(awk '{print $1" "$2}' "$KEY_FILE.pub")"

  log "Verificando Deploy Key en $REPOSITORY..."

  existing="$(gh api "repos/$REPOSITORY/keys" --paginate \
    --jq '.[] | [.id, .key] | @tsv' 2>/dev/null \
    | awk -F '\t' -v wanted="$normalized_key" '{
        split($2, p, " ");
        candidate=p[1]" "p[2];
        if (candidate == wanted) { print $1; exit }
      }' || true)"

  if [[ -n "$existing" ]]; then
    log "La Deploy Key ya está registrada (ID $existing)."
    return
  fi

  tmp_file="$(mktemp)"
  set +e
  gh api --method POST "repos/$REPOSITORY/keys" \
    -f "title=$title" \
    -f "key=$public_key" \
    -F "read_only=true" >"$tmp_file" 2>&1
  http_code=$?
  set -e

  if [[ "$http_code" -ne 0 ]]; then
    if grep -qiE 'Validation Failed|key is already in use|key already in use|already exists' "$tmp_file"; then
      log "GitHub indica que esta Deploy Key ya existe. Continuando."
      rm -f "$tmp_file"
      return
    fi

    cat "$tmp_file" >&2
    rm -f "$tmp_file"
    die "No fue posible registrar la Deploy Key en GitHub."
  fi

  rm -f "$tmp_file"
  log "Deploy Key de solo lectura registrada correctamente."
}

clone_or_update() {
  local remote default_branch
  remote="git@$HOST_ALIAS:$REPOSITORY.git"
  log "Preparando repositorio en $TARGET_DIR..."
  mkdir -p "$TARGET_DIR"

  if [[ -d "$TARGET_DIR/.git" ]]; then
    git -c safe.directory="$TARGET_DIR" -C "$TARGET_DIR" remote set-url origin "$remote"
    GIT_SSH_COMMAND="ssh -F $SSH_CONFIG" git -c safe.directory="$TARGET_DIR" -C "$TARGET_DIR" fetch origin
    default_branch="$(GIT_SSH_COMMAND="ssh -F $SSH_CONFIG" git ls-remote --symref "$remote" HEAD 2>/dev/null | awk '/^ref:/ {sub("refs/heads/","",$2); print $2; exit}')"
    default_branch="${default_branch:-main}"
    git -c safe.directory="$TARGET_DIR" -C "$TARGET_DIR" checkout -B "$default_branch" "origin/$default_branch"
    git -c safe.directory="$TARGET_DIR" -C "$TARGET_DIR" reset --hard "origin/$default_branch"
  else
    if [[ -n "$(find "$TARGET_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
      local backup_dir
      backup_dir="${TARGET_DIR}.backup-$(date +%Y%m%d-%H%M%S)"
      log "$TARGET_DIR no es un repositorio Git y contiene archivos."
      log "Moviendo su contenido a $backup_dir antes de clonar."
      mkdir -p "$backup_dir"
      shopt -s dotglob nullglob
      mv "$TARGET_DIR"/* "$backup_dir"/
      shopt -u dotglob nullglob
    fi
    GIT_SSH_COMMAND="ssh -F $SSH_CONFIG" git clone "$remote" "$TARGET_DIR"
  fi

  git -c safe.directory="$TARGET_DIR" -C "$TARGET_DIR" remote set-url origin "$remote"
}


fix_target_permissions() {
  local owner group

  owner="${SUDO_USER:-root}"
  if [[ "$owner" == "root" ]]; then
    group="root"
  else
    group="$(id -gn "$owner")"
  fi

  chown -R "$owner:$group" "$TARGET_DIR"
  find "$TARGET_DIR" -type d -exec chmod u+rwx,go+rx {} +
  find "$TARGET_DIR" -type f -exec chmod u+rw,go+r {} +
  chmod +x "$TARGET_DIR/scripts/bootstrap-vps.sh" 2>/dev/null || true
  chmod +x "$TARGET_DIR/scripts/deploy.sh" 2>/dev/null || true
}

run_project_bootstrap() {
  local bootstrap="$TARGET_DIR/scripts/bootstrap-vps.sh"

  [[ -f "$bootstrap" ]] || die "El repositorio fue descargado, pero no existe $bootstrap."

  chmod +x "$bootstrap"

  log "Repositorio preparado correctamente."
  log "Ejecutando inmediatamente $bootstrap ..."

  cd "$TARGET_DIR"
  bash "$bootstrap"
}

summary() {
  printf '\n============================================================\n'
  printf 'Inicialización terminada\n'
  printf 'Repositorio : %s\n' "$REPOSITORY"
  printf 'Directorio  : %s\n' "$TARGET_DIR"
  printf 'Deploy Key  : %s.pub\n' "$KEY_FILE"
  printf 'Git origin  : git@%s:%s.git\n' "$HOST_ALIAS" "$REPOSITORY"
  printf '============================================================\n'
}

main() {
  require_root
  install_packages
  ask_repository
  ask_target
  prepare_identity
  authenticate_github
  register_deploy_key
  clone_or_update
  fix_target_permissions
  run_project_bootstrap
  fix_target_permissions
  summary
}

main "$@"
