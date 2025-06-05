#!/bin/bash
# Script para configurar el laboratorio GCP qwiklabs-gcp-03-4874b94ae8d1

# Variables de proyecto
PROJECT_ID="qwiklabs-gcp-03-4874b94ae8d"
PROJECT_NUMBER="865183104578"
REGION_US="us-east1"
REGION_ASIA="asia-east1"
ZONE_US="us-east1-c"

# Configura el proyecto activo
gcloud config set project $PROJECT_ID

echo "=== TASK 1: Configurar regla de firewall para health checks ==="
gcloud compute firewall-rules create fw-allow-health-checks \
    --network default \
    --target-tags allow-health-checks \
    --allow tcp:80 \
    --source-ranges 130.211.0.0/22,35.191.0.0/16 \
    --description "Allow health check probes to instances"

echo "=== TASK 2: Crear Cloud Router y Cloud NAT ==="
gcloud compute routers create nat-router-us1 \
    --network default \
    --region $REGION_US \
    --project $PROJECT_ID || echo "Router already exists"

gcloud compute routers nats create nat-config \
    --router=nat-router-us1 \
    --router-region=$REGION_US \
    --nat-all-subnet-ip-ranges \
    --auto-allocate-nat-external-ips \
    --project $PROJECT_ID || echo "NAT already exists"

echo "=== TASK 3: Crear VM webserver y preparar imagen personalizada ==="
gcloud compute instances create webserver \
    --zone $ZONE_US \
    --machine-type e2-micro \
    --subnet default \
    --tags allow-health-checks \
    --no-address \
    --image-family debian-11 \
    --image-project debian-cloud \
    --boot-disk-auto-delete=false

# Espera a que la VM esté lista
echo "Esperando que la VM webserver esté lista para SSH..."
sleep 30

# Instalar apache2 y configurar para que inicie al boot
gcloud compute ssh webserver --zone=$ZONE_US --command="
    sudo apt-get update &&
    sudo apt-get install -y apache2 &&
    sudo service apache2 start &&
    sudo update-rc.d apache2 enable
"

# Reiniciar VM para probar el autoarranque del apache
gcloud compute instances reset webserver --zone=$ZONE_US

# Esperar para que reinicie
sleep 20

# Comprobar status apache (opcional)
gcloud compute ssh webserver --zone=$ZONE_US --command="sudo service apache2 status"

# Crear imagen personalizada desde el disco de webserver
DISK_NAME=$(gcloud compute instances describe webserver --zone=$ZONE_US --format='get(disks[0].deviceName)')
gcloud compute images create mywebserver \
    --source-disk=$DISK_NAME \
    --source-disk-zone=$ZONE_US

echo "=== TASK 4: Crear plantilla de instancia y grupos administrados ==="
gcloud compute instance-templates create mywebserver-template \
    --machine-type e2-micro \
    --network default \
    --tags allow-health-checks \
    --no-address \
    --image mywebserver

gcloud compute health-checks create tcp http-health-check --port 80

gcloud compute instance-groups managed create us-1-mig \
    --base-instance-name us-1-mig \
    --template mywebserver-template \
    --size 1 \
    --zones us-east1-b,us-east1-c

gcloud compute instance-groups managed set-autoscaling us-1-mig \
    --max-num-replicas 2 \
    --min-num-replicas 1 \
    --target-load-balancing-utilization 0.8 \
    --cool-down-period 60 \
    --zone us-east1-c

gcloud compute instance-groups managed create notus-1-mig \
    --base-instance-name notus-1-mig \
    --template mywebserver-template \
    --size 1 \
    --zones asia-east1-b,asia-east1-c

gcloud compute instance-groups managed set-autoscaling notus-1-mig \
    --max-num-replicas 2 \
    --min-num-replicas 1 \
    --target-load-balancing-utilization 0.8 \
    --cool-down-period 60 \
    --zone asia-east1-c

echo "=== TASK 5: Configurar Application Load Balancer (HTTP) ==="
gcloud compute backend-services create http-backend \
    --protocol HTTP \
    --port-name http \
    --health-checks http-health-check \
    --global

gcloud compute backend-services add-backend http-backend \
    --instance-group us-1-mig \
    --instance-group-zone us-east1-c \
    --global

gcloud compute backend-services add-backend http-backend \
    --instance-group notus-1-mig \
    --instance-group-zone asia-east1-c \
    --global

gcloud compute url-maps create http-map \
    --default-service http-backend

gcloud compute target-http-proxies create http-lb-proxy \
    --url-map http-map

gcloud compute forwarding-rules create http-content-rule-v4 \
    --address "" \
    --global \
    --target-http-proxy http-lb-proxy \
    --ports 80

echo "Script terminado. Verifica los recursos en la consola de Google Cloud."
