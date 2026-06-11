#!/bin/bash
# Impedir que o script continue se algum comando falhar
set -e

echo "===================================================="
echo "    INSTALADOR AUTOMATIZADO - VITOR-QUADROS ISP     "
echo "               (VERSÃO DE LAB NATIVA)               "
echo "===================================================="
echo ""

# 0. LIMPEZA ESTRUTURAL COMPLETA BEFORE CLEAN DEPLOY
echo "[*] Removendo instalações, processos e daemons anteriores..."
systemctl stop nginx php8.2-fpm cron netflow-collector dns-metrics-collector unbound krill routinator freeradius || true
pkill -9 php-fpm || true
pkill -9 php || true

if systemctl is-active --quiet postgresql; then
    su - postgres -c "psql -c \"SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'isp_client_portal';\"" || true
    su - postgres -c "psql -c \"DROP DATABASE IF EXISTS isp_client_portal WITH (FORCE);\"" || true
    su - postgres -c "psql -c \"DROP USER IF EXISTS isp_client_app;\"" || true
fi

rm -rf /var/www/html/isp-client || true
rm -f /etc/cron.d/isp-client /etc/sudoers.d/www-data-mtr || true
rm -rf /etc/systemd/system/php8.2-fpm.service.d/ || true
rm -f /etc/systemd/system/netflow-collector.service /etc/systemd/system/dns-metrics-collector.service /etc/nginx/ssl/isp-client.* || true
systemctl daemon-reload || true

# 1. REPOSITÓRIOS
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

echo "[*] Instalando dependências essenciais do sistema..."
apt-get install -y apt-transport-https ca-certificates curl gnupg wget sudo lsof mtr-tiny rsync socat netcat-openbsd net-tools rsyslog sshpass python3 python3-pip python3-venv apparmor-utils unbound dnsutils git cron nginx postgresql postgresql-contrib sqlite3 php8.2 php8.2-fpm php8.2-pgsql php8.2-sqlite3 php8.2-curl php8.2-mbstring php8.2-xml php8.2-zip php8.2-gd php8.2-intl php-ssh2 libphp-phpmailer wine xvfb x11vnc novnc fluxbox websockify freeradius freeradius-postgresql

# 2. INSTALAÇÃO RPKI (NLNET LABS)
echo "[*] Adicionando repositório NLnet Labs e instalando Routinator e Krill..."
curl -fsSL https://packages.nlnetlabs.nl/aptkey.asc | gpg --dearmor -o /usr/share/keyrings/nlnetlabs-archive-keyring.gpg || true
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/nlnetlabs-archive-keyring.gpg] https://packages.nlnetlabs.nl/linux/debian bookworm main" > /etc/apt/sources.list.d/nlnetlabs.list
apt-get update
apt-get install -y routinator krill

# 3. CHAVES SSH DINÂMICAS
echo "[*] Configurando chaves SSH locais..."
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
git clone git@github.com:VITOR-QUADROS1/isp-client.git /var/www/html/isp-client

# ====================================================================
# 🛠️ AMBIENTE DE DESENVOLVIMENTO (LAB): OFUSCADOR INTERNO
# ====================================================================
echo "[*] Instalando motor de ofuscação PHP (Yakpro-PO)..."
cd /opt
rm -rf PHP-Parser yakpro-po || true
git clone https://github.com/nikic/PHP-Parser.git
git clone https://github.com/pk-fr/yakpro-po.git
cd yakpro-po
git clone https://github.com/nikic/PHP-Parser.git
chmod +x yakpro-po.php
ln -sf /opt/yakpro-po/yakpro-po.php /usr/local/bin/yakpro-po

echo "[*] Configurando exceptions do Ofuscador (Ignorando pasta vendor)..."
cat << 'YAKCONF' > /opt/yakpro-po/yakpro-po.cnf
<?php
$conf->source_directory = null;
$conf->target_directory = null;
$conf->obfuscate_constant_name = true;
$conf->obfuscate_variable_name = true;
$conf->obfuscate_function_name = true;
$conf->obfuscate_class_name    = true;
$conf->ignore_file_path_names  = array("/vendor");
YAKCONF

echo "[*] Clonando repositório de Produção para permitir o Deploy Automático..."
cd /var/www/html/
git clone git@github.com:VITOR-QUADROS1/isp-client-prod.git || true
chmod +x /var/www/html/isp-client/deploy.sh || true
# ====================================================================

echo "[*] Gerando chaves de criptografia SSL para HTTPS..."
mkdir -p /etc/nginx/ssl
openssl req -x509 -nodes -days 3650 -newkey rsa:2048 -keyout /etc/nginx/ssl/isp-client.key -out /etc/nginx/ssl/isp-client.crt -subj "/C=BR/ST=RS/L=PortoAlegre/O=VisaoSoft/OU=NOC/CN=visao-soft-isp" 2>/dev/null

echo "[*] Configurando Servidor Web Nginx para a porta 8081 (HTTPS)..."
cat << 'XML' > /etc/nginx/sites-available/isp-client
server {
    listen 8081 ssl default_server;
    listen [::]:8081 ssl default_server;
    server_name _;
    root /var/www/html/isp-client;
    index login.php index.php index.html;
    ssl_certificate /etc/nginx/ssl/isp-client.crt;
    ssl_certificate_key /etc/nginx/ssl/isp-client.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    location / { try_files $uri $uri/ /index.php?$query_string; }
    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.2-fpm.sock;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        include fastcgi_params;
    }
    location ~ /\.ht { deny all; }
}
XML
ln -sf /etc/nginx/sites-available/isp-client /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default || true

echo "[*] Configurando banco de dados PostgreSQL..."
su - postgres -c \"CREATE USER isp_client_app WITH PASSWORD 'Union@2026!';\" || true
su - postgres -c \"CREATE DATABASE isp_client_portal OWNER isp_client_app;\" || true

cat /var/www/html/isp-client/backups/install.sql | sudo -u postgres psql -d isp_client_portal
php /var/www/html/isp-client/backups/seed_backups.php

echo "[*] Aplicando patches de segurança e permissões..."
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
HASH_MASTER=$(php -r "echo password_hash('VisaoMaster2026', PASSWORD_DEFAULT);")
HASH_CLIENTE=$(php -r "echo password_hash('Mudar@123!', PASSWORD_DEFAULT);")
cat << 'EOF' | sudo -u postgres psql -d isp_client_portal
INSERT INTO client_portal_users (username, password_hash, role, name, email, phone, is_active, created_at, updated_at) VALUES ('master', '$HASH_MASTER', 'master', 'Master Oculto', 'suporte@visaosoft.com', '5500000000000', true, NOW(), NOW()), ('admin', '$HASH_CLIENTE', 'admin', 'Administrador Local', 'admin@provedor.com', '5500000000000', true, NOW(), NOW()) ON CONFLICT (username) DO NOTHING;
INSERT INTO backup_configuracoes (id, smtp_host, smtp_porta, smtp_usuario, smtp_senha, smtp_from_nome, smtp_from_email, senha_min_caracteres, backup_automatico, backup_horario, backup_avisar_falhas, backup_email_falhas, backup_retencoes) VALUES (1, 'mail.seusistema.com.br', 587, '', '', 'ISP Backup', '', 6, false, '02:00:00', false, 'noc@seuprovedor.com.br', 10) ON CONFLICT (id) DO NOTHING;
EOF

mkdir -p /var/www/html/isp-client/config
cat << EOF > /var/www/html/isp-client/config/env.php
<?php
declare(strict_types=1);
define('DB_PASS', 'Union@2026!');
define('SIRENE_APP_KEY', '$(openssl rand -hex 32)');
EOF
chown root:www-data /var/www/html/isp-client/config/env.php && chmod 640 /var/www/html/isp-client/config/env.php

echo "[*] Configurando o modulo SQL do FreeRADIUS..."
cat << 'RADIUS_CONF' > /etc/freeradius/3.0/mods-enabled/sql
sql {
    driver = "rlm_sql_postgresql"
    dialect = "postgresql"
    server = "127.0.0.1"
    port = 5432
    login = "isp_client_app"
    password = "Union@2026!"
    radius_db = "isp_client_portal"
    client_table = "nas"
    authcheck_table = "radcheck"
    authreply_table = "radreply"
    groupcheck_table = "radgroupcheck"
    groupreply_table = "radgroupreply"
    usergroup_table = "radusergroup"
    acct_table1 = "radacct"
    acct_table2 = "radacct"
    postauth_table = "radpostauth"
    group_attribute = "SQL-Group"
    read_clients = yes
    read_groups = yes
    read_profiles = yes
    delete_stale_sessions = yes
    sql_user_name = "%{User-Name}"
    default_user_profile = ""
    client_query = "SELECT id,nasname,shortname,type,secret FROM nas"
    safe_characters = "@abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_: /"
    auto_escape = no
    pool {
        start = 5
        min = 3
        max = 32
        spare = 10
        idle_timeout = 60
        retry_delay = 30
    }
    $include /etc/freeradius/3.0/mods-config/sql/main/postgresql/queries.conf
    authorize {
        authorize_reply_query = "SELECT 1 WHERE 1=0"
    }
}
RADIUS_CONF
ln -sf /etc/freeradius/3.0/mods-available/sql /etc/freeradius/3.0/mods-enabled/sql || true
chown -R freerad:freerad /etc/freeradius/3.0/

echo "[*] Configurando DNS Unbound RECURSIVO PURO..."
mkdir -p /var/log/unbound && touch /var/log/unbound/unbound.log
chown -R unbound:unbound /var/log/unbound && chmod 644 /var/log/unbound/unbound.log
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
/usr/sbin/unbound-anchor -a /var/lib/unbound/root.key || true
aa-complain /usr/sbin/unbound || true
echo "www-data ALL=(ALL) NOPASSWD: /usr/bin/systemctl reload unbound" >> /etc/sudoers

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
User=www-data
Group=www-data
WorkingDirectory=/var/www/html/isp-client/flow
ExecStart=/usr/bin/php /var/www/html/isp-client/flow/collector.php
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF

echo "[*] Configurando daemons do RPKI (Routinator e Krill)..."
cat << 'EOF' > /etc/routinator/routinator.conf
repository-dir = "/var/lib/routinator/repository"
rtr-listen = ["0.0.0.0:3323"]
http-listen = ["127.0.0.1:8323"]
log-level = "info"
EOF
chown -R routinator:routinator /var/lib/routinator /etc/routinator

cat << 'EOF' > /etc/krill.conf
ip = "0.0.0.0"
port = 3000
auth_token = "d7kLj4HxFlgLIk4DxMgXLMU2GAdkIGVu"
data_dir = "/var/lib/krill/data"
log_type = "syslog"
log_level = "info"
EOF
mkdir -p /var/log/krill /var/lib/krill/data
chown krill:krill /etc/krill.conf
chown -R krill:krill /var/log/krill /var/lib/krill

mkdir -p /home/flow_logs && chown -R www-data:www-data /home/flow_logs
rm -rf /var/www/html/isp-client/flow/logs || true
ln -s /home/flow_logs /var/www/html/isp-client/flow/logs

cat << 'XML' > /etc/logrotate.d/isp-flow
/home/flow_logs/*.log { size 1G rotate 3 compress missingok notifempty copytruncate }
XML

mkdir -p /var/www/html/isp-client/flow/data
echo "[]" > /var/www/html/isp-client/flow/data/flows.json
echo "{}" > /var/www/html/isp-client/flow/data/stats.json
rm -f /var/www/html/isp-client/flow/data/templates.json || true
chown -R www-data:www-data /var/www/html/isp-client/flow/data
chmod -R 775 /var/www/html/isp-client/flow/data

chown -R www-data:www-data /var/www/html/isp-client
chown -R www-data:www-data /var/lib/php/sessions
echo "www-data ALL=(ALL) NOPASSWD: /usr/bin/mtr" > /etc/sudoers.d/www-data-mtr
chmod 440 /etc/sudoers.d/www-data-mtr

mkdir -p /etc/systemd/system/php8.2-fpm.service.d/
cat << 'EOF' > /etc/systemd/system/php8.2-fpm.service.d/override.conf
[Service]
NoNewPrivileges=no
EOF
systemctl daemon-reload

cat << 'XML' > /etc/cron.d/isp-client
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
* * * * * www-data /usr/bin/php /var/www/html/isp-client/mtr/monitoramento/cron/check_targets.php > /dev/null 2>&1
*/5 * * * * www-data /usr/bin/php /var/www/html/isp-client/mtr/advanced/cron/check_all.php > /dev/null 2>&1
* * * * * www-data /usr/bin/php /var/www/html/isp-client/backups/motor_backup.php > /dev/null 2>&1
* * * * * www-data /usr/bin/php /var/www/html/isp-client/flow/cron_flow.php > /dev/null 2>&1
* * * * * www-data /usr/bin/php /var/www/html/isp-client/flow/cron_consolidar.php > /dev/null 2>&1
0 */4 * * * www-data /usr/bin/php /var/www/html/isp-client/app/cron_license.php > /dev/null 2>&1
0 3 * * * root /usr/bin/systemctl restart netflow-collector.service > /dev/null 2>&1
XML
chmod 644 /etc/cron.d/isp-client

rm -f /var/www/html/isp-client/storage/license_state.json || true
find /var/www/html/isp-client/backups/ -name "*.txt" -type f -delete || true

systemctl daemon-reload
systemctl enable netflow-collector.service dns-metrics-collector.service unbound routinator krill freeradius
systemctl reset-failed krill || true
systemctl restart unbound dns-metrics-collector.service netflow-collector.service routinator krill freeradius
systemctl restart cron php8.2-fpm nginx
systemctl enable cron php8.2-fpm nginx

rm -f /etc/resolv.conf
echo "nameserver 127.0.0.1" > /etc/resolv.conf

echo "===================================================="
echo "        INSTALACAO CONCLUIDA COM SUCESSO!"
echo "===================================================="
rm -- "$0"
