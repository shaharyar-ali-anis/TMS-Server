# EMS On-Premise Server Setup Guide

## Overview

This guide explains how to set up the **EMS On-Premise Server** on Ubuntu 24.04.2 LTS. It covers installation, configuration, and verification steps for Docker, MongoDB, MinIO, Mosquitto, and related services.

All shell commands are provided in **copy-paste friendly code blocks**.

---

## ⚙️ Prerequisites

### System Requirements

* Ubuntu Server/Desktop 24.04.2 LTS
* Minimum: 4 CPU cores, 8 GB RAM, 100 GB disk space
* Internet access for package and image downloads

### Required Ports

Make sure the following ports are open on your server:

| Port | Service       | Description             |
| ---- | ------------- | ----------------------- |
| 22   | SSH           | Remote access           |
| 80   | TMS Portal    | Web portal interface    |
| 8080 | API           | Application backend     |
| 1880 | WebSocket     | Real-time events        |
| 1883 | MQTT Broker   | IoT message broker      |
| 9000 | MinIO         | Object storage (images) |
| 9001 | MinIO Console | Management portal       |

---

### Default Demo account credentials
| Parameter                             |    Value     |
| ------------------------------------- | ------------ |
| Login ID                              | op1@hazen.ai |
| Password | hazen123 |
| Device ID| 1/cam_virtual |

### Default Production account credentials
| Parameter                             |    Value     |
| ------------------------------------- | ------------ |
| Login ID             | user@demo.com |
| Password | 1qaz!QAZ |
| Device ID| 2/cam1 |


---

## 1. Configure Hostname

```bash
sudo hostnamectl set-hostname EMS-DevServer
```

---

## 2. Install Docker and Dependencies

```bash
# Install prerequisites
sudo apt update && sudo apt install -y apt-transport-https ca-certificates curl software-properties-common gnupg lsb-release

# Create Docker keyring directory
sudo mkdir -p /etc/apt/keyrings && sudo chmod 0755 /etc/apt/keyrings

# Add Docker GPG key
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo tee /etc/apt/keyrings/docker.asc > /dev/null

# Add Docker repository
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Install Docker
sudo apt update && sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Verify installation
sudo docker --version
```

> **Tip:** Make sure Docker is running: `sudo systemctl status docker`

---

## 3. Prepare Installation Files

### Create a temporary setup folder

We’ll use a temporary folder to hold all installation files. You’ll upload these files manually (via FileZilla or another SFTP client) instead of downloading directly from Google Drive.

```bash
mkdir -p ~/ems_setup
cd ~/ems_setup
```

### Upload installation files

1. On your local machine, download all setup files located in the `Dist` folder of the following Github Repo:

   * [Github Repo: TMS-Server](https://github.com/shaharyar-ali-anis/TMS-Server/tree/main/dist)
2. Once downloaded, use FileZilla (or any SFTP tool) to **upload the contents** into the target server’s folder:

   ```bash
   ~/ems_setup
   ```
3. Verify that the folder now contains items such as:

   * `gateway/` and `ws-publisher/` directories
   * `virtual_cam/` directory
   * `portal_db.agz` and `traffic_data.agz` database archives

### Create base directory structure for runtime data

These directories are used by running services (they are not temporary):

```bash
sudo mkdir -p /opt/hazen-stack/{minio/{data,config},mongodb/data,mosquitto/{config,data,log},api,gateway,ws-publisher}
```

### Move docker-compose.yml to permanent location

Before starting any containers, move the `docker-compose.yml` file out of the temporary setup folder so it is retained for future management:

```bash
sudo mv ~/ems_setup/docker-compose.yml /opt/hazen-stack/docker-compose.yml
```

> **Note:** The `docker-compose.yml` file defines all container services and must remain under `/opt/hazen-stack` for future restarts using:
>
> ```bash
> cd /opt/hazen-stack
> sudo docker compose up -d
> sudo docker compose down
> sudo docker compose ps
> ```

---

## 4. Set Ownership & Permissions

Adjust `ubuntu` to match your actual username if needed.

```bash
# MinIO
sudo chown -R 1000:ubuntu /opt/hazen-stack/minio
sudo find /opt/hazen-stack/minio -type d -exec chmod 750 {} +
sudo find /opt/hazen-stack/minio -type f -exec chmod 640 {} +

# MongoDB
sudo chown -R 999:ubuntu /opt/hazen-stack/mongodb
sudo find /opt/hazen-stack/mongodb/data -type d -exec chmod 750 {} +
sudo find /opt/hazen-stack/mongodb/data -type f -exec chmod 640 {} +

# MongoDB Keyfile
sudo openssl rand -base64 756 | sudo tee /opt/hazen-stack/mongodb/keyfile > /dev/null
sudo chown 999:999 /opt/hazen-stack/mongodb/keyfile
sudo chmod 400 /opt/hazen-stack/mongodb/keyfile
```

---

## 5. Configure Mosquitto (MQTT Broker)

### Create Configuration File

```bash
sudo tee /opt/hazen-stack/mosquitto/config/mosquitto.conf > /dev/null <<'EOF'
persistence true
persistence_location /mosquitto/data/
log_dest file /mosquitto/log/mosquitto.log
listener 1883 0.0.0.0
allow_anonymous false
password_file /mosquitto/config/passwordfile
EOF
```

### Create Password File

```bash
sudo docker run --rm -v /opt/hazen-stack/mosquitto/config:/mosquitto/config eclipse-mosquitto \
  mosquitto_passwd -c -b /mosquitto/config/passwordfile admin admin6754
```

---

## 6. Start Docker Services

Once all configurations are in place (permissions, keyfile, and Mosquitto setup), start all containers using the `docker-compose.yml` file located in `/opt/hazen-stack`.

```bash
cd /opt/hazen-stack
sudo docker compose up -d
```

Verify running containers:

```bash
sudo docker ps
```

If any service fails, review logs:

```bash
sudo docker logs <container_name>
```

---

## 7. Initialize MongoDB

### Install Tools

```bash
wget -qO- https://www.mongodb.org/static/pgp/server-7.0.asc | sudo gpg --dearmor -o /usr/share/keyrings/mongodb-server-7.0.gpg
echo "deb [signed-by=/usr/share/keyrings/mongodb-server-7.0.gpg] https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/7.0 multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-org-7.0.list > /dev/null
sudo apt update && sudo apt install -y mongodb-database-tools
```

### Restore Databases
Adjust `<your_user>` to match your actual username if needed.
```bash
mongorestore --host localhost:27017 -u admin -p admin6754 --authenticationDatabase admin --db portal_db   --archive=/home/<your_user>/ems_setup/portal_db.agz --gzip
mongorestore --host localhost:27017 -u admin -p admin6754 --authenticationDatabase admin --db traffic_data --archive=/home/<your_user>/ems_setup/traffic_data.agz --gzip
```

### Verify Collections

```bash
sudo docker run --rm -it --network host mongo:7 mongosh "mongodb://admin:admin6754@localhost:27017/portal_db?authSource=admin" --eval "db.getCollectionNames()"
```

---

## 8. Verify MQTT

To test the MQTT broker, you need to open **two terminals** — one for subscribing and one for publishing.

1. **In Terminal 1**, run the subscriber command and keep it open:

   ```bash
   sudo docker run --rm -it --network host eclipse-mosquitto mosquitto_sub -h localhost -p 1883 -u admin -P admin6754 -t test/topic -v
   ```

   This command will wait and listen for any incoming messages.

2. **In Terminal 2**, run the publisher command:

   ```bash
   sudo docker run --rm -it --network host eclipse-mosquitto mosquitto_pub -h localhost -p 1883 -u admin -P admin6754 -t test/topic -m "hello"
   ```

If everything is configured correctly, you will see the `hello` message appear in Terminal 1.

> **Note:** The subscriber command blocks the terminal, so both commands must be run in separate terminal sessions.
---

## 9. Configure API Database Connection

```bash
sudo docker exec -it api bash -lc "sed -i 's|mongodb.*|mongodb://admin:admin6754@mongodb:27017/\",|' /app/appsettings.json"
```

Verify by opening the config file manually:

```bash
sudo docker exec -it api cat /app/appsettings.json
```

---

## 10. Initialize MinIO

```bash
sudo docker run --rm --network host -v /tmp/.mc:/root/.mc minio/mc alias set local http://127.0.0.1:9000 admin admin6754
sudo docker run --rm --network host -v /tmp/.mc:/root/.mc minio/mc mb --ignore-existing local/hazen-tms
sudo docker run --rm --network host -v /tmp/.mc:/root/.mc minio/mc anonymous set download local/hazen-tms
```

---

## 11. Setup Gateway & WS-Publisher

### Install Node.js and PM2

```bash
sudo apt install -y nodejs npm && sudo npm install -g pm2@latest
```

### Move Files & Set Permissions
Adjust `<your_user>` to match your actual username if needed.
```bash
sudo mv /home/<your_user>/ems_setup/gateway/{config.env,gateway-linux} /opt/hazen-stack/gateway/
sudo mv /home/<your_user>/ems_setup/ws-publisher/{config.env,WS-Publisher-linux} /opt/hazen-stack/ws-publisher/
sudo chmod +x /opt/hazen-stack/gateway/gateway-linux /opt/hazen-stack/ws-publisher/WS-Publisher-linux
```

### Create & Apply MinIO Service Keys

```bash
ACCESS_KEY=$(openssl rand -hex 10)
SECRET_KEY=$(openssl rand -hex 20)
echo -e "AccessKeyId='$ACCESS_KEY'\nSecretAccessKey='$SECRET_KEY'\n" | tee /tmp/minio_keys.txt
sudo docker run --rm --network host -v /tmp/.mc:/root/.mc minio/mc admin user svcacct add local admin --access-key "$ACCESS_KEY" --secret-key "$SECRET_KEY"
sudo sed -i -E "s|^accessKeyId *=.*|accessKeyId='$ACCESS_KEY'|; s|^secretAccessKey *=.*|secretAccessKey='$SECRET_KEY'|" /opt/hazen-stack/gateway/config.env
rm -f /tmp/minio_keys.txt
```

### Update `image_access_endpoint` in Gateway Config

After the MinIO keys are written to `config.env`, update the image endpoint directly via console without opening an editor. Replace `<your_public_or_accessible_ip>` with your actual accessible IP/URL:

```bash
sudo sed -i -E "s|^image_access_endpoint *=.*|image_access_endpoint = 'http://<your_public_or_accessible_ip>:9000'|" /opt/hazen-stack/gateway/config.env
```

#### Verify the update:
```bash
grep -n "^image_access_endpoint =" /opt/hazen-stack/gateway/config.env
```

> This confirms the correct public or local endpoint is configured for browser image retrieval.

---

### Start PM2 Services

```bash
sudo env NODE_ENV=production pm2 start /opt/hazen-stack/gateway/gateway-linux --name gateway -- --config /opt/hazen-stack/gateway/config.env
sudo env NODE_ENV=production pm2 start /opt/hazen-stack/ws-publisher/WS-Publisher-linux --name ws-publisher -- --config /opt/hazen-stack/ws-publisher/config.env
sudo pm2 save
sudo env "PATH=$PATH" pm2 startup systemd
```

---

## 12. Test the System with Virtual Camera

### Relocate the Virtual Camera App to production folder ###
Move VirtualCam out of the temporary setup directory into a permanent runtime path.

Adjust `<your_user>` to match your actual username if needed.

```bash
sudo mkdir -p /opt/hazen-stack/virtual_cam
sudo mv /home/<your_user>/ems_setup/virtual_cam/* /opt/hazen-stack/virtual_cam/
sudo chmod +x /opt/hazen-stack/virtual_cam/VirtualCam-linux
```

### Run the Virtual Camera ###
Run from the **app’s directory** so it can load config.env and other local files:
```bash
cd /opt/hazen-stack/virtual_cam
sudo ./VirtualCam-linux
```

If you see an error like `TypeError: Cannot read properties of undefined (reading 'yellow')`, make sure you are in the `/opt/hazen-stack/virtual_cam` directory before launching.

You should see output similar to:
```
License: Valid
MQTT Broker: 127.0.0.1
MQTT: Connected
MQTT: TX: Packet sent to topic > hazen/vistapro/...
```
This confirms successful MQTT and backend communication.


### Login to Webpage ###

From any browser on the same network, visit:

```
http://<Server-IP>
```

Login using the **Test account**:

| Parameter | Value |
|------------|--------|
| Login ID | op1@hazen.ai |
| Password | hazen123 |

Credentials for Camera:
| Parameter | Value |
|------------|--------|
| MQTT Broker |\<Server-IP> |
| MQTT username | admin |
| MQTT password | admin6754 |

On the dashboard, you should see live events every 60 seconds or so.

<img src="http://hazen-tms.s3.dualstack.me-central-1.amazonaws.com/files/assets/Dashboard.jpg" alt="Dashboard" width="800">

\
On the **ALPR & Violations** page, you can view the history of captured events:

<img src="http://hazen-tms.s3.dualstack.me-central-1.amazonaws.com/files/assets/Records.jpg" alt="Records" width="800">

\
Ensure that each event’s images appear correctly:

<img src="http://hazen-tms.s3.dualstack.me-central-1.amazonaws.com/files/assets/VehicleImage.jpg" alt="Event Image" width="800">

---

## 13. Cleanup temporary setup folder

Once all services are running and you’ve verified portal access and events, remove the temporary setup folder created in Step 3:

```bash
sudo rm -rf /home/<your_user>/ems_setup
```

**Do not delete:** `/opt/hazen-stack/docker-compose.yml` — this file is needed for restarting or updating the services later.


---

## 🧩 Troubleshooting Tips

* Use `sudo docker logs <container>` to inspect container issues.
* If images are not visible, verify the IP in `image_access_endpoint` inside gateway’s `config.env`.
* Check MinIO service health:
  ```bash
  sudo docker ps | grep minio
  ```
  Access the MinIO console at `http://<Server-IP>:9001`. login using ID `admin` PW `admin6754`
* Validate MQTT connection:
  ```bash
  sudo docker logs mosquitto | tail -n 20
  ````
---

## ✅ Final Checklist

* [ ] All containers are running (`docker ps`)
* [ ] Portal loads at `http://<Server-IP>`
* [ ] Virtual Camera's events are received
* [ ] Production device ID with its client prefix is configuired on the actual Camera

---

**Author:** Hazen.ai Operations Team
**Version:** v1.0
**Date:** October 2025
