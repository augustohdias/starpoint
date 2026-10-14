#!/usr/bin/env bash
# Starpoint CD — simples: pull da main + restart.
# Uso:  ./deploy.sh          (force update manual)
#       systemd timer        (diário 09:30 America/Sao_Paulo)
# O build (out/) já vem commitado na main — a VM não compila (1GB RAM).
# Migrations: rodam automaticamente no boot do servidor.
set -uo pipefail

cd "$(dirname "$(readlink -f "$0")")/../.."   # raiz do repo
SUDO=""
[[ $EUID -ne 0 ]] && SUDO="sudo"

echo "[deploy] $(date '+%F %T') — atualizando"

# fetch + reset --hard em vez de pull: imune a conflitos com arquivos
# untracked (ex.: mods pré-existentes) e não derruba o worktree no meio.
git fetch origin main -q
BEFORE=$(git rev-parse HEAD)
git reset --hard origin/main -q
if [[ "$BEFORE" == "$(git rev-parse HEAD)" ]]; then
    echo "[deploy] fonte sem mudanças"
else
    echo "[deploy] atualizado: $(git log --oneline -1 | head -c 60)"
fi

echo "[deploy] reiniciando serviço"
$SUDO systemctl restart starpoint
sleep 5

if systemctl is-active --quiet starpoint; then
    echo "[deploy] OK — $(git log --oneline -1 | head -c 50)"
else
    echo "[deploy] FALHA — serviço não subiu:"
    $SUDO journalctl -u starpoint -n 8 --no-pager | tail -8
    exit 1
fi
