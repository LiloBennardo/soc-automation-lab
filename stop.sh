#!/bin/bash

echo "🛑 Arrêt du lab SOC..."

cd ~/thehive && docker compose down
cd ~/Shuffle && docker compose down
cd ~/wazuh-docker/single-node && docker compose down

echo "✅ Tous les services arrêtés."
