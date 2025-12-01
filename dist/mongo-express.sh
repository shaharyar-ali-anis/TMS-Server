#!/bin/bash

echo "Starting Mongo Express..."

sudo docker run --rm -it \
    --network host \
    -p 8081:8081 \
    -e ME_CONFIG_MONGODB_ADMINUSERNAME=admin \
    -e ME_CONFIG_MONGODB_ADMINPASSWORD=admin6754 \
    -e ME_CONFIG_MONGODB_URL="mongodb://admin:admin6754@127.0.0.1:27017/?authSource=admin&directConnection=true" \
    -e ME_CONFIG_BASICAUTH_USERNAME=admin \
    -e ME_CONFIG_BASICAUTH_PASSWORD=1qaz!QAZ \
    mongo-express
