#!/bin/bash
# Impedir que o script continue se algum comando falhar
set -e

echo "===================================================="
echo "    INSTALADOR AUTOMATIZADO - VITOR-QUADROS ISP     "
echo "              (VERSÃO DE PRODUÇÃO NATIVA)           "
echo "===================================================="
echo ""

# 🧹 0.1 LIMPEZA ESTRUTURAL COMPLETA BEFORE CLEAN DEPLOY
echo "[*] Removendo instalações, processos e bancos de dados anteriores..."
systemctl stop nginx php8.2-fpm cron netflow-collector freeradius || true
pkill -9 php-fpm || true
pkill -9 php || true

# Derruba conexões presas no Postgres e limpa o banco e o usuário antigo
if systemctl is-active --quiet postgresql; then
    su - postgres -c "psql -c \"SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'isp_client_portal';\"" || true
    su - postgres -c "psql -c \"DROP DATABASE IF EXISTS isp_client_portal WITH (FORCE);\"" || true
    su - postgres -c "psql -c \"DROP USER IF EXISTS isp_client_app;\"" || true
fi

# Passa o rodo nas pastas, crons, chaves e arquivos antigos
rm -rf /var/www/html/isp-client || true
rm -f /etc/cron.d/isp-client || true
rm -f /etc/sudoers.d/www-data-mtr || true
rm -rf /etc/systemd/system/php8.2-fpm.service.d/ || true
rm -f /etc/systemd/system/netflow-collector.service || true
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

# 2. Instalar todas as dependências do sistema, redes, e-mail, freeradius e paramiko nativo
echo "[*] Instalando ferramentas de rede, e-mail, freeradius e linguagens..."
apt-get install -y apt-transport-https ca-certificates curl gnupg wget sudo lsof mtr-tiny socat netcat-openbsd net-tools rsyslog sshpass python3 python3-pip python3-paramiko nodejs msmtp msmtp-mta git cron freeradius freeradius-postgresql

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
echo ""

read -p "Após liberar o acesso no seu GitHub, digite 'OK' e aperte Enter: " CONFIRMACAO
if [ "$CONFIRMACAO" != "OK" ] && [ "$CONFIRMACAO" != "ok" ]; then
    echo "❌ Instalação cancelada pelo usuário."
    exit 1
fi

# Baixando o código via SSH
echo "[*] Baixando o código do sistema do GitHub de forma segura..."
mkdir -p /var/www/html
git clone git@github.com:VITOR-QUADROS1/isp-client.git /var/www/html/isp-client

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

# 🚀 INJEÇÃO DE PARÂMETROS DE INICIALIZAÇÃO (Povoa usuários e a linha de configuração de backups ID=1)
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

# 🔑 CONFIGURAÇÃO DO FREERADIUS CENTRAL HOMOLOGADO (BYPASS DE TABELAS AUSENTES)
echo "[*] Configurando subsistema modular do FreeRADIUS Central..."
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

# Implantação de Serviço Nativo do Coletor NetFlow (Híbrido v5/v9)
echo "[*] Criando serviço nativo do Systemd para o Coletor de Tráfego..."
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

# 🛑 FORMATAÇÃO DO FLOW EM ZERO ABSOLUTO E AJUSTE DE PERMISSÃO CONTRA LOCKS
echo "[*] Formatando base de dados do Flow Monitor em zero absoluto comercial..."
mkdir -p /var/www/html/isp-client/flow/data
echo "[]" > /var/www/html/isp-client/flow/data/flows.json
echo "{}" > /var/www/html/isp-client/flow/data/stats.json
rm -f /var/www/html/isp-client/flow/data/templates.json || true
chown -R www-data:www-data /var/www/html/isp-client/flow/data
chmod -R 775 /var/www/html/isp-client/flow/data

# Ajustar permissões globais e liberar o MTR
chown -R www-data:www-data /var/www/html/isp-client
chown -R www-data:www-data /var/lib/php/sessions
chmod -s /usr/bin/mtr || true
chmod -s /usr/libexec/mtr-packet 2>/dev/null || true
chmod -s /usr/lib/mtr/mtr-packet 2>/dev/null || true
echo "www-data ALL=(ALL) NOPASSWD: /usr/bin/mtr" > /etc/sudoers.d/www-data-mtr
chmod 440 /etc/sudoers.d/www-data-mtr

mkdir -p /etc/systemd/system/php8.2-fpm.service.d/
cat << 'EOF' > /etc/systemd/system/php8.2-fpm.service.d/override.conf
[Service]
NoNewPrivileges=no
EOF
systemctl daemon-reload

# Configurando as Crons do Sistema
cat << 'XML' > /etc/cron.d/isp-client
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
* * * * * www-data /usr/bin/php /var/www/html/isp-client/mtr/monitoramento/cron/check_targets.php > /dev/null 2>&1
*/5 * * * * www-data /usr/bin/php /var/www/html/isp-client/mtr/advanced/cron/check_all.php > /dev/null 2>&1
0 2 * * * www-data /usr/bin/php /var/www/html/isp-client/backups/motor_backup.php > /dev/null 2>&1
* * * * * www-data /usr/bin/php /var/www/html/isp-client/flow/cron_flow.php > /dev/null 2>&1
0 */4 * * * www-data /usr/bin/php /var/www/html/isp-client/app/cron_license.php > /dev/null 2>&1
0 3 * * * root /usr/bin/systemctl restart netflow-collector.service > /dev/null 2>&1
XML

chmod 644 /etc/cron.d/isp-client

# Limpezas finais
rm -f /var/www/html/isp-client/storage/license_state.json || true
find /var/www/html/isp-client/backups/ -name "*.txt" -type f -delete || true

# Inicializando serviços
systemctl daemon-reload
systemctl enable netflow-collector.service freeradius
systemctl restart netflow-collector.service freeradius
systemctl restart cron php8.2-fpm nginx
systemctl enable cron php8.2-fpm nginx

echo "===================================================="
echo "        INSTAÇÃO CONCLUÍDA COM SUCESSO!           "
echo "        LEMBRE-SE DE USAR: https://IP:8081"
echo "===================================================="

# O script se auto-destrói do servidor do cliente para não deixar lixo exposto
rm -- "$0"
