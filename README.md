# docker-dataguard

Files for building an Oracle Data Guard database in Docker

Currently working for version 19.3.

# Disclaimer

This is intended as an educational tool for learning and experimenting with Data Guard. 

Want to understand how switchover works? Nice!
Interested in learning more about Data Guard? Welcome!
Need identical labs for students in a class or workshop? Awesome!
Hacking out a preliminary demo solution or proof of concept? Cool!
Want a portable, lightweight, fully functional Data Guard that runs on a laptop in Economy class? Enjoy!
**Use this to protect a production environment? Bad idea.**

# What does it do?
This creates two containers each hosting Oracle databases and configures them as a Data Guard primary/secondary.

The primary database is built much the same as in an ordinary Docker build. Additional configurations and parameters are added to satisfy the requirements of Data Guard. Standby redo logs are added.

Meanwhile the standby database is initiated but does not run DBCA.

When the database configuration on the primary is complete, it begins an RMAN duplicate and instantiates the standby database. 

Data Guard broker is invoked to create a configuration and add the databases. It also adds static connect identifiers to overcome issues arising from Docker's host-naming.

The containers are visible across the Docker network by the names assigned in the compose yaml file (default are DG11 and DG21) and all TNS/networking operations can be conduced using those aliases.

The two containers are built with an environment variable called ROLE. This is initially set to PRIMARY and STANDBY to faciliate the intial installation. Once database is creation is complete the variable has no meaning. The role of a database is determined at startup in the startDB.sh script by querying the current role of the instance. This allows the database to be started/resume the correct role through a start/stop of compose.

NOTE: Data Guard requires your database to be in archivelog mode. Manage archive log directories accordingly.

## Information
The 19.3 database image is 6.65G.
```
> docker images 
REPOSITORY                         TAG                 IMAGE ID            CREATED             SIZE
oracle/database                    19.3.0-ee           ea261e0fff26        2 hours ago         6.65GB
```
The default build opens ports 1521 and 5500. It translates port 1521 to 1211 on the first host and 1212 on the second. This may be changed in docker-compose.yml.

The default build maps the data volume to a local directory on the host. Change or remove this in the docker-compose.yml.

## Errata
The setupLinuxEnv.sh script for this build includes `vi` and `less` for troubleshooting purposes. If you're looking for a very slightly smaller image, remove them. :)

## Setup

Set Docker's memory limit to at least 8G

## Prerequisites
This repo is built on the Oracle Docker repository: https://github.com/oracle/docker-images

Download the following files from Oracle OTN:
```
LINUX.X64_193000_db_home.zip
```

## Set the environment
The ORADATA_VOLUME is for persisting data for the databases. Each database will inhabit a subdirectory of ORADATA_VOLUME based on the database unique name. DG_DIR is the base directory for this repo.
```
export COMPOSE_YAML=docker-compose.yml
export DB_VERSION=19.3.0
export IMAGE_NAME=oracle/database:${DB_VERSION}-ee
export ORADATA_VOLUME=~/oradata
export DG_DIR=~/docker-dataguard
```

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

# Testing
The build has been tested by starting the databases under docker-compose and running DGMGRL validations and switchover through a variety of scenarios. It correctly resumes the configuration across stops/starts of docker-compose.

Please report any issues to oracle.sean@gmail.com. Thanks!

# CUSTOM CONFIGURATION
## Database configurations
Customize a configuration file for setting up the contaner hosts using the following format if the existing config_dataguard.lst does not meet your needs. This file is used for automated setup of the environment.

The pluggable database is ${ORACLE_SID}PDB1. The default configuration is:

```
cat << EOF > $DG_DIR/config_dataguard.lst
# Host | ID | Role    | DG Cfg | SID  | DB_UNQNAME | DG_TARGET | ORACLE_PWD
DG11   | 1  | PRIMARY | DG1    | DG11 | DG11       | DG21      | oracle
DG21   | 2  | STANDBY | DG1    | DG11 | DG21       | DG11      | oracle
EOF
```

## Docker compose file, TNS configuration
If the ORACLE_SID or host names are changed, the TNS configuration must be update to match.

### Create a docker-compose file using a custom configuration and build the tnsnames.ora, listener.ora files
The `createCompose.sh` script will create the yaml file and the necessary TNS entries by reading the config file:
```
./createCompose.sh
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

