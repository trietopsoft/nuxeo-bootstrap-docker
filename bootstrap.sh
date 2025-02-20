#!/bin/bash

REPO="https://github.com/trietopsoft/nuxeo-bootstrap-docker.git"
LATEST_IMAGE="nuxeo:10.10"

MONGO_VERSION="4.2"
ELASTIC_VERSION="6.8.20"

CHECKS=()
# Check for commands used in this script
command -v awk >/dev/null || CHECKS+=("awk")
command -v make >/dev/null || CHECKS+=("make")
command -v envsubst >/dev/null || CHECKS+=("envsubst")
command -v git >/dev/null || CHECKS+=("git")
command -v docker >/dev/null || CHECKS+=("docker")
command -v docker-compose >/dev/null || CHECKS+=("docker-compose")

if [ $CHECKS ]
then
  echo "Please install the following programs for your platform:"
  echo ${CHECKS[@]}
  exit 1
fi

docker info >/dev/null
RUNNING=$?
if [ "${RUNNING}" != "0" ]
then
  echo "Docker does not appear to be running, please start Docker."
  exit 2
fi

# Directions for image setup
cat << EOM
 _ __  _   ___  _____  ___
| '_ \| | | \ \/ / _ \/ _ \\
| | | | |_| |>  <  __/ (_) |
|_| |_|\__,_/_/\_\___|\___/

Nuxeo Docker Compose Bootstrap

Requirements:

* A Nuxeo Connect Account (https://connect.nuxeo.com/)
* A Nuxeo Connect token (https://connect.nuxeo.com/nuxeo/site/connect/tokens)
* A Nuxeo Studio project id
* Sonatype User Token credentials (https://packages.nuxeo.com/#user/usertoken)

If you are on a Mac, you have the option to save your Connect Token in your
Keychain. If you do so, note that a dialog box will pop up to verify credential
access whenever you use this script.

This script builds a custom Nuxeo docker image. This may consume a lot of
bandwidth and may take a bit of time. Please be patient. At the end of the
script, additional instructions will be displayed.

EOM

# Prompt for studio project name
NX_STUDIO="${NX_STUDIO:-}"
INSTALL_RPM=""
while [ -z "${NX_STUDIO}" ]
do
  echo -n "Studio Project ID: "
  read NX_STUDIO
done

if [ -e ${NX_STUDIO} ]
then
  echo "Hmm, the directory ${PWD}/${NX_STUDIO} already exists.  I'm going to exit and let you sort that out."
  exit 3
fi

# Prompt for project version
PROJECT_NAME=$(echo "${NX_STUDIO}" | awk '{print tolower($0)}')
STUDIO_PACKAGE=""
NX_STUDIO_VER="${NX_STUDIO_VER:-}"
if [ -z "${NX_STUDIO_VER}" ]
then
  echo -n "Version: [0.0.0-SNAPSHOT] "
  read NX_STUDIO_VER
fi
if [ -z "${NX_STUDIO_VER}" ]
then
  NX_STUDIO_VER="0.0.0-SNAPSHOT"
fi
if [ -n "${NX_STUDIO}" ]
then
  STUDIO_PACKAGE="${NX_STUDIO}-${NX_STUDIO_VER}"
  echo "Using Nuxeo Studio package: ${STUDIO_PACKAGE}"
fi

# Prompt for host name
FQDN="${FQDN:-}"
if [ -z "${FQDN}" ]
then
  echo -n "Hostname: [localhost] "
  read FQDN
fi
if [ -z "${FQDN}" ]
then
  FQDN="localhost"
fi

FROM_IMAGE=${LATEST_IMAGE}
IMAGE_TYPE="latest"

export FROM_IMAGE
echo ""
echo "Using Image: ${FROM_IMAGE}"

# Prompt for Studio Login
STUDIO_USERNAME=${STUDIO_USERNAME:-}
while [ -z "${STUDIO_USERNAME}" ]
do
  echo -n "Studio username: "
  read STUDIO_USERNAME
done

# Check to see if password exists
MACFOUND="false"
if [[ "${OSTYPE}" == "darwin"* ]]
then
  password=$(security find-generic-password -w -a ${STUDIO_USERNAME} -s studio 2>/dev/null)
  CHECK=$?
  if [[ "$CHECK" != "0" ]]
  then
    echo "No password found in MacOS keychain, please provide your credentials below."
  else
    MACFOUND="true"
    CREDENTIALS="${password}"
  fi
fi

if [[ "${MACFOUND}" == "false" && "${OSTYPE}" == "darwin"* ]]
then
  echo -n "Save the Nuxeo Studio token in your keychain? y/n [y]: "
  read SAVEIT

  CHECK="1"
  if [[ -z "${SAVEIT}" || "${SAVEIT}" == "y" || "${SAVEIT}" == "Y" ]]
  then
    echo ""
    echo "You will be prompted to enter your token twice.  After you have saved your token, you will be prompted for your login password in a dialog box."
    security add-generic-password -T "" -a ${STUDIO_USERNAME} -s studio -w
    CHECK=$?
  fi

  if [[ "$CHECK" == "0" ]]
  then
    echo ""
    echo "A dialog box will now pop up to verify your credentials.  Please enter your login password.  The login password will not be visible to this script."
    CREDENTIALS=$(security find-generic-password -w -a ${STUDIO_USERNAME} -s studio )
  fi
fi

CREDENTIALS=${CREDENTIALS:-}
while [ -z "${CREDENTIALS}" ]
do
  echo -n "Studio token: "
  read -s CREDENTIALS
  echo ""
done

# Check out repository
echo ""
echo "Cloning configuration: ${PWD}/${NX_STUDIO}"
git clone ${REPO} ${NX_STUDIO}
mkdir -p ${NX_STUDIO}/conf
cp ${NX_STUDIO}/conf.d/*.conf ${NX_STUDIO}/conf
echo ""

# Write system configuration
cat << EOF > ${NX_STUDIO}/conf/system.conf
# Host Configuration
session.timeout=600
nuxeo.url=http://${FQDN}:8080/nuxeo

# Templates
nuxeo.templates=default,mongodb
EOF

# Write environment file
cat << EOF > ${NX_STUDIO}/.env
APPLICATION_NAME=${NX_STUDIO}
PROJECT_NAME=${PROJECT_NAME}

# Latest Image: ${LATEST_IMAGE}
# LTS Image  : ${LTS_IMAGE}
NUXEO_IMAGE=${FROM_IMAGE}

NUXEO_DEV=true
NUXEO_INSTALL_HOTFIX=true
NUXEO_PORT=8080
NUXEO_PACKAGES=${STUDIO_PACKAGE} ${NUXEO_PACKAGES:-}

INSTALL_RPM=${INSTALL_RPM}

ELASTIC_VERSION=${ELASTIC_VERSION}
MONGO_VERSION=${MONGO_VERSION}

FQDN=${FQDN}
STUDIO_USERNAME=${STUDIO_USERNAME}
STUDIO_CREDENTIALS=${CREDENTIALS}
EOF

# Build everything in init/nuxeo.conf
cat ${NX_STUDIO}/conf/*.conf > ${NX_STUDIO}/init/nuxeo.conf

# Run everything in NX_STUDIO dir
cd ${NX_STUDIO}

# Pull images
echo "Please wait, getting things ready..."
make dockerfiles NUXEO_IMAGE=${FROM_IMAGE} ELASTIC_VERSION=${ELASTIC_VERSION}
#docker pull --quiet ${FROM_IMAGE}
#echo " pulling services..."
#docker-compose build
#echo ""

# Generate CLID
echo "Generating CLID..."
./generate_clid.sh
EC=$?
if [[ "${EC}" == "1" ]]
then
  echo "Something is misconfigured or missing in your .env file, please fix and try again."
  exit 1
elif [[ "${EC}" == "2" ]]
then
  echo "Your studio token does not appear to be correct.  Please check and try again."
  exit 2
fi
echo ""

# Build image (may use CLID generated in previous step)
echo "Building your custom image(s)..."
docker-compose build
echo ""

# Display a sharable config
echo "> Share your configuration:"
echo "IMAGE_TYPE=${IMAGE_TYPE} NUXEO_PACKAGES=\"${NUXEO_PACKAGES:-}\" FQDN=${FQDN} NX_STUDIO=${NX_STUDIO} NX_STUDIO_VER=${NX_STUDIO_VER} bash -c \"\$(curl -fsSL https://raw.github.com/nuxeo-sandbox/nuxeo-presales-docker/master/bootstrap.sh)\""
echo ""

# Display startup instructions
make -e info
if [ -e notes.txt ]
then
  cat notes.txt
fi