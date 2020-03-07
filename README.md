# docker-dataguard

Files for building an Oracle Data Guard database in Docker

## Setup

Set Docker's memory limit to at least 8G

## Prerequisites
This repo is built on the Oracle Docker repository: https://github.com/oracle/docker-images

Download the following files from Oracle OTN:
```
LINUX.X64_193000_db_home.zip
```

## Set the environment
The ORA_DOCKER_DIR is the location of the existing docker-images directory. The ORADATA_VOLUME is for persisting data for the databases. Each database will inhabit a subdirectory of ORADATA_VOLUME based on the database unique name.
```
export COMPOSE_YAML=docker-compose.yml
export DB_VERSION=19.3.0
export IMAGE_NAME=oracle/database:${DB_VERSION}-ee
export ORA_DOCKER_DIR=~/docker
export ORADATA_VOLUME=~/oradata
export DG_DIR=~/docker-dataguard
```

## Copy the Oracle Docker files from their current location to the DG directory:
`cp $ORA_DOCKER_DIR/docker-images/OracleDatabase/SingleInstance/dockerfiles/$DB_VERSION/* $DG_DIR`

## Copy the downloaded Oracle database installation files to the DG directory:
```
cp LINUX.X64_193000_db_home.zip $DG_DIR/$DB_VERSION
```

## Navigate to the DG directory
`cd $DG_DIR`

## Run the build to create the oracle/datbase:19.3.0-ee Docker image
`./buildDockerImage.sh -v 19.3.0 -e`

## Run compose (detached)
`docker-compose up -d`

## Tail the logs
`docker-compose logs -f`

# OPTIONAL STEPS
## Database configurations
Customize a configuration file for setting up the contaner hosts using the following format if the existing config_dataguard.lst does not meet your needs. This file is used for automated setup of the environment.

The container name is the DB_UNIQUE_NAME.
The pluggable database is ${ORACLE_SID}PDB1.

```
cat << EOF > $DG_DIR/config_dataguard.lst
# Container | ID | Role   | DG Config | SID  | DG_TARGET | Oracle Pass
DG11        | 1  | PRIMARY| DG1       | DG11 | DG21      | oracle
DG21        | 2  | STANDBY| DG1       | DG11 | DG11      | oracle
EOF
```

## Docker compose file, TNS configuration
If using a custom dataguard configuration (above) there will need to be changes to the TNS configuration and Docker compose file.

### Create a docker-compose file and build tnsnames.ora, listener.ora files
```
# Initialize the files:
cat << EOF > $COMPOSE_YAML
version: '3'
services: 
EOF

cat << EOF > $DG_DIR/tnsnames.ora
# tnsnames.ora extension for Data Guard demo
EOF

# Populate the docker-compose.yml file:
egrep -v "^$|^#" $DG_DIR/config_dataguard.lst | sed -e 's/[[:space:]]//g' | sort | while IFS='|' read CONTAINER_NAME CONTAINER_ID ROLE DG_CONFIG ORACLE_SID DG_TARGET ORACLE_PWD
do

# Write the Docker compose file entry:
cat << EOF >> $COMPOSE_YAML
  $CONTAINER_NAME:
    image: $IMAGE_NAME
    container_name: $CONTAINER_NAME
    volumes:
      - "$ORADATA_VOLUME/$CONTAINER_NAME:/opt/oracle/oradata"
      - "$DG_DIR:/opt/oracle/scripts"
    environment:
      CONTAINER_NAME: $CONTAINER_NAME
      DG_CONFIG: $DG_CONFIG
      DG_TARGET: $DG_TARGET
      ORACLE_PDB: ${ORACLE_SID}PDB1
      ORACLE_PWD: $ORACLE_PWD
      ORACLE_SID: $ORACLE_SID
      ROLE: $ROLE
    ports:
      - "121$CONTAINER_ID:1521"

EOF

# Write the tnsnames.ora entry:
cat << EOF >> $DG_DIR/tnsnames.ora
$CONTAINER_NAME=
(DESCRIPTION =
  (ADDRESS = (PROTOCOL = TCP)(HOST = $CONTAINER_NAME)(PORT = 1521))
  (CONNECT_DATA =
    (SERVER = DEDICATED)
    (SERVICE_NAME = $ORACLE_SID)
  )
)
EOF

done
```
# Cleanup
## To stop compose, remove any existing image and prune the images:
```
docker-compose down
docker rmi oracle/database:19.3.0-ee
docker image prune <<< y
```

## Clear out the ORADATA volume
```
if [[ "$ORADATA_VOLUME" ]] && [ -d "$ORADATA_VOLUME" ]
  then rm -Rf $ORADATA_VOLUME/DG*
fi
#rm -Rf ~/oradata/DG*
```
