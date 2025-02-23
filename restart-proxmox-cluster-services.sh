GREEN="\e[32m"
RESET="\e[0m"

echo -e "${GREEN}Restarting corosync.service...${RESET}"
systemctl restart corosync.service;
echo -e "${GREEN}Restarting pve-cluster...${RESET}"
systemctl restart pve-cluster
echo -e "${GREEN}Restarting pvedaemon...${RESET}"
systemctl restart pvedaemon
echo -e "${GREEN}Restarting pvestatd...${RESET}"
systemctl restart pvestatd
echo -e "${GREEN}Restarting pveproxy...${RESET}"
systemctl restart pveproxy