#!/bin/bash
set -e

echo "=== [0/4] Autorise l'utilisateur courant à exécuter des commandes sudo sans mot de passe ==="

echo "$USER ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/$USER > /dev/null

echo "=== [1/4] Préparation des disques ==="

# Mapping des disques ➜ répertoires cibles
declare -A DISK_MAP=(
  ["/dev/vdc"]="/var/opt/alfresco"     # Data
  ["/dev/vdd"]="/var/log/alfresco"     # Logs
  ["/dev/vde"]="/etc/opt/alfresco"     # Configurations
  ["/dev/vdf"]="/opt/alfresco"         # Binaries
)

# Traitement de chaque disque
for DISK in "${!DISK_MAP[@]}"; do
  MOUNT_POINT="${DISK_MAP[$DISK]}"
  echo "--> Traitement : $DISK ➜ $MOUNT_POINT"

  # Vérifie si formaté
  if ! blkid "$DISK" > /dev/null 2>&1; then
    echo "    [Formatage] mkfs.ext4 $DISK"
    sudo mkfs.ext4 "$DISK"
  else
    echo "    [OK] Déjà formaté"
  fi

  # Crée le dossier s’il n’existe pas
  sudo mkdir -p "$MOUNT_POINT"

  # Monte le disque s’il ne l’est pas déjà
  if ! mount | grep -q " $MOUNT_POINT "; then
    echo "    [Montage] $DISK ➜ $MOUNT_POINT"
    sudo mount "$DISK" "$MOUNT_POINT"
  else
    echo "    [OK] Déjà monté"
  fi

  # Ajoute à /etc/fstab
  if ! grep -q "$MOUNT_POINT" /etc/fstab; then
    echo "    [fstab] Ajout de $DISK"
    echo "$DISK $MOUNT_POINT ext4 defaults,nofail 0 0" | sudo tee -a /etc/fstab
  else
    echo "    [OK] Déjà présent dans fstab"
  fi
done

echo "=== [2/4] Installation des dépendances système ==="

# Détection OS et installation dépendances
if [ -f /etc/redhat-release ]; then
  if ! sudo subscription-manager status > /dev/null 2>&1; then
    echo "    [RHSM] Enregistrement du système..."
    sudo subscription-manager register --username <username> --password <password> --auto-attach || echo "    [INFO] Système déjà enregistré, poursuite..."
  else
    echo "    [OK] Système déjà enregistré."
  fi
  sudo dnf install -y python3.12 git
elif [ -f /etc/lsb-release ]; then
  sudo apt update && sudo apt install -y python3.12 git
else
  echo "Système non reconnu, installation manuelle requise."
  exit 1
fi

echo "=== [3/4] Clonage du dépôt d'installation Heritage ECM ==="

if [ -d "heritage-ecm-ansible-deployment" ]; then
  echo "    [INFO] Le dossier existe déjà. Suppression..."
  rm -rf heritage-ecm-ansible-deployment
fi

git clone https://github.com/bambandouraccel/heritage-ecm-ansible-deployment.git
cd heritage-ecm-ansible-deployment

echo "=== [4/4] Exécution du playbook Ansible ==="

# === [Préparation de l'environnement Python/Ansible] ===

# Installation Python et pip pour RHEL/CentOS/Fedora
sudo dnf update -y
sudo dnf install -y python3.12 python3.12-pip

# Création et activation de l'environnement virtuel
python3.12 -m venv venv
source venv/bin/activate

# Mise à jour de pip et installation de pipenv
sudo dnf update -y
sudo dnf install -y python3.12 python3.12-pip
sudo python3 -m pip install --upgrade pip
pip install --upgrade pip
pip install pipenv

# Installation des dépendances Python via pipenv
pipenv install --deploy
pipenv run ansible-galaxy install -r requirements.yml

# Vérifie et corrige pour root si présent
if [ -d "/root/heritage-ecm-ansible-deployment" ]; then
    echo "Correction pour root..."
    sudo chmod +x -R /root/heritage-ecm-ansible-deployment
    if [ -f "/root/heritage-ecm-ansible-deployment/scripts/generate-secret.sh" ]; then
        sudo sed -i 's/\r$//' /root/heritage-ecm-ansible-deployment/scripts/generate-secret.sh
    else
        echo "Fichier generate-secret.sh introuvable pour root"
    fi
fi

# Vérifie et corrige pour chaque utilisateur de /home/
for dir in /home/*/heritage-ecm-ansible-deployment; do
    if [ -d "$dir" ]; then
        user=$(basename "$(dirname "$dir")")
        echo "Correction pour $user..."
        sudo chmod +x -R "$dir"
        if [ -f "$dir/scripts/generate-secret.sh" ]; then
            sudo sed -i 's/\r$//' "$dir/scripts/generate-secret.sh"
        else
            echo "Fichier generate-secret.sh introuvable pour $user"
        fi
    fi
done


# Suppression de l'invite sudo interactive
sudo echo "$USER ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/ansible-nopasswd

# Lancement sans interaction
pipenv run ansible-playbook playbooks/acs.yml \
  -i inventory_local.yml \
  -e "acs_play_repository_acs_edition=Community autogen_unsecure_secrets=yes" \
  --become

echo "=== [OK] Installation Heritage ECM terminée avec succès ==="
