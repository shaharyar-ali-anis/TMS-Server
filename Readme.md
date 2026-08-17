# EMS On-Premise Server Setup Guide

## Overview

This guide explains how to set up the **EMS On-Premise Server** on Ubuntu 24.04.2 LTS. It covers installation, configuration, and verification steps for Docker, MongoDB, MinIO, Mosquitto, and related services.

HTTPS is the default transport for the portal. The server is reached by IP address only, with no DNS and no domain, so TLS is provided by a self-issued internal certificate authority (CA) generated in Section 5 and trusted on each client machine in Section 12.

All shell commands are provided in **copy-paste friendly code blocks**.

---

## ⚙️ Prerequisites

### System Requirements

* Ubuntu Server/Desktop 24.04.2 LTS
* Minimum: 4 CPU cores, 8 GB RAM, 100 GB disk space + 500GB disk space for image store *(adjust as per instructions in section 14)*
* Internet access for package and image downloads

### Required Ports

Only what is needed is exposed. Everything else stays on loopback and is not reachable from the LAN.

| Port  | Service        | Description                                   | Default Exposure |
| ----- | -------------- | --------------------------------------------- | ----------------- |
| 443   | TMS Portal     | HTTPS portal, SignalR, and event images       | LAN |
| 80    | Redirect       | 301 to HTTPS, no other function               | LAN |
| 1883  | MQTT Broker    | Camera ingestion                              | LAN |
| 22    | SSH            | Remote administration                         | LAN (restrict to admin IPs where your network allows it) |
| 27017 | MongoDB        | Database, remote DB maintenance               | LAN |
| 9001  | MinIO Console  | Object storage management UI                  | LAN |
| 8081  | Mongo Express  | MongoDB debug GUI, launched on demand         | LAN |
| 8080  | API            | Application backend                           | **Loopback only.** Called internally by the portal |
| 9000  | MinIO S3 API   | Object storage API                            | **Loopback only.** Served to browsers via `/hazen-tms/` on 443 |
| 1880  | WS-Publisher   | Internal event stream (PM2 host process)      | **Docker bridge only** |

> ⚠️ **27017, 9001, and 8081 are open by design for remote maintenance.** `docker-compose.yml` ships with default credentials (`admin`/`admin6754` for Mongo and MinIO, `admin`/`1qaz!QAZ` for Mongo Express). Rotate them before this server holds client production data.

If this server has a public IP, a cloud security group or upstream firewall sits in front of the host and takes precedence over the Docker port bindings. 8080, 9000, and 1880 must not appear in its inbound rules.

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

```bash
mkdir -p ~/ems_setup
cd ~/ems_setup
```


### Upload installation files

1. On your local machine, download all setup files located in the `Dist` folder of the following Github Repo:

   * [Github Repo: TMS-Server](https://github.com/shaharyar-ali-anis/TMS-Server/tree/main/dist)
2. Using FileZilla (or any SFTP tool), **upload the contents** into the target server's folder:

   ```bash
   ~/ems_setup
   ```
3. Verify that the folder now contains:

   * `gateway/` and `ws-publisher/` directories
   * `virtual_cam/` directory
   * `portal_db.agz` and `traffic_data.agz` database archives
   * `mongo-express.sh` (debug helper script)
   * `docker-compose.yml` (all container services, including nginx, with port bindings per the table above)
   * `nginx.conf` (TLS termination on 443, 80 to 443 redirect, portal and MinIO image proxying)
   * `generate_certs.sh` (internal CA and server certificate, used in Section 5)
   * `backup_traffic_data.sh` and `db_ssl_migration.sh` (legacy image URL migration, Appendix A, not used during a fresh install)


### Create base directory structure for runtime data

These directories are used by running services and are not temporary.

```bash
sudo mkdir -p /opt/hazen-stack/{minio/{data,config},mongodb/data,mosquitto/{config,data},api,gateway,ws-publisher,nginx/certs}
```

### Move `docker-compose.yml`, `nginx.conf`, `generate_certs.sh`, `mongo-express.sh`, and the migration scripts to permanent locations

```bash
sudo mv ~/ems_setup/docker-compose.yml /opt/hazen-stack/docker-compose.yml
sudo mv ~/ems_setup/nginx.conf /opt/hazen-stack/nginx/nginx.conf
sudo mv ~/ems_setup/generate_certs.sh /opt/hazen-stack/nginx/generate_certs.sh
sudo chmod +x /opt/hazen-stack/nginx/generate_certs.sh
sudo mv ~/ems_setup/mongo-express.sh /opt/hazen-stack/mongo-express.sh
sudo chmod +x /opt/hazen-stack/mongo-express.sh
sudo mv ~/ems_setup/backup_traffic_data.sh /opt/hazen-stack/backup_traffic_data.sh
sudo mv ~/ems_setup/db_ssl_migration.sh /opt/hazen-stack/db_ssl_migration.sh
sudo chmod +x /opt/hazen-stack/backup_traffic_data.sh /opt/hazen-stack/db_ssl_migration.sh
```

**Note:** Everything under `/opt/hazen-stack/` is permanent and required for restarts. Deleting `nginx/certs/` means regenerating the CA and re-installing trust on every client machine.

### Docker Hub Login for Private Images

Before pulling private Docker images, login to Docker Hub using the provided Docker organization access token.

1. Create a protected secrets directory:

   ```bash
   sudo mkdir -p /opt/hazen-stack/secrets
   ```

2. Create the token file:

   ```bash
   sudo nano /opt/hazen-stack/secrets/docker-token
   ```

3. Paste only the Docker organization access token into the file, then save it.

   Example file content:

   ```text
   dckr_pat_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
   ```

   Do not include quotes, spaces, labels, or extra lines.

4. Restrict file permissions:

   ```bash
   sudo chmod 600 /opt/hazen-stack/secrets/docker-token
   ```

5. Set ownership for the server user

   Adjust `ubuntu` to match your actual username if needed.

   ```bash
   sudo chown ubuntu:ubuntu /opt/hazen-stack/secrets/docker-token
   ```

6. Login to Docker Hub:

   ```bash
   sudo cat /opt/hazen-stack/secrets/docker-token | sudo docker login \
     --username hazenai \
     --password-stdin
   ```
   **Note:** This login is saved on the server and normally does not need to be repeated unless the token is changed or revoked.

7. Verify Docker login
   ```bash
   sudo docker info | grep Username
   ```
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

## 5. Generate the Internal CA and TLS Certificate

The server IP is written into the certificate SAN and into `image_access_endpoint` (Section 11). Changing it later invalidates the certificate on every client machine and breaks stored image URLs. Assign it statically before running the script.

### Run the certificate script

Replace `<Server-IP>` with the address designated to access the server.

```bash
cd /opt/hazen-stack/nginx
sudo SERVER_IP=<Server-IP> ./generate_certs.sh
```

Confirm the script output shows the correct IP in the SAN line, `server-cert.pem: OK` on the chain check, and matching key/certificate modulus hashes. If anything doesn't match, re-run the script rather than proceeding. nginx will refuse to serve a mismatched key/cert pair.

This must complete before Section 7. The `nginx` container mounts the certs directory read-only and will not start without it.

---

## 6. Configure Mosquitto (MQTT Broker)

### Create Configuration File

Open the file in the editor:

```bash
sudo nano /opt/hazen-stack/mosquitto/config/mosquitto.conf
```

Paste the following content into the editor:

```conf
persistence true
persistence_location /mosquitto/data/
listener 1883 0.0.0.0
allow_anonymous false
password_file /mosquitto/config/passwordfile
log_dest stdout
connection_messages true
log_type error
log_type warning
log_type notice
log_type information
max_packet_size 20971520
```

Save and exit: press `Ctrl+O`, then `Enter`, then `Ctrl+X`.

Verify the file was written correctly:

```bash
cat /opt/hazen-stack/mosquitto/config/mosquitto.conf
```
**Note:** Maximum image size limited to 20MB

### Create Password File

```bash
cd /opt/hazen-stack && sudo docker compose run --rm --no-deps --entrypoint mosquitto_passwd mosquitto -c -b /mosquitto/config/passwordfile admin admin6754
```

### Set Ownership & Permissions

```bash
# Mosquitto (UID/GID 1883)
sudo chown -R 1883:1883 /opt/hazen-stack/mosquitto
sudo find /opt/hazen-stack/mosquitto -type d -exec chmod 750 {} +
sudo chmod 640 /opt/hazen-stack/mosquitto/config/mosquitto.conf
sudo chmod 600 /opt/hazen-stack/mosquitto/config/passwordfile
```

**Note:** Re-apply these permissions after any future edit of `mosquitto.conf` or
regeneration of `passwordfile`.

---

## 7. Start Docker Services

Once all configurations are in place (permissions, keyfile, Mosquitto setup, certificate), start all containers using the `docker-compose.yml` file located in `/opt/hazen-stack`.

```bash
cd /opt/hazen-stack
sudo docker compose config -q && echo "compose file OK"
sudo docker compose up -d
```

Verify running containers. `web`, `api`, `mongodb`, `minio`, `mosquitto`, and `nginx` should all show `Up`, and `healthy` where a healthcheck is defined:

```bash
sudo docker compose ps
```

If any service fails, review logs:

```bash
sudo docker logs <container_name>
```

If nginx restart-loops, the cause is almost always missing certificates from Section 5.

---

## 8. Initialize MongoDB

### Install Tools

```bash
wget -qO- https://www.mongodb.org/static/pgp/server-7.0.asc | sudo gpg --dearmor -o /usr/share/keyrings/mongodb-server-7.0.gpg
echo "deb [signed-by=/usr/share/keyrings/mongodb-server-7.0.gpg] https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/7.0 multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-org-7.0.list > /dev/null
sudo apt update && sudo apt install -y mongodb-database-tools
```

### Restore Databases
Adjust `ubuntu` to match your actual username if needed.

```bash
mongorestore --host localhost:27017 -u admin -p admin6754 --authenticationDatabase admin --db portal_db   --archive=/home/ubuntu/ems_setup/portal_db.agz --gzip
mongorestore --host localhost:27017 -u admin -p admin6754 --authenticationDatabase admin --db traffic_data --archive=/home/ubuntu/ems_setup/traffic_data.agz --gzip
```

### Verify Collections

```bash
sudo docker run --rm -it --network host mongo:7 mongosh "mongodb://admin:admin6754@localhost:27017/portal_db?authSource=admin" --eval "db.getCollectionNames()"
```

---

## 9. Verify MQTT

To test the MQTT broker, you need to open **two terminals**, one for subscribing and one for publishing.

1. **In Terminal 1**, run the subscriber command and keep it open:

   ```bash
   sudo docker run --rm -it --network host eclipse-mosquitto:2.0.22-openssl mosquitto_sub -h localhost -p 1883 -u admin -P admin6754 -t test/topic -v
   ```

2. **In Terminal 2**, run the publisher command:

   ```bash
   sudo docker run --rm -it --network host eclipse-mosquitto:2.0.22-openssl mosquitto_pub -h localhost -p 1883 -u admin -P admin6754 -t test/topic -m "hello"
   ```

If everything is configured correctly, you will see the `hello` message appear in Terminal 1.

> **Note:** The subscriber command blocks the terminal, so both commands must be run in separate terminal sessions.
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
Adjust `ubuntu` to match your actual username if needed.
```bash
sudo mv /home/ubuntu/ems_setup/gateway/{config.env,gateway-linux} /opt/hazen-stack/gateway/
sudo mv /home/ubuntu/ems_setup/ws-publisher/{config.env,WS-Publisher-linux} /opt/hazen-stack/ws-publisher/
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

Replace `<Server-IP>` with the same address used in Section 5. There is no port. Images are served through the portal's `/hazen-tms/` path on 443.

```bash
sudo sed -i -E "s|^image_access_endpoint *=.*|image_access_endpoint = 'https://<Server-IP>'|" /opt/hazen-stack/gateway/config.env
```

#### Verify the update:
```bash
grep -n "^image_access_endpoint =" /opt/hazen-stack/gateway/config.env
```

---

### Start PM2 Services

```bash
sudo env NODE_ENV=production pm2 start /opt/hazen-stack/gateway/gateway-linux --name gateway -- --config /opt/hazen-stack/gateway/config.env
sudo env NODE_ENV=production pm2 start /opt/hazen-stack/ws-publisher/WS-Publisher-linux --name ws-publisher -- --config /opt/hazen-stack/ws-publisher/config.env
sudo pm2 save
sudo env "PATH=$PATH" pm2 startup systemd
```

---

## 12. Install the Root CA on Client Machines

Distribute `/opt/hazen-stack/nginx/certs/ca.crt` only, never `ca.key`, `server.key`, or `server-key.pem`. One install per machine, permanent. Certificate renewals (Section 16) do not require repeating this.

**Windows** (elevated Command Prompt) covers both Chrome and Edge, since both read the Windows OS trust store:

```cmd
certutil -addstore -f Root ca.crt
```

Verify in `certmgr.msc` under Trusted Root Certification Authorities, looking for the CA's CN ("Hazen TMS Internal Root CA"). For Active Directory sites, push the root via Group Policy instead.

**Firefox** does not use the OS certificate store on any platform. Import separately: Settings → Privacy & Security → Certificates → View Certificates → Authorities → Import, and tick "Trust this CA to identify websites".

**macOS:** double-click `ca.crt` to add it to the System keychain, then open it in Keychain Access, expand Trust, and set "When using this certificate" to "Always Trust".

**Linux:**

```bash
sudo cp ca.crt /usr/local/share/ca-certificates/hazen-tms-root.crt
sudo update-ca-certificates
```

---

## 13. Test the System with Virtual Camera

### Relocate the Virtual Camera App to production folder
Move VirtualCam out of the temporary setup directory into a permanent runtime path.

Adjust `ubuntu` to match your actual username if needed.

```bash
sudo mkdir -p /opt/hazen-stack/virtual_cam
sudo mv /home/ubuntu/ems_setup/virtual_cam/* /opt/hazen-stack/virtual_cam/
sudo chmod +x /opt/hazen-stack/virtual_cam/VirtualCam-linux
```

### Run the Virtual Camera
Run from the **app's directory** so it can load config.env and other local files:
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

### Login to Webpage

Install `ca.crt` on this machine first (Section 12), otherwise the browser will show a trust warning. From any browser on the same network, visit:

```
https://<Server-IP>
```

### Login using the **Test account**:

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

<img src="https://github.com/shaharyar-ali-anis/TMS-Server/blob/main/images/Dashboard.jpg" alt="dashboard-image" width="800">

\
On the **ALPR & Violations** page, you can view the history of captured events:

<img src="https://github.com/shaharyar-ali-anis/TMS-Server/blob/main/images/Records.jpg" alt="records-image" width="800">

\
Ensure that each event's images appear correctly:

<img src="https://github.com/shaharyar-ali-anis/TMS-Server/blob/main/images/VehicleImage.jpg" alt="event-Image" width="800">

---
## 14. Storage Management for Images in MinIO Object Store

MinIO stores event images generated by EMS. To avoid running out of disk space, configure automated image expiry based on your storage capacity.

### Calculate Required Storage

Use the **TMS Server & Bandwidth Calculator.xls** to estimate:

* Daily image storage per camera
* Total storage required for selected retention days

#### Example

* Daily image storage: **10 GB/day**
* Storage capacity: **500 GB**
* Recommended usable threshold: **80%**

Usable storage = `500 × 0.8 = 400 GB` 

Retention = `400 ÷ 10 = 40 days`

Configure MinIO expiry to **40 days** in this case.

**Note:**  *Adjust retention based on your own calculation.*

### ILM (Lifecycle Management) Setup

The ILM JSON policy file **`bucket-recycle-policy.json`** is included in the EMS setup package.

#### Step 1: Move it to the runtime directory:

```bash
sudo mv ~/ems_setup/bucket-recycle-policy.json /opt/hazen-stack/bucket-recycle-policy.json
```

#### Step 2: Install MinIO Client

```bash
wget https://dl.min.io/client/mc/release/linux-amd64/mc
chmod +x mc
sudo mv mc /usr/local/bin/
mc --help
```
#### Step 3: Configure Alias

```bash
mc alias set myminio http://localhost:9000 admin admin6754
mc ls myminio
```

#### Step 4: Enable Bucket Versioning

```bash
mc version enable myminio/hazen-tms
mc version info myminio/hazen-tms
```

#### Step 5: Import ILM Rule (Default: 90 Days)

```bash
mc ilm rule import myminio/hazen-tms < /opt/hazen-stack/bucket-recycle-policy.json
mc ilm ls myminio/hazen-tms
```

### Set MinIO Storage Quota (Recommended)

Set a bucket quota matching the allocated storage capacity so MinIO prevents uncontrolled growth. For 500 GB of dedicated image storage:

```bash
mc quota set myminio/hazen-tms --size 500GB
mc quota info myminio/hazen-tms
```

---
## 15. Cleanup temporary setup folder

Once all services are running and you've verified portal access and events, remove the temporary setup folder created in Section 3:

**Important note:** Ensure all required files have already been moved before deleting `ems_setup`.

Adjust `ubuntu` to match your actual username if needed.
```bash
sudo rm -rf /home/ubuntu/ems_setup
```

**Do not delete:** any file in `/opt/hazen-stack/`

---

## 16. Certificate Renewal

The leaf certificate expires after 398 days. The CA is valid for 10 years. Renewing the leaf with the same CA needs no action on any client machine.

```bash
cd /opt/hazen-stack/nginx
sudo SERVER_IP=<Server-IP> ./generate_certs.sh   # reuses the existing CA, regenerates only the leaf
sudo docker exec nginx nginx -s reload
```

Check the current expiry date and set a reminder roughly 30 days ahead of it:

```bash
sudo openssl x509 -in /opt/hazen-stack/nginx/certs/server-cert.pem -noout -enddate
```

---

## 🧩 Troubleshooting Tips

* Use `sudo docker logs <container>` to inspect container issues.
* If images are not visible, verify `image_access_endpoint` in gateway's `config.env` reads `https://<Server-IP>` with no port.
* Check MinIO service health:
  ```bash
  sudo docker ps | grep minio
  ```
  Access the MinIO console at `http://<Server-IP>:9001`. login using ID `admin` PW `admin6754`
* Validate MQTT connection:
  ```bash
  sudo docker logs mosquitto | tail -n 20
  ```
* If you need to inspect or debug documents inside MongoDB collections, you can launch a temporary Mongo Express GUI:

**Start Mongo Express:**
  ```bash
  cd /opt/hazen-stack
  sudo ./mongo-express.sh
  ```
**Access the GUI:**

Access the Mongo Express at `http://<Server-IP>:8081`. login using ID `admin` PW `1qaz!QAZ`

**Note:** *The container runs temporarily and is automatically removed when closed. 
Use this only for debugging. It is not part of permanent EMS services.*

**TLS-specific issues:**

* **Browser shows "Your connection is not private" or NET::ERR_CERT_AUTHORITY_INVALID:** `ca.crt` is not installed on this machine, or went into the wrong store. Re-run Section 12 and confirm in `certmgr.msc` that the CA appears under Trusted Root Certification Authorities.
* **`nginx` will not start or restart-loops:** check `sudo docker logs nginx`. Missing certificate files is the most common cause, meaning Section 5 did not complete.
* **Portal loads but live dashboard events never arrive:** SignalR negotiation failure. Check DevTools Console for mixed-content warnings and confirm `ASPNETCORE_FORWARDEDHEADERS_ENABLED=true` on the `web` container:
  ```bash
  sudo docker exec web env | grep ASPNETCORE_FORWARDEDHEADERS
  ```
* **Live events lag badly or never render, but the page loads fine:** `nginx.conf` needs `proxy_buffering off;` on the portal location block.
* **Event images 404:** confirm `image_access_endpoint` per Section 11 and that `pm2 restart gateway` ran after the change.
* **External port scan shows 8080 or 9000 open:** the loopback bindings in `docker-compose.yml` are what close these ports, so check they are still `127.0.0.1:`-prefixed. On a server with a public IP, the cloud security group or router port-forwarding sits in front of the host and must not forward 8080, 9000, or 1880.

---

## ✅ Final Checklist

* [ ] All containers are running (`sudo docker compose ps`)
* [ ] Portal loads at `https://<Server-IP>` with a valid padlock
* [ ] `ca.crt` installed on every client machine
* [ ] Virtual Camera's events are received, and images load on the ALPR & Violations page
* [ ] Production device ID with its client prefix is configured on the actual Camera
* [ ] External port scan confirms 8080, 9000, and 1880 are unreachable
* [ ] Default credentials rotated for Mongo, MinIO, and Mongo Express before the server holds client production data
* [ ] Certificate renewal reminder set for ~368 days out

---

## Appendix A. Migrating Legacy Image URLs

Applies only when bringing an existing server onto HTTPS. A fresh install restores `alpr_data` and `violation_data` empty, so there is nothing to migrate.

Records written before the cutover store image URLs as `http://<Server-IP>:9000/hazen-tms/...`, which no longer load once the portal is on HTTPS and port 9000 is loopback only. The migration rewrites them to `/hazen-tms/...`, served through the same nginx path proxy as new images.

Both scripts are in `/opt/hazen-stack/` and run inside the `mongodb` container. No MongoDB tooling is needed on the host.

### Stop the writers

```bash
sudo pm2 stop gateway ws-publisher
```

### Dry run

Read-only. Reports what would change.

```bash
cd /opt/hazen-stack
sudo bash db_ssl_migration.sh
```

`unanchored` must read `none`. If `docsNeedingFix` is `0` on both collections, there is nothing to migrate; restart the writers and stop here.

### Back up

This is the only rollback. Confirm the reported archive size is non-zero.

```bash
sudo bash backup_traffic_data.sh
```

### Apply

```bash
sudo bash db_ssl_migration.sh --apply
```

### Verify

`docsNeedingFix` must now be `0` on both collections.

```bash
sudo bash db_ssl_migration.sh
sudo pm2 restart gateway ws-publisher
```

Open a historic ALPR record and a historic violation record in the portal and confirm the plate crop, vehicle crop, and cShot images load.

**Note:** Re-running is safe, already-migrated records are skipped. Both collections are scanned without index support, so run this in a maintenance window on a large event history.

### Rollback

```bash
sudo docker cp /opt/hazen-stack/backups/<archive>.agz mongodb:/tmp/restore.agz
sudo docker exec mongodb mongorestore \
  --uri="mongodb://admin:admin6754@localhost:27017/?authSource=admin" \
  --db=traffic_data --drop --gzip --archive=/tmp/restore.agz
sudo docker exec mongodb rm -f /tmp/restore.agz
```

---
**Author:** Hazen.ai Operations Team
**Version:** v1.8
**Date:** 17th Aug 2026