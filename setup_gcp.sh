#!/bin/bash

set -e

PROJECT_ID="tu-proyecto-id"
REGION1="us-east1"
ZONE1="us-east1-c"
REGION2="asia-east1"
ZONE2="asia-east1-a"

# Autenticarse y seleccionar proyecto (opcional si ya está hecho)
gcloud config set project $PROJECT_ID

echo "Task 1: Crear regla de firewall para health checks"
gcloud compute firewall-rules create fw-allow-health-checks \
  --network default \
  --target-tags allow-health-checks \
  --allow tcp:80 \
  --source-ranges 130.211.0.0/22,35.191.0.0/16 \
  --description "Allow health check probes from GCP ranges" \
  --quiet

echo "Task 2: Crear Cloud Router y configurar Cloud NAT"
gcloud compute routers create nat-router-us1 \
  --network default \
  --region $REGION1 \
  --quiet

gcloud compute routers nats create nat-config \
  --router=nat-router-us1 \
  --router-region=$REGION1 \
  --nat-all-subnet-ip-ranges \
  --auto-allocate-nat-external-ips \
  --enable-logging \
  --quiet

# Esperar a que NAT esté activo (simple espera)
echo "Esperando 30 segundos para que Cloud NAT se inicie..."
sleep 30

echo "Task 3: Crear VM webserver sin IP externa y con Apache instalado"

gcloud compute instances create webserver \
  --zone=$ZONE1 \
  --machine-type=e2-micro \
  --network-tags=allow-health-checks \
  --no-address \
  --image-family=debian-11 \
  --image-project=debian-cloud \
  --boot-disk-auto-delete=no \
  --quiet

echo "Instalando Apache en la VM 'webserver'..."
gcloud compute ssh webserver --zone=$ZONE1 --command="sudo apt-get update && sudo apt-get install -y apache2 && sudo service apache2 start && sudo update-rc.d apache2 enable"

echo "Reiniciando la VM para validar que apache arranque al inicio..."
gcloud compute instances reset webserver --zone=$ZONE1 --quiet

echo "Esperando 15 segundos para que la VM reinicie..."
sleep 15

echo "Verificando estado de apache en 'webserver'..."
gcloud compute ssh webserver --zone=$ZONE1 --command="sudo service apache2 status"

echo "Task 3: Crear imagen customizada del disco boot de webserver"
DISK_NAME=$(gcloud compute instances describe webserver --zone=$ZONE1 --format="get(disks[0].deviceName)")
echo "Usando disco boot: $DISK_NAME"

# Detener instancia antes de crear imagen para evitar problemas
gcloud compute instances stop webserver --zone=$ZONE1 --quiet
sleep 10

gcloud compute images create mywebserver \
  --source-disk=$DISK_NAME \
  --source-disk-zone=$ZONE1 \
  --quiet

# Borrar la VM pero mantener disco
gcloud compute instances delete webserver --zone=$ZONE1 --quiet

echo "Task 4: Crear template de instancia"

gcloud compute instance-templates create mywebserver-template \
  --machine-type=e2-micro \
  --network-tags=allow-health-checks \
  --no-address \
  --image=mywebserver \
  --image-project=$PROJECT_ID \
  --quiet

echo "Task 4: Crear health check TCP puerto 80"
gcloud compute health-checks create tcp http-health-check --port 80 --quiet

echo "Task 4: Crear grupos de instancias administradas con autoscaling"

gcloud compute instance-groups managed create us-1-mig \
  --base-instance-name=us-1-mig \
  --template=mywebserver-template \
  --size=1 \
  --zone=$ZONE1 \
  --health-check=http-health-check \
  --initial-delay=60 \
  --quiet

gcloud compute instance-groups managed set-autoscaling us-1-mig \
  --max-num-replicas=2 \
  --min-num-replicas=1 \
  --target-load-balancing-utilization=0.8 \
  --cool-down-period=60 \
  --zone=$ZONE1 \
  --quiet

# Para asia-east1:
gcloud compute instance-groups managed create notus-1-mig \
  --base-instance-name=notus-1-mig \
  --template=mywebserver-template \
  --size=1 \
  --zone=$ZONE2 \
  --health-check=http-health-check \
  --initial-delay=60 \
  --quiet

gcloud compute instance-groups managed set-autoscaling notus-1-mig \
  --max-num-replicas=2 \
  --min-num-replicas=1 \
  --target-load-balancing-utilization=0.8 \
  --cool-down-period=60 \
  --zone=$ZONE2 \
  --quiet

echo "Task 5: Crear Load Balancer HTTP global"

gcloud compute backend-services create http-backend \
  --protocol=HTTP \
  --port-name=http \
  --health-checks=http-health-check \
  --global \
  --timeout=30 \
  --quiet

gcloud compute backend-services add-backend http-backend \
  --instance-group=us-1-mig \
  --instance-group-zone=$ZONE1 \
  --global \
  --balancing-mode=RATE \
  --max-rate=50 \
  --capacity-scaler=1.0 \
  --quiet

gcloud compute backend-services add-backend http-backend \
  --instance-group=notus-1-mig \
  --instance-group-zone=$ZONE2 \
  --global \
  --balancing-mode=UTILIZATION \
  --max-utilization=0.8 \
  --capacity-scaler=1.0 \
  --quiet

gcloud compute url-maps create web-map-http \
  --default-service=http-backend \
  --quiet

gcloud compute target-http-proxies create http-lb-proxy \
  --url-map=web-map-http \
  --quiet

gcloud compute forwarding-rules create http-content-rule-v4 \
  --address=0.0.0.0 \
  --global \
  --target-http-proxy=http-lb-proxy \
  --ports=80 \
  --quiet

gcloud compute forwarding-rules create http-content-rule-v6 \
  --address=0.0.0.0 \
  --global \
  --target-http-proxy=http-lb-proxy \
  --ports=80 \
  --ip-version=IPV6 \
  --quiet

echo "Task 6: Crear VM para stress test"

# Elegimos zona diferente, por ejemplo us-central1-a
STRESS_REGION="us-central1"
STRESS_ZONE="us-central1-a"

gcloud compute instances create stress-test \
  --zone=$STRESS_ZONE \
  --machine-type=e2-micro \
  --image=mywebserver \
  --image-project=$PROJECT_ID \
  --quiet

echo "El script ha terminado. Revisa el estado de los recursos y el IP del load balancer con:"
echo "gcloud compute forwarding-rules list --global"
echo "Para stress test, conecta a la VM stress-test y corre: ab -n 500000 -c 1000 http://[LB_IP]/"

