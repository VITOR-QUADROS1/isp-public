#!/bin/bash
# =========================================================================
#  PLAYBOOK AUTOMATIZADO DE IMPLANTAÇÃO CLIENTE AAA (RADIUS + PAM + JIT)
# =========================================================================

RADIUS_IP="$1"
RADIUS_SECRET="$2"

if [ -z "$RADIUS_IP" ] || [ -z "$RADIUS_SECRET" ]; then
    echo "❌ ERRO: Parâmetros ausentes."
    echo "👉 Modo de uso: $0 <IP_DO_RADIUS> <CHAVE_SECRETA>"
    echo "💡 Exemplo: $0 172.27.12.159 VisaoMaster@2026!"
    exit 1
fi

echo "1. Instalando o módulo do PAM RADIUS e conector de dados..."
apt update && apt install libpam-radius-auth postgresql-client -y

echo "2. Apontando dinamicamente para o Servidor FreeRADIUS do Cliente..."
cat << EOF > /etc/pam_radius_auth.conf
# Mapeamento do Servidor RADIUS Central Gerado Dinamicamente
# IP_DO_RADIUS      CHAVE_SECRETA      TIMEOUT
$RADIUS_IP       $RADIUS_SECRET       3
EOF

echo "3. Configurando a Árvore de Decisão Limpa do PAM SSHD..."
cat << 'EOF' > /etc/pam.d/sshd
# PAM configuration for the Secure Shell service
auth [success=done default=ignore] pam_radius_auth.so
@include common-auth
account required                pam_nologin.so
account sufficient              pam_radius_auth.so
@include common-account
@include common-session
@include common-password
EOF

echo "4. Escrevendo o Sincronizador de Identidade Dinâmico (Sem IPs Fixos)..."
cat << EOF > /usr/local/bin/radius-user-sync.sh
#!/bin/bash
groupadd -f visao-tech

DB_HOST="$RADIUS_IP"
DB_USER="isp_client_app"
DB_NAME="isp_client_portal"
export PGPASSWORD="Union@2026!"

# Consulta a central dinamicamente para saber os técnicos ativos
CENTRAL_USERS=\$(psql -h "\$DB_HOST" -U "\$DB_USER" -d "\$DB_NAME" -t -A -c "SELECT DISTINCT username FROM radcheck;" 2>/dev/null)

if [ -z "\$CENTRAL_USERS" ]; then
    exit 0
fi

# [FLUXO JIT]: Cria o esqueleto local de quem está ativo no painel web
for u in \$CENTRAL_USERS; do
    if ! id "\$u" >/dev/null 2>&1; then
        useradd -m -g visao-tech -s /bin/bash "\$u"
        passwd -l "\$u" >/dev/null 2>&1
    fi
done

# [FLUXO PURGA]: Remove quem foi excluído da central (Auto-Limpante)
LOCAL_TECH_USERS=\$(getent group visao-tech | cut -d: -f4 | tr ',' ' ')
for lu in \$LOCAL_TECH_USERS; do
    if ! echo "\$CENTRAL_USERS" | grep -q -w "\$lu"; then
        userdel -r -f "\$lu" >/dev/null 2>&1
    fi
done
EOF

chmod +x /usr/local/bin/radius-user-sync.sh

echo "5. Ativando o Agendador Invisível de NOC e Reiniciando o SSH..."
sed -i '/radius-user-sync.sh/d' /etc/crontab
sed -i '/AuthorizedKeysCommand/d' /etc/ssh/sshd_config

# Injeta a tarefa para rodar a cada 1 minuto na cron invisível do sistema
echo "* * * * * root /usr/local/bin/radius-user-sync.sh > /dev/null 2>&1" >> /etc/crontab

# Executa a primeira vez na marra para já puxar os técnicos e criar a conta no ato
/usr/local/bin/radius-user-sync.sh || true

systemctl restart sshd
echo "========================================================================="
echo " 🎉 CONCLUÍDO! SISTEMA 100% PORTÁTIL, AUTOMÁTICO E HOMOLOGADO!"
echo "========================================================================="
