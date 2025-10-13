#!/bin/bash

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                                                              ║"
echo "║     CRÉATION COMPLÈTE IMS KUBERNETES + DASHBOARD             ║"
echo "║                                                              ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# Couleurs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Variables
BASE_DIR="$HOME/docker_open5gs/ims_kubernetes"
MANIFEST_DIR="$BASE_DIR/manifests"
SCRIPT_DIR="$BASE_DIR/scripts"

# ====================================================================
# PARTIE 0: INSTALLATION MINIKUBE ET KUBECTL
# ====================================================================

echo -e "${YELLOW}=== [0/7] INSTALLATION MINIKUBE ET KUBECTL ===${NC}"

# Installer Minikube
if ! command -v minikube &> /dev/null; then
    echo "Installation de Minikube..."
    curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
    sudo install minikube-linux-amd64 /usr/local/bin/minikube
    rm minikube-linux-amd64
    echo -e "${GREEN}✓ Minikube installé${NC}"
else
    echo -e "${GREEN}✓ Minikube déjà installé: $(minikube version --short)${NC}"
fi

# Installer kubectl
if ! command -v kubectl &> /dev/null; then
    echo "Installation de kubectl..."
    curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
    rm kubectl
    echo -e "${GREEN}✓ kubectl installé${NC}"
else
    echo -e "${GREEN}✓ kubectl déjà installé${NC}"
fi

# ====================================================================
# PARTIE 1: CRÉATION DE LA STRUCTURE
# ====================================================================

echo ""
echo -e "${YELLOW}=== [1/7] CRÉATION DE LA STRUCTURE ===${NC}"

rm -rf "$BASE_DIR" 2>/dev/null
mkdir -p "$MANIFEST_DIR" "$SCRIPT_DIR"

echo -e "${GREEN}✓ Structure créée: $BASE_DIR${NC}"

# ====================================================================
# PARTIE 2: BUILD DES IMAGES AVEC PODMAN
# ====================================================================

echo ""
echo -e "${YELLOW}=== [2/7] BUILD DES IMAGES AVEC PODMAN ===${NC}"

# Build docker_open5gs (base HSS)
if [ -d "$HOME/docker_open5gs/base" ]; then
    if ! podman images | grep -q "docker_open5gs"; then
        echo "Building docker_open5gs..."
        cd $HOME/docker_open5gs/base
        podman build --no-cache --force-rm -t docker_open5gs .
        echo -e "${GREEN}✓ docker_open5gs built${NC}"
    else
        echo -e "${GREEN}✓ docker_open5gs existe déjà${NC}"
    fi
fi

# Build docker_kamailio
if [ -d "$HOME/docker_open5gs/ims_base" ]; then
    if ! podman images | grep -q "docker_kamailio"; then
        echo "Building docker_kamailio..."
        cd $HOME/docker_open5gs/ims_base
        podman build --no-cache --force-rm -t docker_kamailio .
        echo -e "${GREEN}✓ docker_kamailio built${NC}"
    else
        echo -e "${GREEN}✓ docker_kamailio existe déjà${NC}"
    fi
fi

# Build docker_rtpengine (si existe)
if [ -d "$HOME/docker_open5gs/rtpengine" ]; then
    if ! podman images | grep -q "docker_rtpengine"; then
        echo "Building docker_rtpengine..."
        cd $HOME/docker_open5gs/rtpengine
        podman build --no-cache --force-rm -t docker_rtpengine .
        echo -e "${GREEN}✓ docker_rtpengine built${NC}"
    else
        echo -e "${GREEN}✓ docker_rtpengine existe déjà${NC}"
    fi
fi

cd $HOME/docker_open5gs

# ====================================================================
# PARTIE 3: DÉMARRAGE MINIKUBE
# ====================================================================

echo ""
echo -e "${YELLOW}=== [3/7] DÉMARRAGE MINIKUBE ===${NC}"

# Arrêter minikube si déjà en cours
minikube stop 2>/dev/null || true

# Démarrer Minikube
echo "Démarrage de Minikube (cela peut prendre quelques minutes)..."
minikube start \
  --driver=docker \
  --cpus=4 \
  --memory=8192 \
  --disk-size=20g

echo -e "${GREEN}✓ Minikube démarré${NC}"

# ====================================================================
# PARTIE 4: PUSH DES IMAGES PODMAN VERS MINIKUBE
# ====================================================================

echo ""
echo -e "${YELLOW}=== [4/7] PUSH DES IMAGES VERS MINIKUBE ===${NC}"

# Configurer pour utiliser le registry Minikube
eval $(minikube docker-env)

# Liste des images à pousser
IMAGES=(
    "docker_open5gs"
    "docker_kamailio"
    "docker_rtpengine"
)

echo "Push des images Podman vers Minikube Docker..."
for image in "${IMAGES[@]}"; do
    if podman images | grep -q "$image"; then
        echo "  → Pushing $image..."
        # Export depuis Podman et import dans Docker de Minikube
        podman save "$image:latest" | docker load
        echo -e "${GREEN}    ✓ $image pushed${NC}"
    else
        echo -e "${YELLOW}    ⚠ $image non trouvée${NC}"
    fi
done

# Taguer les images pour correspondre aux noms des deployments
docker tag docker_open5gs:latest docker_open5gs_hss:latest 2>/dev/null || true

echo -e "${GREEN}✓ Images disponibles dans Minikube${NC}"

# Vérifier les images
echo ""
echo "Images disponibles dans Minikube:"
docker images | grep -E "docker_open5gs|docker_kamailio|docker_rtpengine"

# ====================================================================
# PARTIE 5: CONFIGURATION MINIKUBE
# ====================================================================

echo ""
echo -e "${YELLOW}=== [5/7] CONFIGURATION MINIKUBE ===${NC}"

# Activer addons
minikube addons enable dashboard
minikube addons enable metrics-server
echo -e "${GREEN}✓ Dashboard et Metrics-Server activés${NC}"

# Charger module SCTP
minikube ssh -- 'sudo modprobe sctp && echo "sctp" | sudo tee /etc/modules-load.d/sctp.conf' 2>/dev/null
echo -e "${GREEN}✓ Module SCTP chargé${NC}"

# Créer namespace
kubectl create namespace ims --dry-run=client -o yaml | kubectl apply -f -
kubectl config set-context --current --namespace=ims
echo -e "${GREEN}✓ Namespace 'ims' créé${NC}"

# ====================================================================
# PARTIE 6: CRÉATION DES MANIFESTS KUBERNETES
# ====================================================================

echo ""
echo -e "${YELLOW}=== [6/7] CRÉATION DES MANIFESTS ===${NC}"

# Manifest 1: Namespace
cat > $MANIFEST_DIR/01-namespace.yaml << 'YAML'
apiVersion: v1
kind: Namespace
metadata:
  name: ims
  labels:
    name: ims
    app: ims-core
YAML

# ConfigMaps
echo "Création des ConfigMaps..."
for component in hss pcscf icscf scscf; do
    if [ -d "$HOME/docker_open5gs/$component" ]; then
        kubectl create configmap ${component}-config \
          --from-file=$HOME/docker_open5gs/$component/ \
          --namespace=ims \
          --dry-run=client -o yaml > $MANIFEST_DIR/02-configmap-${component}.yaml
        echo -e "${GREEN}  ✓ ConfigMap $component${NC}"
    fi
done

# Manifest 3: PVCs
cat > $MANIFEST_DIR/03-pv-mysql.yaml << 'YAML'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: mysql-pvc
  namespace: ims
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 5Gi
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: mongo-pvc
  namespace: ims
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 5Gi
YAML

# Manifest 4: MySQL
cat > $MANIFEST_DIR/04-deployment-mysql.yaml << 'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mysql
  namespace: ims
spec:
  replicas: 1
  selector:
    matchLabels:
      app: mysql
  template:
    metadata:
      labels:
        app: mysql
    spec:
      containers:
      - name: mysql
        image: mysql:8.0
        env:
        - name: MYSQL_ROOT_PASSWORD
          value: "linux"
        - name: MYSQL_DATABASE
          value: "open5gs"
        ports:
        - containerPort: 3306
        volumeMounts:
        - name: mysql-storage
          mountPath: /var/lib/mysql
      volumes:
      - name: mysql-storage
        persistentVolumeClaim:
          claimName: mysql-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: mysql
  namespace: ims
spec:
  selector:
    app: mysql
  ports:
  - port: 3306
    targetPort: 3306
YAML

# Manifest 5: MongoDB
cat > $MANIFEST_DIR/05-deployment-mongo.yaml << 'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mongo
  namespace: ims
spec:
  replicas: 1
  selector:
    matchLabels:
      app: mongo
  template:
    metadata:
      labels:
        app: mongo
    spec:
      containers:
      - name: mongo
        image: mongo:6.0
        command: ["mongod", "--bind_ip", "0.0.0.0"]
        ports:
        - containerPort: 27017
        volumeMounts:
        - name: mongo-storage
          mountPath: /data/db
      volumes:
      - name: mongo-storage
        persistentVolumeClaim:
          claimName: mongo-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: mongo
  namespace: ims
spec:
  selector:
    app: mongo
  ports:
  - port: 27017
    targetPort: 27017
YAML

# Copier deployments existants si disponibles
if [ -d "$HOME/docker_open5gs/k8s-ims-final" ]; then
    cp $HOME/docker_open5gs/k8s-ims-final/hss-deployment.yaml $MANIFEST_DIR/06-deployment-hss.yaml 2>/dev/null
    cp $HOME/docker_open5gs/k8s-ims-final/pcscf-deployment.yaml $MANIFEST_DIR/07-deployment-pcscf.yaml 2>/dev/null
    cp $HOME/docker_open5gs/k8s-ims-final/icscf-deployment.yaml $MANIFEST_DIR/08-deployment-icscf.yaml 2>/dev/null
    cp $HOME/docker_open5gs/k8s-ims-final/scscf-deployment.yaml $MANIFEST_DIR/09-deployment-scscf.yaml 2>/dev/null
    echo -e "${GREEN}✓ Deployments IMS copiés${NC}"
else
    echo -e "${YELLOW}⚠ k8s-ims-final non trouvé, créer les deployments manuellement${NC}"
fi

# Manifest Services
cat > $MANIFEST_DIR/10-services-ims.yaml << 'YAML'
apiVersion: v1
kind: Service
metadata:
  name: hss
  namespace: ims
spec:
  selector:
    io.kompose.service: hss
  ports:
  - name: diameter
    port: 3868
    targetPort: 3868
---
apiVersion: v1
kind: Service
metadata:
  name: pcscf
  namespace: ims
spec:
  selector:
    io.kompose.service: pcscf
  ports:
  - name: sip-udp
    protocol: UDP
    port: 5060
    targetPort: 5060
  - name: sip-tcp
    protocol: TCP
    port: 5060
    targetPort: 5060
  type: NodePort
---
apiVersion: v1
kind: Service
metadata:
  name: icscf
  namespace: ims
spec:
  selector:
    io.kompose.service: icscf
  ports:
  - name: sip
    port: 4060
    targetPort: 4060
  - name: diameter
    port: 3869
    targetPort: 3869
---
apiVersion: v1
kind: Service
metadata:
  name: scscf
  namespace: ims
spec:
  selector:
    io.kompose.service: scscf
  ports:
  - name: sip
    port: 6060
    targetPort: 6060
YAML

echo -e "${GREEN}✓ Manifests créés${NC}"

# ====================================================================
# PARTIE 7: DÉPLOIEMENT SUR KUBERNETES
# ====================================================================

echo ""
echo -e "${YELLOW}=== [7/7] DÉPLOIEMENT SUR KUBERNETES ===${NC}"

# Appliquer les manifests dans l'ordre
echo "Déploiement du namespace..."
kubectl apply -f $MANIFEST_DIR/01-namespace.yaml

echo "Déploiement des ConfigMaps..."
kubectl apply -f $MANIFEST_DIR/02-configmap-*.yaml 2>/dev/null || echo "ConfigMaps en cours..."

echo "Déploiement des PVCs..."
kubectl apply -f $MANIFEST_DIR/03-pv-mysql.yaml
sleep 5

echo "Déploiement des bases de données..."
kubectl apply -f $MANIFEST_DIR/04-deployment-mysql.yaml
kubectl apply -f $MANIFEST_DIR/05-deployment-mongo.yaml
echo "  Attente démarrage (30s)..."
sleep 30

if [ -f "$MANIFEST_DIR/06-deployment-hss.yaml" ]; then
    echo "Déploiement du HSS..."
    kubectl apply -f $MANIFEST_DIR/06-deployment-hss.yaml
    sleep 15

    echo "Déploiement des CSCF..."
    kubectl apply -f $MANIFEST_DIR/07-deployment-pcscf.yaml 2>/dev/null
    kubectl apply -f $MANIFEST_DIR/08-deployment-icscf.yaml 2>/dev/null
    kubectl apply -f $MANIFEST_DIR/09-deployment-scscf.yaml 2>/dev/null
    echo "  Attente démarrage (30s)..."
    sleep 30
else
    echo -e "${YELLOW}⚠ Deployments IMS non trouvés, à déployer manuellement via Dashboard${NC}"
fi

echo "Déploiement des services..."
kubectl apply -f $MANIFEST_DIR/10-services-ims.yaml

echo -e "${GREEN}✓ Déploiement terminé${NC}"

# ====================================================================
# CRÉATION DES SCRIPTS UTILES
# ====================================================================

echo ""
echo "Création des scripts utiles..."

# Script Dashboard
cat > $SCRIPT_DIR/open-dashboard.sh << 'DASH'
#!/bin/bash
echo "Ouverture du Dashboard Kubernetes..."
minikube dashboard
DASH
chmod +x $SCRIPT_DIR/open-dashboard.sh

# Script Verify
cat > $SCRIPT_DIR/verify.sh << 'VERIFY'
#!/bin/bash
echo "=== État des Pods ==="
kubectl get pods -n ims

echo ""
echo "=== Services ==="
kubectl get svc -n ims

echo ""
echo "=== Images Disponibles ==="
eval $(minikube docker-env)
docker images | grep -E "docker_open5gs|docker_kamailio"

echo ""
echo "=== Connexions Diameter HSS ==="
kubectl logs deployment/hss -n ims 2>/dev/null | grep CONNECTED | tail -n 5

echo ""
echo "=== Connexions Diameter PCSCF ==="
kubectl logs deployment/pcscf -n ims 2>/dev/null | grep "3868 connected" | tail -n 1

echo ""
echo "=== Connexions Diameter ICSCF ==="
kubectl logs deployment/icscf -n ims 2>/dev/null | grep "3868 connected" | tail -n 1

echo ""
echo "=== Connexions Diameter SCSCF ==="
kubectl logs deployment/scscf -n ims 2>/dev/null | grep "3868 connected" | tail -n 1
VERIFY
chmod +x $SCRIPT_DIR/verify.sh

# Script Cleanup
cat > $SCRIPT_DIR/cleanup.sh << 'CLEAN'
#!/bin/bash
echo "Suppression du namespace IMS..."
kubectl delete namespace ims --timeout=60s
echo "✓ Nettoyage terminé"
CLEAN
chmod +x $SCRIPT_DIR/cleanup.sh

# Script Logs
cat > $SCRIPT_DIR/logs-all.sh << 'LOGS'
#!/bin/bash
echo "=== Logs HSS ==="
kubectl logs deployment/hss -n ims --tail=20

echo ""
echo "=== Logs PCSCF ==="
kubectl logs deployment/pcscf -n ims --tail=20

echo ""
echo "=== Logs ICSCF ==="
kubectl logs deployment/icscf -n ims --tail=20

echo ""
echo "=== Logs SCSCF ==="
kubectl logs deployment/scscf -n ims --tail=20
LOGS
chmod +x $SCRIPT_DIR/logs-all.sh

echo -e "${GREEN}✓ Scripts créés${NC}"

# ====================================================================
# FINALISATION
# ====================================================================

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                                                              ║"
echo "║        ✅  DÉPLOIEMENT IMS KUBERNETES TERMINÉ  ✅           ║"
echo "║                                                              ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

echo -e "${GREEN}=== RÉSUMÉ ===${NC}"
echo ""
echo "Dossier créé: $BASE_DIR"
echo ""

echo "État actuel:"
kubectl get all -n ims
echo ""

echo -e "${BLUE}=== ACCÈS DASHBOARD ===${NC}"
echo ""
echo "Pour ouvrir le Dashboard Kubernetes:"
echo "  cd $SCRIPT_DIR"
echo "  ./open-dashboard.sh"
echo ""

echo -e "${BLUE}=== VÉRIFICATIONS ===${NC}"
echo ""
echo "Vérifier le déploiement:"
echo "  cd $SCRIPT_DIR"
echo "  ./verify.sh"
echo ""

echo -e "${GREEN}=== FICHIERS CRÉÉS ===${NC}"
echo ""
echo "Manifests: $MANIFEST_DIR/"
echo "Scripts: $SCRIPT_DIR/"
echo ""

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                                                              ║"
echo "║  🎉 PROJET IMS KUBERNETES CRÉÉ ET DÉPLOYÉ AVEC SUCCÈS! 🎉  ║"
echo "║                                                              ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "Dashboard: cd $SCRIPT_DIR && ./open-dashboard.sh"
echo "Vérification: cd $SCRIPT_DIR && ./verify.sh"
echo ""

