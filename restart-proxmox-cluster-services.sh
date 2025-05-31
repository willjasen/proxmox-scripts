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

stop_service() {
    local service=$1
    echo -ne "${GREEN}Stopping ${service}...${RESET}"
    local start_time=$(date +%s)
    systemctl stop ${service}
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    echo -e "${GREEN} done in ${duration} seconds.${RESET}"
}

start_service() {
    local service=$1
    echo -ne "${GREEN}Starting ${service}...${RESET}"
    local start_time=$(date +%s)
    systemctl start ${service}
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    echo -e "${GREEN} done in ${duration} seconds.${RESET}"
}

# stop_service corosync
# stop_service pve-cluster
# stop_service pvedaemon
# stop_service pvestatd
# stop_service pveproxy

# start_service corosync
# start_service pve-cluster
# start_service pvedaemon
# start_service pvestatd
# start_service pveproxy




# Stop services in order
stop_service pvescheduler;
stop_service pve-ha-lrm;
stop_service pveproxy;
stop_service pvedaemon;
stop_service corosync;
stop_service pve-cluster;


# Start services in order
start_service pve-cluster;
start_service corosync;
start_service pvedaemon;
start_service pveproxy;
start_service pve-ha-lrm;
start_service pvescheduler;