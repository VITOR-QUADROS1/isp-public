#!/bin/bash
# Impedir que o script continue se algum comando falhar
set -e

echo "===================================================="
echo "    INSTALADOR AUTOMATIZADO - VITOR-QUADROS ISP     "
echo "               (VERSÃO DE PRODUÇÃO)                 "
echo "===================================================="
echo ""

# 0.1 LIMPEZA ESTRUTURAL COMPLETA BEFORE CLEAN DEPLOY
echo "[*] Removendo instalações, processos e bancos de dados anteriores..."
systemctl stop nginx php8.2-fpm cron netflow-collector dns-metrics-collector unbound || true
pkill -9 php-fpm || true
pkill -9 php || true

if systemctl is-active --quiet postgresql; then
    su - postgres -c "psql -c \"SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'isp_client_portal';\"" || true
    su - postgres -c "psql -c \"DROP DATABASE IF EXISTS isp_client_portal WITH (FORCE);\"" || true
    su - postgres -c "psql -c \"DROP USER IF EXISTS isp_client_app;\"" || true
fi

rm -rf /var/www/html/isp-client || true
rm -f /etc/cron.d/isp-client || true
rm -f /etc/sudoers.d/www-data-mtr || true
rm -rf /etc/systemd/system/php8.2-fpm.service.d/ || true
rm -f /etc/systemd/system/netflow-collector.service || true
rm -f /etc/systemd/system/dns-metrics-collector.service || true
rm -f /etc/nginx/ssl/isp-client.* || true
systemctl daemon-reload || true

# 0.2 Configurar Repositórios do Debian Minimal
echo "[*] Configurando repositórios oficiais do Debian 12 (Internet)..."
cat << 'EOF' > /etc/apt/sources.list
deb http://deb.debian.org/debian/ bookworm main contrib non-free non-free-firmware
deb-src http://deb.debian.org/debian/ bookworm main contrib non-free non-free-firmware

deb http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
deb-src http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware

deb http://deb.debian.org/debian/ bookworm-updates main contrib non-free non-free-firmware
deb-src http://deb.debian.org/debian/ bookworm-updates main contrib non-free non-free-firmware
EOF

# 1. Atualizar o Sistema com a nova lista de internet
echo "[*] Atualizando a lista de pacotes do Debian 12..."
apt-get update && apt-get upgrade -y

# 2. Instalar todas as dependências do sistema, redes, recursivo e e-mail
echo "[*] Instalando ferramentas de rede, recursivo, e-mail e linguagens..."
apt-get install -y apt-transport-https ca-certificates curl gnupg wget sudo lsof mtr-tiny rsync socat netcat-openbsd net-tools rsyslog sshpass python3 python3-pip python3-venv apparmor-utils unbound dnsutils git cron

# 3. Instalar o Nginx e os Bancos de Dados
echo "[*] Instalando Nginx, PostgreSQL e SQLite..."
apt-get install -y nginx postgresql postgresql-contrib sqlite3

# 4. Instalar o PHP 8.2 e todos os módulos necessários
echo "[*] Instalando PHP 8.2 e extensões..."
apt-get install -y php8.2 php8.2-fpm php8.2-pgsql php8.2-sqlite3 php8.2-curl php8.2-mbstring php8.2-xml php8.2-zip php8.2-gd php8.2-intl php-ssh2 libphp-phpmailer

# 5. Instalar o ambiente gráfico Web para o Winbox (Wine e NoVNC)
echo "[*] Instalando ambiente gráfico para Winbox via navegador..."
apt-get install -y wine xvfb x11vnc novnc fluxbox websockify

# 🚀 6. CONFIGURAÇÃO DA CHAVE SSH COM O GITHUB
echo "[*] Configurando chaves SSH locais..."
mkdir -p /root/.ssh
chmod 700 /root/.ssh

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
echo "👉 PASSO OBRIGATÓRIO:"
echo "1. Copie a chave acima completa (começando em ssh-ed25519 até o fim)."
echo "2. Cadastre no GitHub da VisãoSoft como Deploy Key EXCLUSIVA do projeto ISP-CLIENT-PROD."
echo "====================================================================="
echo ""

read -p "Após liberar o acesso no seu GitHub, digite 'OK' e aperte Enter: " CONFIRMACAO
if [ "$CONFIRMACAO" != "OK" ] && [ "$CONFIRMACAO" != "ok" ]; then
    echo "❌ Instalação cancelada pelo usuário."
    exit 1
fi

# Baixando o código protegido via SSH direto da branch blindada de produção
echo "[*] Baixando a build protegida do GitHub de forma segura..."
mkdir -p /var/www/html
git clone git@github.com:VITOR-QUADROS1/isp-client-prod.git /var/www/html/isp-client

# 🔐 Gerar Certificado SSL Autoassinado para HTTPS (Válido por 10 anos)
echo "[*] Gerando chaves de criptografia SSL para HTTPS..."
mkdir -p /etc/nginx/ssl
openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
  -keyout /etc/nginx/ssl/isp-client.key \
  -out /etc/nginx/ssl/isp-client.crt \
  -subj "/C=BR/ST=RS/L=PortoAlegre/O=VisaoSoft/OU=NOC/CN=visao-soft-isp"

# Configurar Servidor Web Nginx (HTTPS) na Porta 8081
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
    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }
    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.2-fpm.sock;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        include fastcgi_params;
    }
    location ~ /\.ht {
        deny all;
    }
}
XML

ln -sf /etc/nginx/sites-available/isp-client /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default || true

# Configuração do Banco de Dados PostgreSQL
echo "[*] Configurando banco de dados PostgreSQL..."
su - postgres -c "psql -c \"CREATE USER isp_client_app WITH PASSWORD 'Union@2026!';\"" || true
su - postgres -c "psql -c \"CREATE DATABASE isp_client_portal OWNER isp_client_app;\"" || true

# Importa o arquivo de estrutura limpa
echo "[*] Importando tabelas limpas do sistema..."
cat /var/www/html/isp-client/backups/install.sql | sudo -u postgres psql -d isp_client_portal

# 🔥 SEED AUTOMÁTICO: Popula os 14 scripts e fabricantes nativos na interface
echo "[*] Populando fabricantes e injetando scripts de backup padrões de fábrica..."
php /var/www/html/isp-client/backups/seed_backups.php

# 🛠️ CORREÇÃO DE PRIVILÉGIOS E SINCRONISMO DE COLUNAS DO ADVANCED MTR DE FÁBRICA
echo "[*] Aplicando patches de segurança e permissões absolutas de banco de dados..."
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

# 🚀 INJEÇÃO DE PARÂMETROS DE INICIALIZAÇÃO
echo "[*] Injetando usuários administradores e parâmetros padrões de fábrica..."
HASH_MASTER=$(php -r "echo password_hash('VisaoMaster2026', PASSWORD_DEFAULT);")
HASH_CLIENTE=$(php -r "echo password_hash('Mudar@123!', PASSWORD_DEFAULT);")
cat << EOF | sudo -u postgres psql -d isp_client_portal
INSERT INTO client_portal_users (username, password_hash, role, name, email, phone, is_active, created_at, updated_at)
VALUES
('master', '$HASH_MASTER', 'master', 'Master Oculto', 'suporte@visaosoft.com', '5500000000000', true, NOW(), NOW()),
('admin', '$HASH_CLIENTE', 'admin', 'Administrador Local', 'admin@provedor.com', '5500000000000', true, NOW(), NOW())
ON CONFLICT (username) DO NOTHING;
INSERT INTO backup_configuracoes (id, smtp_host, smtp_porta, smtp_usuario, smtp_senha, smtp_from_nome, smtp_from_email, senha_min_caracteres, backup_automatico, backup_horario, backup_avisar_falhas, backup_email_falhas, backup_retencoes)
VALUES (1, 'mail.seusistema.com.br', 587, '', '', 'ISP Backup', '', 6, false, '02:00:00', false, 'noc@seuprovedor.com.br', 10)
ON CONFLICT (id) DO NOTHING;
EOF

# Criar arquivo de credenciais local
echo "[*] Escrevendo arquivo de credenciais local..."
mkdir -p /var/www/html/isp-client/config
cat << EOF > /var/www/html/isp-client/config/env.php
<?php
declare(strict_types=1);
define('DB_PASS', 'Union@2026!');
define('SIRENE_APP_KEY', '$(openssl rand -hex 32)');
EOF

chown root:www-data /var/www/html/isp-client/config/env.php
chmod 640 /var/www/html/isp-client/config/env.php

# ====================================================================
# 🌐 CONFIGURAÇÃO INDUSTRIAL RECURSIVA PURA AUTO-DINÂMICA DO UNBOUND
# ====================================================================
echo "[*] Configurando esqueleto modular do DNS Unbound..."
mkdir -p /var/log/unbound
touch /var/log/unbound/unbound.log
chown -R unbound:unbound /var/log/unbound
chmod 644 /var/log/unbound/unbound.log

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

# Inicializa as ACLs dinâmicas cobrindo todas as faixas privadas de fábrica
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

# Inicializa as chaves de segurança DNSSEC dos Root Servers mundiais
mkdir -p /var/lib/unbound
chown -R unbound:unbound /var/lib/unbound
/usr/sbin/unbound-anchor -a /var/lib/unbound/root.key || true
aa-complain /usr/sbin/unbound || true
echo "www-data ALL=(ALL) NOPASSWD: /usr/bin/systemctl reload unbound" >> /etc/sudoers

# Configura o ambiente virtual Python exclusivo para os daemons de métricas
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

# Implantação de Serviço Nativo do Coletor NetFlow
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

# Redirecionando logs do NetFlow para o /home
mkdir -p /home/flow_logs
chown -R www-data:www-data /home/flow_logs
rm -rf /var/www/html/isp-client/flow/logs || true
ln -s /home/flow_logs /var/www/html/isp-client/flow/logs

# Configurando monitoramento e autolimpeza dos logs
cat << 'XML' > /etc/logrotate.d/isp-flow
/home/flow_logs/*.log {
      size 1G
      rotate 3
      compress
      missingok
      notifempty
      copytruncate
}
XML

# 🛑 FORMATAÇÃO DO FLOW EM ZERO ABSOLUTO
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

# 🔄 CONFIGURAÇÃO DAS CRONS EM MODO DINÂMICO
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
systemctl enable netflow-collector.service dns-metrics-collector.service unbound
systemctl restart unbound dns-metrics-collector.service netflow-collector.service
systemctl restart cron php8.2-fpm nginx
systemctl enable cron php8.2-fpm nginx

# 🌐 AUTO-RESOLUÇÃO: Aponta o DNS da própria máquina para ela mesma consultar direto na raiz (Última linha)
rm -f /etc/resolv.conf
echo "nameserver 127.0.0.1" > /etc/resolv.conf

echo "===================================================="
echo "        INSTALAÇÃO CONCLUÍDA COM SUCESSO!           "
echo "        LEMBRE-SE DE USAR: https://IP:8081"
echo "===================================================="
rm -- "$0"
