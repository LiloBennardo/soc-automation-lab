#!/bin/bash
# ============================================================
# SOC Automation Lab — Script de déploiement complet
# Usage : ./deploy.sh
# ============================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
CERTS_DIR="$SCRIPT_DIR/config/wazuh_indexer_ssl_certs"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
info() { echo -e "${BLUE}[→]${NC} $1"; }

echo ""
echo "  ╔══════════════════════════════════════════╗"
echo "  ║        SOC Automation Lab Deploy         ║"
echo "  ║   Wazuh SIEM + Shuffle SOAR + TheHive    ║"
echo "  ╚══════════════════════════════════════════╝"
echo ""

# ------------------------------------------------------------
# 1. Vérifications préalables
# ------------------------------------------------------------
info "Vérification des prérequis..."

command -v docker >/dev/null 2>&1 || err "Docker non trouvé. Installe Docker Desktop avec WSL2 backend."
command -v git    >/dev/null 2>&1 || err "Git non trouvé."

# Vérifier que Docker est démarré
docker info >/dev/null 2>&1 || err "Le daemon Docker n'est pas démarré. Lance Docker Desktop."

log "Docker OK ($(docker --version | awk '{print $3}' | tr -d ','))"

# ------------------------------------------------------------
# 2. Vérifier / créer le fichier .env
# ------------------------------------------------------------
if [ ! -f "$ENV_FILE" ]; then
    warn "Fichier .env absent. Création depuis .env.example..."
    cp "$SCRIPT_DIR/.env.example" "$ENV_FILE"
    warn "IMPORTANT : Édite $ENV_FILE avec tes mots de passe avant de continuer."
    warn "Relance ce script après configuration."
    exit 1
fi

# Charger les variables
source "$ENV_FILE"

# Vérifier les variables obligatoires
for var in INDEXER_PASSWORD API_PASSWORD DASHBOARD_PASSWORD THEHIVE_SECRET SHUFFLE_OPENSEARCH_PASSWORD SHUFFLE_HOST_IP; do
    val="${!var}"
    if [ -z "$val" ] || [[ "$val" == ChangeMe* ]]; then
        err "Variable $var non configurée dans .env. Remplace la valeur par défaut."
    fi
done

log "Variables d'environnement OK"

# ------------------------------------------------------------
# 3. Paramètres système
# ------------------------------------------------------------
info "Configuration système (vm.max_map_count)..."
sudo sysctl -w vm.max_map_count=262144 >/dev/null
log "vm.max_map_count=262144"

# ------------------------------------------------------------
# 4. Cloner les repos nécessaires (si absents)
# ------------------------------------------------------------
info "Vérification des dépôts..."

# wazuh-docker (pour la génération des certificats SSL)
if [ ! -d "$HOME/wazuh-docker" ]; then
    info "Clonage wazuh-docker..."
    git clone --depth 1 --branch v4.9.2 https://github.com/wazuh/wazuh-docker.git "$HOME/wazuh-docker"
    log "wazuh-docker cloné"
else
    log "wazuh-docker déjà présent"
fi

# Shuffle
if [ ! -d "$HOME/Shuffle" ]; then
    info "Clonage Shuffle SOAR..."
    git clone --depth 1 https://github.com/Shuffle/Shuffle.git "$HOME/Shuffle"
    log "Shuffle cloné"
else
    log "Shuffle déjà présent"
fi

# ------------------------------------------------------------
# 5. Génération des certificats SSL Wazuh
# ------------------------------------------------------------
if [ ! -d "$CERTS_DIR" ] || [ -z "$(ls -A "$CERTS_DIR" 2>/dev/null)" ]; then
    info "Génération des certificats SSL Wazuh..."
    mkdir -p "$CERTS_DIR"

    cd "$HOME/wazuh-docker/single-node"
    docker compose -f generate-indexer-certs.yml run --rm generator
    log "Certificats générés dans $HOME/wazuh-docker/single-node/config/wazuh_indexer_ssl_certs/"

    # Copier les certs vers notre répertoire
    cp "$HOME/wazuh-docker/single-node/config/wazuh_indexer_ssl_certs/"* "$CERTS_DIR/"
    log "Certificats copiés dans $CERTS_DIR"
    cd "$SCRIPT_DIR"
else
    log "Certificats SSL déjà présents"
fi

# ------------------------------------------------------------
# 6. Substitution dynamique de l'IP WSL2 dans ossec.conf
# ------------------------------------------------------------
info "Mise à jour de l'IP Shuffle dans ossec.conf..."

# Obtenir l'IP WSL2 actuelle
CURRENT_WSL_IP=$(ip addr show eth0 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)

if [ -n "$CURRENT_WSL_IP" ]; then
    SHUFFLE_IP="$CURRENT_WSL_IP"
    info "IP WSL2 détectée automatiquement : $SHUFFLE_IP"
else
    SHUFFLE_IP="${SHUFFLE_HOST_IP}"
    warn "IP WSL2 non détectée, utilisation de SHUFFLE_HOST_IP=$SHUFFLE_IP depuis .env"
fi

OSSEC_CONF="$SCRIPT_DIR/config/ossec.conf"
OSSEC_RUNTIME="/tmp/ossec.conf.runtime"

# Créer une copie avec les vraies valeurs (ne jamais modifier l'original)
sed -e "s/SHUFFLE_HOST_IP/$SHUFFLE_IP/g" \
    -e "s/SHUFFLE_PORT/${FRONTEND_PORT:-3001}/g" \
    -e "s/SHUFFLE_WEBHOOK_GENERAL/${SHUFFLE_WEBHOOK_GENERAL}/g" \
    -e "s/SHUFFLE_WEBHOOK_VIRUSTOTAL/${SHUFFLE_WEBHOOK_VIRUSTOTAL}/g" \
    "$OSSEC_CONF" > "$OSSEC_RUNTIME"

log "ossec.conf configuré (IP: $SHUFFLE_IP, port: ${FRONTEND_PORT:-3001})"

# ------------------------------------------------------------
# 7. Préparer les volumes Shuffle
# ------------------------------------------------------------
info "Création des dossiers Shuffle..."
mkdir -p "${SHUFFLE_APP_HOTLOAD_LOCATION:-/tmp/shuffle-apps}"
mkdir -p "${SHUFFLE_FILE_LOCATION:-/tmp/shuffle-files}"
mkdir -p "${DB_LOCATION:-/tmp/shuffle-database}"
log "Dossiers Shuffle OK"

# Copier le .env pour Shuffle
cp "$ENV_FILE" "$HOME/Shuffle/.env" 2>/dev/null || true

# ------------------------------------------------------------
# 8. Démarrer Wazuh
# ------------------------------------------------------------
info "Démarrage Wazuh SIEM (Manager + Indexer + Dashboard)..."
cd "$SCRIPT_DIR/docker"

# Injecter les variables d'env dans le compose
export $(grep -v '^#' "$ENV_FILE" | xargs) 2>/dev/null || true

docker compose -f wazuh-docker-compose.yml up -d

log "Wazuh démarré"

# ------------------------------------------------------------
# 9. Attendre que Wazuh soit prêt
# ------------------------------------------------------------
info "Attente démarrage Wazuh Indexer (90s max)..."
for i in $(seq 1 18); do
    if curl -sk -o /dev/null -w "%{http_code}" "https://localhost:9200" -u "admin:${INDEXER_PASSWORD}" | grep -q "200\|401"; then
        log "Wazuh Indexer accessible"
        break
    fi
    echo -n "."
    sleep 5
done
echo ""

# ------------------------------------------------------------
# 10. Démarrer Shuffle
# ------------------------------------------------------------
info "Démarrage Shuffle SOAR..."
cd "$HOME/Shuffle"
docker compose up -d
log "Shuffle démarré"

# ------------------------------------------------------------
# 11. Démarrer TheHive
# ------------------------------------------------------------
info "Démarrage TheHive IRP..."
cd "$SCRIPT_DIR/docker"
docker compose -f thehive-docker-compose.yml up -d
log "TheHive démarré"

# ------------------------------------------------------------
# 12. Résumé
# ------------------------------------------------------------
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║              LAB SOC DÉPLOYÉ AVEC SUCCÈS             ║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║${NC}  Wazuh Dashboard  : ${BLUE}https://localhost${NC}"
echo -e "${GREEN}║${NC}    └─ Login       : admin / \$INDEXER_PASSWORD"
echo -e "${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  Shuffle SOAR     : ${BLUE}http://localhost:${FRONTEND_PORT:-3001}${NC}"
echo -e "${GREEN}║${NC}    └─ Créer compte au premier accès"
echo -e "${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  TheHive IRP      : ${BLUE}http://localhost:9000${NC}"
echo -e "${GREEN}║${NC}    └─ Login       : admin@thehive.local / secret"
echo -e "${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  IP WSL2 (Shuffle): ${BLUE}$SHUFFLE_IP${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
warn "Attends 2-3 minutes que tous les services soient pleinement initialisés."
echo ""
