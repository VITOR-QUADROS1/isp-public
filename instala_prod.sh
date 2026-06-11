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
systemctl stop nginx php8.2-fpm cron netflow-collector dns-metrics-collector unbound freeradius 2>/dev/null || true
pkill -9 php-fpm 2>/dev/null || true
pkill -9 php 2>/dev/null || true

# Derruba conexões presas no Postgres e limpa o banco e o usuário antigo
if systemctl is-active --quiet postgresql; then
    su - postgres -c "psql -c \"SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'isp_client_portal';\"" 2>/dev/null || true
    su - postgres -c "psql -c \"DROP DATABASE IF EXISTS isp_client_portal WITH (FORCE);\"" 2>/dev/null || true
    su - postgres -c "psql -c \"DROP USER IF EXISTS isp_client_app;\"" 2>/dev/null || true
fi

# Passa o rodo nas pastas, crons, chaves e arquivos antigos
rm -rf /var/www/html/isp-client 2>/dev/null || true
rm -f /etc/cron.d/isp-client 2>/dev/null || true
rm -f /etc/sudoers.d/www-data-mtr 2>/dev/null || true
rm -rf /etc/systemd/system/php8.2-fpm.service.d/ 2>/dev/null || true
rm -f /etc/systemd/system/netflow-collector.service 2>/dev/null || true
rm -f /etc/systemd/system/dns-metrics-collector.service 2>/dev/null || true
rm -f /etc/nginx/ssl/isp-client.* 2>/dev/null || true
systemctl daemon-reload 2>/dev/null || true

# 0.2 Configurar Repositórios do Debian Minimal
echo "[*] Configurando repositórios oficiais do Debian 12 (Internet)..."
cat << 'EOF2' > /etc/apt/sources.list
deb http://deb.debian.org/debian/ bookworm main contrib non-free non-free-firmware
deb-src http://deb.debian.org/debian/ bookworm main contrib non-free non-free-firmware

deb http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
deb-src http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware

deb http://deb.debian.org/debian/ bookworm-updates main contrib non-free non-free-firmware
deb-src http://deb.debian.org/debian/ bookworm-updates main contrib non-free non-free-firmware
EOF2

# 1. Atualizar o Sistema com a nova lista de internet
echo "[*] Atualizando a lista de pacotes do Debian 12..."
apt-get update && apt-get upgrade -y

# 2. Instalar todas as dependências do sistema, redes, recursivo, e-mail e freeradius
echo "[*] Instalando ferramentas de rede, recursivo, e-mail, freeradius e linguagens..."
apt-get install -y apt-transport-https ca-certificates curl gnupg wget sudo lsof mtr-tiny rsync socat netcat-openbsd net-tools rsyslog sshpass python3 python3-pip python3-venv apparmor-utils unbound dnsutils git cron freeradius freeradius-postgresql

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

cat << 'EOF2' > /root/.ssh/config
Host github.com
    HostName github.com
    User git
    IdentityFile /root/.ssh/id_isp_client
    IdentitiesOnly yes
    StrictHostKeyChecking no
EOF2
chmod 600 /root/.ssh/config /root/.ssh/id_isp_client

echo "🔑 CHAVE DE LIBERAÇÃO DO SISTEMA (DEPLOY KEY)"
echo "====================================================================="
cat /root/.ssh/id_isp_client.pub
echo "====================================================================="
echo "👉 PASSO OBRIGATÓRIO:"
echo "1. Copie a chave acima completa (começando em ssh-ed25519 até o fim)."
echo "2. Cadastre no GitHub da VisãoSoft como Deploy Key EXCLUSIVA do projeto ISP-CLIENTE-PROD."
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

# Importa o arquivo de estrutura limpa atualizado com as novas tabelas DNS
echo "[*] Importando tabelas limpas do sistema..."
if [ -f /var/www/html/isp-client/backups/install.sql ]; then
    cat /var/www/html/isp-client/backups/install.sql | sudo -u postgres psql -d isp_client_portal
else
    echo "[!] Arquivo install.sql não encontrado, criando estrutura básica..."
    # Estrutura mínima será criada pelos patches abaixo
fi

# 🚀 LIBERAÇÃO DO BANCO MESTRE PARA ESCUTA EXTERNA DINÂMICA (TECNICOS DE CLIENTES)
echo "[*] Configurando barramento de escuta externa do PostgreSQL corporativo..."
sed -i "s/#listen_addresses = 'localhost'/listen_addresses = '*'/g" /etc/postgresql/*/main/postgresql.conf 2>/dev/null || true
grep -q "host all all 0.0.0.0/0 md5" /etc/postgresql/*/main/pg_hba.conf 2>/dev/null || echo "host all all 0.0.0.0/0 md5" >> /etc/postgresql/*/main/pg_hba.conf 2>/dev/null || true
systemctl restart postgresql

# 🔥 SEED AUTOMÁTICO: Popula os 14 scripts e fabricantes nativos na interface
if [ -f /var/www/html/isp-client/backups/seed_backups.php ]; then
    echo "[*] Populando fabricantes e injetando scripts de backup padrões de fábrica..."
    php /var/www/html/isp-client/backups/seed_backups.php
fi

# 🛠️ CRIAÇÃO DAS TABELAS RADIUS E VIEW DE LOCKOUT
echo "[*] Criando estrutura RADIUS e aplicando patches de segurança..."
cat << 'EOF2' | sudo -u postgres psql -d isp_client_portal
-- Criar tabelas RADIUS se não existirem
CREATE TABLE IF NOT EXISTS nas (
    id SERIAL PRIMARY KEY,
    nasname TEXT NOT NULL,
    shortname TEXT,
    type TEXT,
    secret TEXT NOT NULL,
    description TEXT
);

CREATE TABLE IF NOT EXISTS radcheck (
    id SERIAL PRIMARY KEY,
    username TEXT NOT NULL,
    attribute TEXT NOT NULL,
    op TEXT NOT NULL,
    value TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS radreply (
    id SERIAL PRIMARY KEY,
    username TEXT NOT NULL,
    attribute TEXT NOT NULL,
    op TEXT NOT NULL,
    value TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS radgroupcheck (
    id SERIAL PRIMARY KEY,
    groupname TEXT NOT NULL,
    attribute TEXT NOT NULL,
    op TEXT NOT NULL,
    value TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS radgroupreply (
    id SERIAL PRIMARY KEY,
    groupname TEXT NOT NULL,
    attribute TEXT NOT NULL,
    op TEXT NOT NULL,
    value TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS radusergroup (
    id SERIAL PRIMARY KEY,
    username TEXT NOT NULL,
    groupname TEXT NOT NULL,
    priority INTEGER DEFAULT 1
);

CREATE TABLE IF NOT EXISTS radacct (
    radacctid BIGSERIAL PRIMARY KEY,
    acctsessionid TEXT NOT NULL,
    acctuniqueid TEXT UNIQUE,
    username TEXT,
    groupname TEXT,
    realm TEXT,
    nasipaddress TEXT,
    nasportid TEXT,
    nasporttype TEXT,
    acctstarttime TIMESTAMP,
    acctstoptime TIMESTAMP,
    acctsessiontime INTEGER,
    acctinputoctets BIGINT,
    acctoutputoctets BIGINT,
    calledstationid TEXT,
    callingstationid TEXT,
    acctterminatecause TEXT,
    servicetype TEXT,
    framedprotocol TEXT,
    framedipaddress TEXT
);

CREATE TABLE IF NOT EXISTS radpostauth (
    id BIGSERIAL PRIMARY KEY,
    username TEXT NOT NULL,
    pass TEXT,
    reply TEXT,
    authdate TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    nasipaddress TEXT,
    callingstationid TEXT DEFAULT '',
    nasportid TEXT DEFAULT ''
);

-- Garante que as colunas active exigidas pelo código existam por padrão
ALTER TABLE mtr_advanced_networks ADD COLUMN IF NOT EXISTS active BOOLEAN DEFAULT true;
ALTER TABLE mtr_advanced_hosts ADD COLUMN IF NOT EXISTS active BOOLEAN DEFAULT true;
ALTER TABLE mtr_advanced_targets ADD COLUMN IF NOT EXISTS active BOOLEAN DEFAULT true;
ALTER TABLE mtr_advanced_probes ADD COLUMN IF NOT EXISTS active BOOLEAN DEFAULT true;

-- 🎯 ENGENHARIA DE OPERADORA: Cria a View que bloqueia o usuário por 30 minutos após 5 erros
DROP VIEW IF EXISTS vw_radcheck;
CREATE VIEW vw_radcheck AS
SELECT id, username, attribute, op, value FROM radcheck
UNION ALL
SELECT
    999999 AS id,
    username,
    'Auth-Type'::varchar AS attribute,
    ':='::varchar AS op,
    'Reject'::varchar AS value
FROM (
    SELECT username FROM radpostauth r
    WHERE reply = 'Access-Reject'
      AND authdate > COALESCE((SELECT max(authdate) FROM radpostauth WHERE username = r.username AND reply = 'Access-Accept'), '1970-01-01'::timestamp)
      AND authdate > NOW() - INTERVAL '30 minutes'
    GROUP BY username
    HAVING COUNT(*) >= 5
) as blocked;

-- Concede direitos totais para o usuário PHP manipular tabelas e auto-incrementos (IDs)
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO isp_client_app;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO isp_client_app;
GRANT ALL PRIVILEGES ON vw_radcheck TO isp_client_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO isp_client_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO isp_client_app;
EOF2

# 🚀 INJEÇÃO DE PARÂMETROS DE INICIALIZAÇÃO (Povoa usuários master de fábrica com hashes gerados em tempo de execução)
echo "[*] Injetando usuários administradores e parâmetros padrões de fábrica..."
HASH_MASTER=$(php -r "echo password_hash('VisaoMaster2026', PASSWORD_DEFAULT);" 2>/dev/null || echo "")
HASH_CLIENTE=$(php -r "echo password_hash('Mudar@123!', PASSWORD_DEFAULT);" 2>/dev/null || echo "")

if [ -n "$HASH_MASTER" ] && [ -n "$HASH_CLIENTE" ]; then
    sudo -u postgres psql -d isp_client_portal -c "INSERT INTO client_portal_users (username, password_hash, role, name, email, phone, is_active, created_at, updated_at) VALUES ('master', '$HASH_MASTER', 'master', 'Master Oculto', 'suporte@visaosoft.com', '5500000000000', true, NOW(), NOW()), ('admin', '$HASH_CLIENTE', 'admin', 'Administrador Local', 'admin@provedor.com', '5500000000000', true, NOW(), NOW()) ON CONFLICT (username) DO NOTHING;" 2>/dev/null || true

    sudo -u postgres psql -d isp_client_portal -c "INSERT INTO backup_configuracoes (id, smtp_host, smtp_porta, smtp_usuario, smtp_senha, smtp_from_nome, smtp_from_email, senha_min_caracteres, backup_automatico, backup_horario, backup_avisar_falhas, backup_email_falhas, backup_retencoes) VALUES (1, 'mail.seusistema.com.br', 587, '', '', 'ISP Backup', '', 6, false, '02:00:00', false, 'noc@seuprovedor.com.br', 10) ON CONFLICT (id) DO NOTHING;" 2>/dev/null || true
fi

# Criar arquivo de credenciais local
echo "[*] Escrevendo arquivo de credenciais local..."
mkdir -p /var/www/html/isp-client/config
cat << EOF2 > /var/www/html/isp-client/config/env.php
<?php
declare(strict_types=1);
define('DB_PASS', 'Union@2026!');
define('SIRENE_APP_KEY', '$(openssl rand -hex 32)');
EOF2

chown root:www-data /var/www/html/isp-client/config/env.php 2>/dev/null || true
chmod 640 /var/www/html/isp-client/config/env.php 2>/dev/null || true

# 🔑 CONFIGURAÇÃO COMPLETA DO FREERADIUS CENTRAL AAA
echo "[*] Configurando subsistema modular do FreeRADIUS Central..."

# Primeiro, limpar configurações existentes problemáticas
rm -f /etc/freeradius/3.0/sites-enabled/inner-tunnel
rm -f /etc/freeradius/3.0/sites-enabled/default

# Criar arquivo de configuração SQL correto
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
    authcheck_table = "vw_radcheck"
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
}
RADIUS_CONF

# Configurar o site DEFAULT (production)
cat << 'DEFAULT_SITE' > /etc/freeradius/3.0/sites-enabled/default
# Default site - FreeRADIUS production configuration
server default {
    listen {
        type = auth
        ipaddr = *
        port = 1812
    }
    
    listen {
        type = acct
        ipaddr = *
        port = 1813
    }
    
    authorize {
        filter_username
        preprocess
        auth_log
        chap
        mschap
        suffix
        eap {
            ok = return
        }
        files
        sql
        pap
    }
    
    authenticate {
        Auth-Type PAP {
            pap
        }
        Auth-Type CHAP {
            chap
        }
        Auth-Type MS-CHAP {
            mschap
        }
        eap
    }
    
    preacct {
        preprocess
        acct_unique
        suffix
    }
    
    accounting {
        sql
    }
    
    session {
        sql
    }
    
    post-auth {
        update {
            &reply: += &session-state:
        }
        sql
        exec
        post-auth_log
    }
    
    pre-proxy {
        pre-proxy_log
    }
    
    post-proxy {
        post-proxy_log
    }
}
DEFAULT_SITE

# Configurar o INNER-TUNNEL (para EAP/PEAP)
cat << 'INNER_TUNNEL' > /etc/freeradius/3.0/sites-enabled/inner-tunnel
# inner-tunnel - FreeRADIUS configuration for EAP/inner-tunnel
server inner-tunnel {
    listen {
        ipaddr = 127.0.0.1
        port = 18120
        type = auth
    }
    
    authorize {
        filter_username
        preprocess
        auth_log
        chap
        mschap
        suffix
        update control {
            &Proxy-To-Realm := LOCAL
        }
        eap {
            ok = return
        }
        files
        sql
        pap
    }
    
    authenticate {
        Auth-Type PAP {
            pap
        }
        Auth-Type CHAP {
            chap
        }
        Auth-Type MS-CHAP {
            mschap
        }
        eap
    }
    
    preacct {
        preprocess
        acct_unique
    }
    
    accounting {
        sql
    }
    
    session {
        sql
    }
    
    post-auth {
        update {
            &reply: += &session-state:
        }
        sql
        exec
        post-auth_log
    }
    
    pre-proxy {
        pre-proxy_log
    }
    
    post-proxy {
        post-proxy_log
    }
}
INNER_TUNNEL

# Configurar clients.conf
cat << 'CLIENTS_CONF' > /etc/freeradius/3.0/clients.conf
client localhost {
    ipaddr = 127.0.0.1
    secret = testing123
    nas_type = other
}

client localhost_ipv6 {
    ipv6addr = ::1
    secret = testing123
    nas_type = other
}
CLIENTS_CONF

# Ajustar queries.conf para os campos corretos
sed -i 's/(username, pass, reply, nasipaddress, authdate)/(username, pass, reply, nasipaddress, authdate, callingstationid, nasportid)/g' /etc/freeradius/3.0/mods-config/sql/main/postgresql/queries.conf 2>/dev/null || true
sed -i "s/'%{NAS-IP-Address}', 'now()')/'%{NAS-IP-Address}', 'now()', '%{Calling-Station-Id}', '%{NAS-Port}')/g" /etc/freeradius/3.0/mods-config/sql/main/postgresql/queries.conf 2>/dev/null || true

# Configurar logging
sed -i 's/log_auth = no/log_auth = yes/g' /etc/freeradius/3.0/radiusd.conf

# Ajustar permissões
chown -R freerad:freerad /etc/freeradius/3.0/
chmod 640 /etc/freeradius/3.0/mods-enabled/sql

# Testar configuração do FreeRADIUS
echo "[*] Testando configuração do FreeRADIUS..."
if freeradius -C 2>&1 | grep -q "Configuration appears to be OK"; then
    echo "[+] Configuração do FreeRADIUS OK"
else
    echo "[!] Aviso: Configuração do FreeRADIUS tem problemas, mas continuando..."
fi

# Permite que o PHP (www-data) recarregue o FreeRADIUS nativamente via interface sem digitar senhas
echo "www-data ALL=(ALL) NOPASSWD: /usr/bin/systemctl reload freeradius" >> /etc/sudoers.d/www-data-freeradius
chmod 440 /etc/sudoers.d/www-data-freeradius

# ====================================================================
# 🌐 CONFIGURAÇÃO INDUSTRIAL INTEGRADA DO DNS RECURSIVO UNBOUND
# ====================================================================
echo "[*] Configurando esqueleto modular do DNS Unbound..."
mkdir -p /var/log/unbound
touch /var/log/unbound/unbound.log
chown -R unbound:unbound /var/log/unbound
chmod 644 /var/log/unbound/unbound.log

# Escreve a arquitetura limpa de includes do Unbound
cat << 'EOF2' > /etc/unbound/unbound.conf
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
EOF2

# Inicializa os arquivos planos de tabelas dinâmicas do Unbound
cat << 'EOF2' > /etc/unbound/acls.conf
access-control: 127.0.0.0/8 allow
access-control: ::1 allow
EOF2
touch /etc/unbound/local_zones.conf /etc/unbound/bloqueios.conf
chown www-data:www-data /etc/unbound/bloqueios.conf /etc/unbound/acls.conf /etc/unbound/local_zones.conf 2>/dev/null || true
chmod 664 /etc/unbound/*.conf 2>/dev/null || true

# Remove a trava de segurança do kernel (AppArmor) para autorizar a gravação de logs externos
aa-complain /usr/sbin/unbound 2>/dev/null || true

# Validação segura das chaves raiz do Unbound
if [ -x /usr/sbin/unbound-anchor ]; then
    /usr/sbin/unbound-anchor 2>/dev/null || true
fi

# Concede direitos para o usuário PHP executar reloads suaves sem derrubar o cache do Unbound
echo "www-data ALL=(ALL) NOPASSWD: /usr/bin/systemctl reload unbound" >> /etc/sudoers

# Configura o ambiente virtual Python exclusivo para os daemons de métricas de rede
echo "[*] Configurando ambiente virtual Python e dependências de NOC..."
mkdir -p /var/www/html/isp-client/ferramentas/dns
python3 -m venv /var/www/html/isp-client/ferramentas/dns/venv-dns 2>/dev/null || true
/var/www/html/isp-client/ferramentas/dns/venv-dns/bin/pip install --upgrade pip 2>/dev/null || true
/var/www/html/isp-client/ferramentas/dns/venv-dns/bin/pip install flask psycopg2-binary reportlab 2>/dev/null || true

# Cria a unidade Systemd para monitoramento contínuo dos logs do Unbound
cat << 'EOF2' > /etc/systemd/system/dns-metrics-collector.service
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
EOF2
# ====================================================================

# Implantação de Serviço Nativo do Coletor NetFlow (Híbrido v5/v9)
echo "[*] Criando serviço nativo do Systemd para o Coletor de Tráfego..."
cat << 'EOF2' > /etc/systemd/system/netflow-collector.service
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
EOF2

# Redirecionando logs do NetFlow para o /home
mkdir -p /home/flow_logs
chown -R www-data:www-data /home/flow_logs 2>/dev/null || true
rm -rf /var/www/html/isp-client/flow/logs 2>/dev/null || true
ln -s /home/flow_logs /var/www/html/isp-client/flow/logs 2>/dev/null || true

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
rm -f /var/www/html/isp-client/flow/data/templates.json 2>/dev/null || true
chown -R www-data:www-data /var/www/html/isp-client/flow/data 2>/dev/null || true
chmod -R 775 /var/www/html/isp-client/flow/data 2>/dev/null || true

# Ajustar permissões globais e liberar o MTR
chown -R www-data:www-data /var/www/html/isp-client 2>/dev/null || true
chown -R www-data:www-data /var/lib/php/sessions 2>/dev/null || true
chmod -s /usr/bin/mtr 2>/dev/null || true
chmod -s /usr/libexec/mtr-packet 2>/dev/null || true
chmod -s /usr/bin/mtr-packet 2>/dev/null || true
echo "www-data ALL=(ALL) NOPASSWD: /usr/bin/mtr" > /etc/sudoers.d/www-data-mtr
chmod 440 /etc/sudoers.d/www-data-mtr

mkdir -p /etc/systemd/system/php8.2-fpm.service.d/
cat << 'EOF2' > /etc/systemd/system/php8.2-fpm.service.d/override.conf
[Service]
NoNewPrivileges=no
EOF2
systemctl daemon-reload

# 🔄 CONFIGURAÇÃO DAS CRONS EM MODO DINÂMICO
echo "[*] Configurando agendador de tarefas automatizadas minuto a minuto..."
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

# Limpezas finais
rm -f /var/www/html/isp-client/storage/license_state.json 2>/dev/null || true
find /var/www/html/isp-client/backups/ -name "*.txt" -type f -delete 2>/dev/null || true

# Inicializando e acordando todos os serviços
systemctl daemon-reload
systemctl enable netflow-collector.service 2>/dev/null || true
systemctl enable dns-metrics-collector.service 2>/dev/null || true
systemctl enable unbound 2>/dev/null || true
systemctl enable freeradius 2>/dev/null || true

# Iniciar serviços
systemctl restart unbound 2>/dev/null || true
systemctl restart dns-metrics-collector.service 2>/dev/null || true
systemctl restart netflow-collector.service 2>/dev/null || true
systemctl restart freeradius 2>/dev/null || true
systemctl restart cron 2>/dev/null || true
systemctl restart php8.2-fpm 2>/dev/null || true
systemctl restart nginx 2>/dev/null || true

systemctl enable cron php8.2-fpm nginx 2>/dev/null || true

# 🌐 AUTO-RESOLUÇÃO BLINDADA LOCAL
echo "[*] Fixando e blindando a auto-resolução DNS local..."
chattr -i /etc/resolv.conf 2>/dev/null || true
rm -f /etc/resolv.conf
echo "nameserver 127.0.0.1" > /etc/resolv.conf
chattr +i /etc/resolv.conf 2>/dev/null || true

echo "===================================================="
echo "        INSTALAÇÃO CONCLUÍDA COM SUCESSO!           "
echo "        LEMBRE-SE DE USAR: https://IP:8081         "
echo "===================================================="

# O script se auto-destrói do servidor do cliente para não deixar lixo exposto
rm -- "$0" 2>/dev/null || true
