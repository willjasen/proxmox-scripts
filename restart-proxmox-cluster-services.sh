GREEN="\e[32m"
RESET="\e[0m"

restart_service() {
    local service=$1
    echo -e "${GREEN}Restarting ${service}...${RESET}"
    systemctl restart ${service}
}

restart_service corosync
restart_service pve-cluster
restart_service pvedaemon
restart_service pvestatd
restart_service pveproxy