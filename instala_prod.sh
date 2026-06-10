#!/bin/bash
# Impedir que o script continue se algum comando falhar
set -e

echo "===================================================="
echo "    INSTALADOR AUTOMATIZADO - VITOR-QUADROS ISP     "
echo "               (VERSÃO DE PRODUÇÃO DOCKER)          "
echo "===================================================="
echo ""

echo "[*] Removendo instalações, processos e bancos de dados anteriores..."
systemctl stop nginx php8.2-fpm cron netflow-collector dns-metrics-collector unbound || true
pkill -9 php-fpm || true
pkill -9 php || true
if command -v docker &>/dev/null; then
    cd /opt/isp-web-docker && docker compose down || true
fi

if systemctl is-active --quiet postgresql; then
    su - postgres -c "psql -c \"SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'isp_client_portal';\"" || true
    su - postgres -c "psql -c \"DROP DATABASE IF EXISTS isp_client_portal WITH (FORCE);\"" || true
    su - postgres -c "psql -c \"DROP USER IF EXISTS isp_client_app;\"" || true
fi

rm -rf /var/www/html/isp-client || true
rm -f /etc/cron.d/isp-client /etc/sudoers.d/www-data-mtr || true
rm -f /etc/systemd/system/netflow-collector.service /etc/systemd/system/dns-metrics-collector.service /etc/nginx/ssl/isp-client.* || true
systemctl daemon-reload || true

echo "[*] Configurando repositórios oficiais do Debian 12 (Internet)..."
cat << 'EOF' > /etc/apt/sources.list
deb http://deb.debian.org/debian/ bookworm main contrib non-free non-free-firmware
deb-src http://deb.debian.org/debian/ bookworm main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
deb-src http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
deb http://deb.debian.org/debian/ bookworm-updates main contrib non-free non-free-firmware
deb-src http://deb.debian.org/debian/ bookworm-updates main contrib non-free non-free-firmware
EOF

echo "[*] Atualizando a lista de pacotes do Debian 12..."
apt-get update && apt-get upgrade -y

echo "[*] Instalando ferramentas de rede, motores nativos e Docker..."
apt-get install -y apt-transport-https ca-certificates curl gnupg wget sudo lsof mtr-tiny rsync socat netcat-openbsd net-tools rsyslog sshpass python3 python3-pip python3-venv apparmor-utils unbound dnsutils git cron postgresql postgresql-contrib sqlite3 docker.io docker-compose-v2

echo "[*] Configurando chaves SSH locais com o GitHub..."
mkdir -p /root/.ssh && chmod 700 /root/.ssh
rm -f /root/.ssh/id_isp_client /root/.ssh/id_isp_client.pub /root/.ssh/config
ssh-keygen -t ed25519 -f /root/.ssh/id_isp_client -N "" -q
cat << 'EOF' > /root/.ssh/config
Host github.com
    HostName github.com
    User git
    IdentityFile /root/.ssh/id_isp_client
    IdentitiesOnly yes
    StrictHostKeyChecking no
EOF
chmod 600 /root/.ssh/config /root/.ssh/id_isp_client

echo "🔑 CHAVE DE LIBERAÇÃO DO SISTEMA (DEPLOY KEY)"
echo "====================================================================="
cat /root/.ssh/id_isp_client.pub
echo "====================================================================="
echo ""
read -p "Após liberar o acesso no seu GitHub, digite 'OK' e aperte Enter: " CONFIRMACAO

echo "[*] Baixando a build protegida do GitHub de forma segura..."
mkdir -p /var/www/html
git clone git@github.com:VITOR-QUADROS1/isp-client-prod.git /var/www/html/isp-client

echo "[*] Gerando chaves de criptografia SSL para HTTPS..."
mkdir -p /etc/nginx/ssl
openssl req -x509 -nodes -days 3650 -newkey rsa:2048 -keyout /etc/nginx/ssl/isp-client.key -out /etc/nginx/ssl/isp-client.crt -subj "/C=BR/ST=RS/L=PortoAlegre/O=VisaoSoft/OU=NOC/CN=visao-soft-isp"

echo "[*] Configurando banco de dados PostgreSQL Nativo..."
su - postgres -c "psql -c \"CREATE USER isp_client_app WITH PASSWORD 'Union@2026!';\"" || true
su - postgres -c "psql -c \"CREATE DATABASE isp_client_portal OWNER isp_client_app;\"" || true
cat /var/www/html/isp-client/backups/install.sql | sudo -u postgres psql -d isp_client_portal

cat << 'EOF' | sudo -u postgres psql -d isp_client_portal
ALTER TABLE mtr_advanced_networks ADD COLUMN IF NOT EXISTS active BOOLEAN DEFAULT true;
ALTER TABLE mtr_advanced_hosts ADD COLUMN IF NOT EXISTS active BOOLEAN DEFAULT true;
ALTER TABLE mtr_advanced_targets ADD COLUMN IF NOT EXISTS active BOOLEAN DEFAULT true;
ALTER TABLE mtr_advanced_probes ADD COLUMN IF NOT EXISTS active BOOLEAN DEFAULT true;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO isp_client_app;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO isp_client_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO isp_client_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO isp_client_app;
EOF

echo "[*] Injetando usuários administradores..."
cat << EOF | sudo -u postgres psql -d isp_client_portal
INSERT INTO client_portal_users (username, password_hash, role, name, email, phone, is_active, created_at, updated_at) VALUES ('master', '\$2y\$10\$X/D4d1oA9.k2/K5Uo4O6uexK7eTq9A2/C41QYqTq/y30Jp6eZ7T2a', 'master', 'Master Oculto', 'suporte@visaosoft.com', '5500000000000', true, NOW(), NOW()) ON CONFLICT (username) DO NOTHING;
INSERT INTO backup_configuracoes (id, smtp_host, smtp_porta, smtp_usuario, smtp_senha, smtp_from_nome, smtp_from_email, senha_min_caracteres, backup_automatico, backup_horario, backup_avisar_falhas, backup_email_falhas, backup_retencoes) VALUES (1, 'mail.seusistema.com.br', 587, '', '', 'ISP Backup', '', 6, false, '02:00:00', false, 'noc@seuprovedor.com.br', 10) ON CONFLICT (id) DO NOTHING;
EOF

echo "[*] Escrevendo arquivo de credenciais local..."
mkdir -p /var/www/html/isp-client/config
cat << EOF > /var/www/html/isp-client/config/env.php
<?php
declare(strict_types=1);
define('DB_PASS', 'Union@2026!');
define('SIRENE_APP_KEY', '$(openssl rand -hex 32)');
EOF
chmod 644 /var/www/html/isp-client/config/env.php

echo "[*] Configurando DNS Unbound RECURSIVO Nativo..."
mkdir -p /var/log/unbound && touch /var/log/unbound/unbound.log
chown -R unbound:unbound /var/log/unbound
cat << 'EOF' > /etc/unbound/unbound.conf
include: /etc/unbound/unbound.conf.d/remote-control.conf
server:
interface: 0.0.0.0
interface: ::0
interface-automatic: yes
include: /etc/unbound/bloqueios.conf
include: /etc/unbound/acls.conf
include: /etc/unbound/local_zones.conf
num-threads: 8
outgoing-range: 8192
so-rcvbuf: 1m
so-sndbuf: 1m
msg-cache-size: 50m
msg-cache-slabs: 8
num-queries-per-thread: 4096
rrset-cache-size: 100m
rrset-cache-slabs: 8
cache-max-ttl: 7200
infra-cache-slabs: 8
minimal-responses: yes
prefetch: yes
prefetch-key: yes
rrset-roundrobin: yes
auto-trust-anchor-file: "/var/lib/unbound/root.key"
logfile: "/var/log/unbound/unbound.log"
verbosity: 2
log-queries: yes
log-replies: yes
log-servfail: yes
statistics-interval: 0
extended-statistics: yes
statistics-cumulative: no
EOF

cat << 'EOF' > /etc/unbound/acls.conf
access-control: 127.0.0.0/8 allow
access-control: ::1 allow
access-control: 10.0.0.0/8 allow
access-control: 172.16.0.0/12 allow
access-control: 192.168.0.0/16 allow
access-control: 100.64.0.0/10 allow
EOF
touch /etc/unbound/local_zones.conf /etc/unbound/bloqueios.conf
chown www-data:www-data /etc/unbound/bloqueios.conf /etc/unbound/acls.conf /etc/unbound/local_zones.conf
chmod 664 /etc/unbound/*.conf

mkdir -p /var/lib/unbound && chown -R unbound:unbound /var/lib/unbound
/usr/sbin/unbound-anchor -a /var/lib/unbound/root.key || unbound-anchor -a /var/lib/unbound/root.key || true
aa-complain /usr/sbin/unbound || true

echo "[*] IMPLANTANDO ORQUESTRAÇÃO DOCKER DO PAINEL WEB COM LIMITADORES..."
mkdir -p /opt/isp-web-docker && cd /opt/isp-web-docker

cat << 'EOF' > Dockerfile
FROM php:8.2-fpm-bookworm
RUN apt-get update && apt-get install -y libpq-dev libsqlite3-dev libcurl4-openssl-dev libonig-dev libxml2-dev libzip-dev libpng-dev libicu-dev libssh2-1-dev git unzip && rm -rf /var/list/apt/lists/*
RUN docker-php-ext-install pdo_pgsql pdo_sqlite curl mbstring xml zip gd intl
RUN pecl install ssh2-1.4.1 && docker-php-ext-enable ssh2
WORKDIR /var/www/html/isp-client
EOF

cat << 'EOF' > nginx.conf
server {
    listen 8081 ssl default_server; listen [::]:8081 ssl default_server;
    server_name _; root /var/www/html/isp-client; index login.php index.php index.html;
    ssl_certificate /etc/nginx/ssl/isp-client.crt; ssl_certificate_key /etc/nginx/ssl/isp-client.key;
    ssl_protocols TLSv1.2 TLSv1.3; ssl_ciphers HIGH:!aNULL:!MD5; ssl_prefer_server_ciphers on;
    location / { try_files $uri $uri/ /index.php?$query_string; }
    location ~ \.php$ { include fastcgi_params; fastcgi_pass 127.0.0.1:9000; fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name; }
    location ~ /\.ht { deny all; }
}
EOF

cat << 'EOF' > docker-compose.yml
version: '3.8'
services:
  isp-php:
    build: .
    container_name: isp-web-php
    network_mode: host
    restart: always
    volumes:
      - /var/www/html/isp-client:/var/www/html/isp-client
    deploy:
      resources:
        limits:
          cpus: '2.0'
          memory: 1G
  isp-nginx:
    image: nginx:alpine
    container_name: isp-web-nginx
    network_mode: host
    restart: always
    depends_on:
      - isp-php
    volumes:
      - /var/www/html/isp-client:/var/www/html/isp-client
      - ./nginx.conf:/etc/nginx/conf.d/default.conf
      - /etc/nginx/ssl:/etc/nginx/ssl
    deploy:
      resources:
        limits:
          cpus: '1.0'
          memory: 512M
EOF

docker compose up -d --build

echo "[*] Populando fabricantes e sementes via Docker..."
docker exec -i isp-web-php php /var/www/html/isp-client/backups/seed_backups.php || true

echo "[*] Implantando Serviços de Métricas e Crons..."
mkdir -p /var/www/html/isp-client/ferramentas/dns
python3 -m venv /var/www/html/isp-client/ferramentas/dns/venv-dns
/var/www/html/isp-client/ferramentas/dns/venv-dns/bin/pip install --upgrade pip
/var/www/html/isp-client/ferramentas/dns/venv-dns/bin/pip install flask psycopg2-binary reportlab

cat << 'EOF' > /etc/systemd/system/dns-metrics-collector.service
[Unit]
Description=VisaoSoft DNS Metrics Daemon Collector
After=network.target unbound.service postgresql.service
[Service]
Type=simple
WorkingDirectory=/var/www/html/isp-client/ferramentas/dns
ExecStart=/var/www/html/isp-client/ferramentas/dns/venv-dns/bin/python /var/www/html/isp-client/ferramentas/dns/dns_metrics_collector.py
Restart=always
User=root
[Install]
WantedBy=multi-user.target
EOF

cat << 'EOF' > /etc/systemd/system/netflow-collector.service
[Unit]
Description=NetFlow Collector Service - VisaoSoft ISP
After=network.target postgresql.service
[Service]
Type=simple
User=root
WorkingDirectory=/var/www/html/isp-client/flow
ExecStart=/usr/bin/python3 -c "import os; os.system('docker exec -i isp-web-php php /var/www/html/isp-client/flow/collector.php')"
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF

mkdir -p /home/flow_logs && chmod 777 /home/flow_logs
mkdir -p /var/www/html/isp-client/flow/data && chmod 777 /var/www/html/isp-client/flow/data
echo "[]" > /var/www/html/isp-client/flow/data/flows.json
echo "{}" > /var/www/html/isp-client/flow/data/stats.json
chmod 777 /var/www/html/isp-client/flow/data/*.json

cat << 'XML' > /etc/logrotate.d/isp-flow
/home/flow_logs/*.log { size 1G rotate 3 compress missingok notifempty copytruncate }
XML

cat << 'XML' > /etc/cron.d/isp-client
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
* * * * * root docker exec -i isp-web-php php /var/www/html/isp-client/mtr/monitoramento/cron/check_targets.php > /dev/null 2>&1
*/5 * * * * root docker exec -i isp-web-php php /var/www/html/isp-client/mtr/advanced/cron/check_all.php > /dev/null 2>&1
* * * * * root docker exec -i isp-web-php php /var/www/html/isp-client/backups/motor_backup.php > /dev/null 2>&1
* * * * * root docker exec -i isp-web-php php /var/www/html/isp-client/flow/cron_flow.php > /dev/null 2>&1
* * * * * root docker exec -i isp-web-php php /var/www/html/isp-client/flow/cron_consolidar.php > /dev/null 2>&1
0 */4 * * * root docker exec -i isp-web-php php /var/www/html/isp-client/app/cron_license.php > /dev/null 2>&1
XML
chmod 644 /etc/cron.d/isp-client

systemctl daemon-reload
systemctl enable netflow-collector.service dns-metrics-collector.service unbound
systemctl restart unbound dns-metrics-collector.service netflow-collector.service
systemctl restart cron

rm -f /etc/resolv.conf
echo "nameserver 127.0.0.1" > /etc/resolv.conf

echo "===================================================="
echo "    INSTALACAO COM CAMADA WEB DOCKER COMPLETADA!"
echo "===================================================="
rm -- "$0"
