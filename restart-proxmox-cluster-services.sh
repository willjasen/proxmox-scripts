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

# The order of these stops and starts correspond to the output of "systemd-analyze critical-chain"

# Stop services in order
stop_service pvescheduler;
stop_service pveproxy;
stop_service pvedaemon;
stop_service corosync;
stop_service pve-cluster;

# Start services in order
start_service pve-cluster;
start_service corosync;
start_service pvedaemon;
start_service pveproxy;

# Wait for pvescheduler to be active
PVE_SCHEDULER_RETRY_INTERVAL=20
echo -e "${GREEN}Waiting for pvescheduler to become active...${RESET}"
while true; do
    systemctl is-active --quiet pvescheduler
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}pvescheduler is active.${RESET}"
        break
    else
        echo -e "${GREEN}pvescheduler not active yet, attempting to start and checking again in ${PVE_SCHEDULER_RETRY_INTERVAL} seconds...${RESET}"
        start_service pvescheduler;
        sleep ${PVE_SCHEDULER_RETRY_INTERVAL}
    fi
done