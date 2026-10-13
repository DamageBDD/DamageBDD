#!/bin/sh
docker compose -p aeternity -f docker-compose.yml pull
docker compose -p aeternity -f docker-compose.yml up -d
