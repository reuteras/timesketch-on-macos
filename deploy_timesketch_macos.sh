#!/bin/bash
# Copyright 2020 Google Inc. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -e

START_CONTAINER=
SKIP_CREATE_USER=
RELEASE_TAG=20250807

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --start-container) START_CONTAINER=yes ;;
        --skip-create-user) SKIP_CREATE_USER=yes ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done

# Exit early if a timesketch directory already exists.
if [ -d "./timesketch" ]; then
  echo "ERROR: Timesketch directory already exist."
  exit 1
fi

# Exit early if git is not installed.
if ! command -v git &> /dev/null ; then
  echo "ERROR: git is not available."
  echo "See: https://brew.sh to install brew and then git."
  exit 1
fi

# Exit early if gtr is not installed.
if ! command -v gtr &> /dev/null ; then
  echo "ERROR: gtr is not available."
  echo "See: https://brew.sh to install brew and then coreutils (to have gtr instead of tr)."
  exit 1
fi

# Exit early if docker is not installed.
if ! command -v docker &> /dev/null ; then
  echo "ERROR: Docker is not available."
  echo "See: https://docs.docker.com/engine/install/ubuntu/"
exit 1
fi

# Exit early if docker compose is not installed.
if ! docker compose &>/dev/null; then
  echo "ERROR: docker-compose-plugin is not installed."
  exit 1
fi

# Exit early if there are Timesketch containers already running.
if [ ! -z "$(docker ps | grep timesketch)" ]; then
  echo "ERROR: Timesketch containers already running."
  exit 1
fi

if [ ! -d timesketch.git ]; then
    git clone https://github.com/google/timesketch.git timesketch.git
    cd timesketch.git || exit
    git checkout "$RELEASE_TAG"
    cd ..
fi

cp Dockerfile-release timesketch.git/docker/release/build/Dockerfile-release
cp docker-entrypoint.sh timesketch.git/docker/release/build/docker-entrypoint.sh
cd timesketch.git || exit
docker buildx build --build-arg RELEASE_TAG="$RELEASE_TAG" -t timesketch:"$RELEASE_TAG" -f docker/release/build/Dockerfile-release .
cd ..

# Create dirs
mkdir -p timesketch/{data/postgresql,data/opensearch,logs,etc,etc/timesketch,etc/timesketch/sigma/rules,upload,etc/timesketch/llm_summarize,etc/timesketch/nl2q}

echo -n "* Setting default config parameters.."
POSTGRES_USER="timesketch"
POSTGRES_PASSWORD="$(< /dev/urandom gtr -dc A-Za-z0-9 | head -c 32 ; echo)"
POSTGRES_ADDRESS="postgres"
POSTGRES_PORT=5432
SECRET_KEY="$(< /dev/urandom gtr -dc A-Za-z0-9 | head -c 32 ; echo)"
OPENSEARCH_ADDRESS="opensearch"
OPENSEARCH_PORT=9200
OPENSEARCH_MEM_USE_GB=$(sysctl hw.memsize | grep hw.memsize | awk '{printf "%.0f", ($2 / (1024 * 1024 * 1024) / 2)}')
REDIS_ADDRESS="redis"
REDIS_PORT=6379
GITHUB_BASE_URL="https://raw.githubusercontent.com/google/timesketch/master"
echo "OK"
echo "* Setting OpenSearch memory allocation to ${OPENSEARCH_MEM_USE_GB}GB"

# Docker compose and configuration
echo -n "* Fetching configuration files.."
curl -s $GITHUB_BASE_URL/docker/release/docker-compose.yml | \
    grep -vE "^version: " | \
    sed -e "s#command: t#command: /docker-entrypoint.sh t#" | \
    sed -e "s#us-docker.pkg.dev/osdfir-registry/timesketch/##" > timesketch/docker-compose.yml
curl -s $GITHUB_BASE_URL/docker/release/config.env | \
    sed -e 's#^POSTGRES_PASSWORD=#POSTGRES_PASSWORD='$POSTGRES_PASSWORD'#' | \
    sed -e 's#^OPENSEARCH_MEM_USE_GB=#OPENSEARCH_MEM_USE_GB='$OPENSEARCH_MEM_USE_GB'#' | \
    sed -e "s/NUM_WSGI_WORKERS=4/NUM_WSGI_WORKERS=1/" > timesketch/config.env

# Fetch default Timesketch config files
curl -s $GITHUB_BASE_URL/data/timesketch.conf | \
    sed -e 's#SECRET_KEY = \x27\x3CKEY_GOES_HERE\x3E\x27#SECRET_KEY = \x27'$SECRET_KEY'\x27#' | \
    sed -e 's#^OPENSEARCH_HOST = .*#OPENSEARCH_HOST = "'$OPENSEARCH_ADDRESS'"#' | \
    sed -e 's#^OPENSEARCH_PORT = 9200#OPENSEARCH_PORT = '$OPENSEARCH_PORT'#' | \
    sed -e 's#^UPLOAD_ENABLED = False#UPLOAD_ENABLED = True#' | \
    sed -e 's#^UPLOAD_FOLDER = \x27/tmp\x27#UPLOAD_FOLDER = \x27/usr/share/timesketch/upload\x27#' | \
    sed -e 's#^CELERY_BROKER_URL =.*#CELERY_BROKER_URL = \x27redis://'$REDIS_ADDRESS':'$REDIS_PORT'\x27#' | \
    sed -e 's#^CELERY_RESULT_BACKEND =.*#CELERY_RESULT_BACKEND = \x27redis://'$REDIS_ADDRESS':'$REDIS_PORT'\x27#' | \
    sed -e 's#postgresql://<USERNAME>:<PASSWORD>@localhost#postgresql://'$POSTGRES_USER':'$POSTGRES_PASSWORD'@'$POSTGRES_ADDRESS':'$POSTGRES_PORT'#' \
    > timesketch/etc/timesketch/timesketch.conf
echo "OPENSEARCH_HOST = \"opensearch\"" >> timesketch/etc/timesketch/timesketch.conf
echo "OPENSEARCH_PORT = 9200" >> timesketch/etc/timesketch/timesketch.conf
curl -s $GITHUB_BASE_URL/data/tags.yaml > timesketch/etc/timesketch/tags.yaml
curl -s $GITHUB_BASE_URL/data/plaso.mappings > timesketch/etc/timesketch/plaso.mappings
curl -s $GITHUB_BASE_URL/data/generic.mappings > timesketch/etc/timesketch/generic.mappings
curl -s $GITHUB_BASE_URL/data/regex_features.yaml > timesketch/etc/timesketch/regex_features.yaml
curl -s $GITHUB_BASE_URL/data/winevt_features.yaml > timesketch/etc/timesketch/winevt_features.yaml
curl -s $GITHUB_BASE_URL/data/ontology.yaml > timesketch/etc/timesketch/ontology.yaml
curl -s $GITHUB_BASE_URL/data/intelligence_tag_metadata.yaml > timesketch/etc/timesketch/intelligence_tag_metadata.yaml
curl -s $GITHUB_BASE_URL/data/sigma_config.yaml > timesketch/etc/timesketch/sigma_config.yaml
curl -s $GITHUB_BASE_URL/data/sigma/rules/lnx_susp_zmap.yml > timesketch/etc/timesketch/sigma/rules/lnx_susp_zmap.yml
curl -s $GITHUB_BASE_URL/data/plaso_formatters.yaml > timesketch/etc/timesketch/plaso_formatters.yaml
curl -s $GITHUB_BASE_URL/data/context_links.yaml > timesketch/etc/timesketch/context_links.yaml
curl -s $GITHUB_BASE_URL/contrib/nginx.conf > timesketch/etc/nginx.conf
curl -s $GITHUB_BASE_URL/data/llm_summarize/prompt.txt > timesketch/etc/timesketch/llm_summarize/prompt.txt
curl -s $GITHUB_BASE_URL/data/nl2q/data_types.csv > timesketch/etc/timesketch/nl2q/data_types.csv
curl -s $GITHUB_BASE_URL/data/nl2q/prompt_nl2q > timesketch/etc/timesketch/nl2q/prompt_nl2q
curl -s $GITHUB_BASE_URL/data/nl2q/examples_nl2q > timesketch/etc/timesketch/nl2q/examples_nl2q
echo "OK"

ln -s ./config.env ./timesketch/.env

echo
echo "* Installation done."

if [ -z $START_CONTAINER ]; then
  read -p "Would you like to start the containers? [y/N]" START_CONTAINER
fi

if [ "$START_CONTAINER" != "${START_CONTAINER#[Yy]}" ] ;then # this grammar (the #[] operator) means that the variable $start_cnt where any Y or y in 1st position will be dropped if they exist.
  cd timesketch
  echo "* Starting Timesketch containers..."
  docker compose up -d
  echo -n "* Waiting for Timesketch web interface to become healthy.."
  TIMEOUT=300 # 5 minutes timeout
  SECONDS=0
  while true; do
    # Suppress errors in case container is not yet created or health check not configured
    NGINX_SERVER=$(hostname)
    HEALTH_STATUS=$(curl -o /dev/null -w "%{http_code}" -L -s http://$NGINX_SERVER || echo "checking")
    if [ "$HEALTH_STATUS" = "200" ]; then
      echo ".OK"
      break
    fi
    if [ $SECONDS -gt $TIMEOUT ]; then
      echo ".FAIL"
      echo "ERROR: Timesketch web container did not become healthy after $TIMEOUT seconds."
      echo "Please check the container logs: docker logs timesketch-web"
      exit 1
    fi
    echo -n "."
    sleep 5
  done

  echo
  echo "Timesketch is now running!"
  echo "You can typically access it by navigating to:"
  echo "  http://<YOUR_SERVER_IP_OR_HOSTNAME>"
  echo
  echo "IMPORTANT: By default, Timesketch is running WITHOUT SSL/TLS encryption."
  echo "For production use, it is CRITICAL to configure SSL/TLS for HTTPS access (https://<YOUR_SERVER_IP_OR_HOSTNAME>)."
  echo "Please follow the SSL/TLS setup instructions here:"
  echo "  https://timesketch.org/guides/admin/https/"
  echo
else
  echo
  echo "You have chosen not to start the containers,"
  echo "if you wish to do so later, you can start timesketch container as below"
  echo
  echo "Start the system:"
  echo "1. cd timesketch"
  echo "2. docker compose up -d"
  echo "3. docker compose exec timesketch-web tsctl create-user <USERNAME>"
  echo
  echo "WARNING: The server is running without encryption."
  echo "Follow the instructions to enable SSL to secure the communications:"
  echo "https://github.com/google/timesketch/blob/master/docs/Installation.md"
  echo
  echo
  exit
fi

if [ -z "$SKIP_CREATE_USER" ]; then
  read -p "Would you like to create a new timesketch user? [y/N]" CREATE_USER
fi

if [ "$CREATE_USER" != "${CREATE_USER#[Yy]}" ] ;then
  read -p "Please provide a new username: " NEWUSERNAME

  if [ ! -z "$NEWUSERNAME" ] ;then
    docker compose exec timesketch-web tsctl create-user "$NEWUSERNAME"
  fi
fi
