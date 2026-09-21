curl -fsSL https://bso-9464.github.io/docker-precheck.sh | bash 2>&1 | tee docker-precheck.txt

curl -fsSL https://bso-9464.github.io/install-docker.sh | bash 2>&1 | tee install-docker.log

curl -fsSL -o install-clewdr.sh https://bso-9464.github.io/install-clewdr.sh && bash install-clewdr.sh

curl -fsSL -o vps-status.sh https://bso-9464.github.io/vps-status.sh && bash vps-status.sh
