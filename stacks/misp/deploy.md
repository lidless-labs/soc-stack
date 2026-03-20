# MISP Deployment

## Prerequisites
- A Hyper-V VM created with `scripts/create-vm.ps1` (or any Ubuntu 24.04 box with Docker)
- Docker and Docker Compose v2 installed
- SSH access to the VM

## Deploy

### 1. Copy the stack to the VM
```bash
scp -r stacks/misp/ admin@<vm-ip>:~/misp/
```

### 2. Configure
```bash
ssh admin@<vm-ip>
cd ~/misp
cp config.env.template config.env
nano config.env  # set passwords, adjust INNODB_BUFFER_POOL_SIZE for your VM
```

### 3. Start the stack
```bash
docker compose up -d
```

MISP takes 2-3 minutes to fully start on first boot.

### 4. Run automated setup
```bash
./setup.sh
```

### 5. Verify
```bash
curl -sk https://localhost/servers/getVersion.json \
  -H "Authorization: $(grep 'API Key' api-keys.txt | awk '{print $NF}')"
```

## Ports
| Service | Port |
|---------|------|
| MISP    | 443 (HTTPS), 80 (HTTP redirect) |
| MariaDB | 3306 (internal only) |
| Redis   | 6379 (internal only) |

## Critical: InnoDB Buffer Pool Size

On 4GB VMs, MariaDB's default 2GB InnoDB buffer pool causes OOM kills. The config.env.template defaults to 512M. Scale based on your VM:

| VM RAM | INNODB_BUFFER_POOL_SIZE |
|--------|------------------------|
| 4GB    | 512M                   |
| 8GB    | 2048M                  |
| 16GB   | 4096M                  |

If MariaDB keeps restarting, run `docker compose down -v` to wipe the failed DB volume, adjust the buffer size, and start fresh.
