GREEN="\e[32m"
RESET="\e[0m"

restart_service() {
    local service=$1
    echo -ne "${GREEN}Restarting ${service}...${RESET}"
    local start_time=$(date +%s)
    systemctl restart ${service}
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    echo -e "${GREEN} done in ${duration} seconds.${RESET}"
}

restart_service corosync
restart_service pve-cluster
restart_service pvedaemon
restart_service pvestatd
restart_service pveproxy