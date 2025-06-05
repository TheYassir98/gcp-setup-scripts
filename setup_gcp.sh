#!/bin/bash

# Variables
PROJECT_ID="qwiklabs-gcp-03-4874ae8d1"
REGION="us-central1"
ZONE="us-central1-a"
NETWORK="default"
FIREWALL_RULE="allow-health-checks"
ROUTER_NAME="nat-router"
NAT_NAME="nat-config"
INSTANCE_NAME="webserver"
INSTANCE_TEMPLATE="webserver-template"
MIG_NAME="webserver-mig"
IMAGE_NAME="mywebserver-image"
LOAD_BALANCER_NAME="webserver-lb"

echo "Configurando proyecto: $PROJECT_ID"

# Configurar proyecto activo
gcloud config set project $PROJECT_ID

echo "=== TASK 1: Crear regla de firewall para health checks ==="
gcloud compute firewall-rules create $FIREWALL_RULE \
  --network $NETWORK \
  --action allow \
  --direction ingress \
  --source-ranges 130.211.0.0/22,35.191.0.0/16 \
  --rules tcp:80,tcp:443 || echo "La regla de firewall probablemente ya existe."

echo "=== TASK 2: Crear Cloud Router y NAT ==="
gcloud compute routers create $ROUTER_NAME \
  --network $NETWORK \
  --region $REGION || echo "Router probablemente ya existe."

gcloud compute routers nats create $NAT_NAME \
  --router=$ROUTER_NAME \
  --auto-allocate-nat-external-ips \
  --nat-all-subnet-ip-ranges \
  --region=$REGION || echo "NAT probablemente ya existe."

echo "=== TASK 3: Crear VM webserver y preparar imagen personalizada ==="
gcloud compute instances create $INSTANCE_NAME \
  --zone $ZONE \
  --machine-type e2-medium \
  --subnet $NETWORK \
  --tags http-server \
  --image-family debian-11 \
  --image-project debian-cloud \
  --boot-disk-size 10GB \
  --boot-disk-type pd-standard \
  --metadata startup-script='#!/bin/bash
    sudo apt-get update
    sudo apt-get install -y apache2
    sudo systemctl start apache2
    sudo systemctl enable apache2' || echo "La instancia probablemente ya existe."

echo "Esperando a que la VM esté lista para crear imagen..."
sleep 60

echo "Creando imagen personalizada..."
gcloud compute images create $IMAGE_NAME \
  --source-disk $INSTANCE_NAME \
  --source-disk-zone $ZONE || echo "Imagen personalizada probablemente ya existe."

echo "Deteniendo la instancia para liberar recursos..."
gcloud compute instances delete $INSTANCE_NAME --zone $ZONE --quiet

echo "=== TASK 4: Crear plantilla de instancia y grupos administrados ==="
gcloud compute instance-templates create $INSTANCE_TEMPLATE \
  --machine-type e2-medium \
  --subnet $NETWORK \
  --tags=http-server \
  --image $IMAGE_NAME || echo "Plantilla de instancia probablemente ya existe."

gcloud compute instance-groups managed create $MIG_NAME \
  --base-instance-name webserver \
  --size 1 \
  --template $INSTANCE_TEMPLATE \
  --zone $ZONE || echo "Grupo administrado probablemente ya existe."

echo "Configurando autoescalado..."
gcloud compute instance-groups managed set-autoscaling $MIG_NAME \
  --max-num-replicas 3 \
  --min-num-replicas 1 \
  --target-cpu-utilization 0.6 \
  --zone $ZONE || echo "Autoescalado probablemente ya está configurado."

echo "=== TASK 5: Configurar Load Balancer ==="
# Backend service
gcloud compute backend-services create $LOAD_BALANCER_NAME-backend \
  --protocol HTTP \
  --port-name http \
  --health-checks $LOAD_BALANCER_NAME-healthcheck \
  --global || echo "Backend service probablemente ya existe."

gcloud compute backend-services add-backend $LOAD_BALANCER_NAME-backend \
  --instance-group $MIG_NAME \
  --instance-group-zone $ZONE \
  --global || echo "Backend ya tiene grupo agregado."

# Health check
gcloud compute health-checks create http $LOAD_BALANCER_NAME-healthcheck \
  --port 80 || echo "Health check probablemente ya existe."

# URL map
gcloud compute url-maps create $LOAD_BALANCER_NAME-map \
  --default-service $LOAD_BALANCER_NAME-backend || echo "URL map probablemente ya existe."

# HTTP proxy
gcloud compute target-http-proxies create $LOAD_BALANCER_NAME-proxy \
  --url-map $LOAD_BALANCER_NAME-map || echo "HTTP proxy probablemente ya existe."

# Forwarding rule
gcloud compute forwarding-rules create $LOAD_BALANCER_NAME-forwarding-rule \
  --global \
  --target-http-proxy $LOAD_BALANCER_NAME-proxy \
  --ports 80 || echo "Forwarding rule probablemente ya existe."

echo "Script finalizado. Verifica los recursos en la consola de Google Cloud."
