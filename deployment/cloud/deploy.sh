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

if ! git pull --ff-only origin main; then
    echo "[deploy] nada a atualizar ou conflito (mantendo versão atual)"
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
