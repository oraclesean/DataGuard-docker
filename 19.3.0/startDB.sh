#!/bin/bash
# LICENSE UPL 1.0
#
# Copyright (c) 1982-2018 Oracle and/or its affiliates. All rights reserved.
#
# Since: November, 2016
# Author: gerald.venzl@oracle.com
# Description: Starts the Listener and Oracle Database.
#              The ORACLE_HOME and the PATH has to be set.
# 
# DO NOT ALTER OR REMOVE COPYRIGHT NOTICES OR THIS HEADER.
# 

# Check that ORACLE_HOME is set
if [ "$ORACLE_HOME" == "" ]; then
  script_name=`basename "$0"`
  echo "$script_name: ERROR - ORACLE_HOME is not set. Please set ORACLE_HOME and PATH before invoking this script."
  exit 1;
fi;

# Start Listener
lsnrctl start

# Startup mount
sqlplus / as sysdba << EOF
startup mount
EOF

# Determine the database role
database_role=$(sqlplus -S / as sysdba << EOF
select database_role from v\$database;
EOF
)

# The expected output is either:
# DATABASE_ROLE ---------------- PRIMARY
# DATABASE_ROLE ---------------- PHYSICAL STANDBY
# Determine the role:

  if [[ $database_role =~ PRIMARY ]]
then export ROLE="PRIMARY"
elif [[ $database_role =~ STANDBY ]]
then export ROLE="STANDBY"
else export ROLE="$ROLE"
fi


  if [ "$ROLE" = "STANDBY" ]
then # Start standby databases in managed recovery
sqlplus / as sysdba << EOF
alter database recover managed standby database disconnect from session;
exit
EOF

else # Open the database
sqlplus / as sysdba << EOF
alter database open;
exit
EOF

fi
