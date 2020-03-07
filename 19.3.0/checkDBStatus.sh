#!/bin/bash
# LICENSE UPL 1.0
#
# Copyright (c) 1982-2018 Oracle and/or its affiliates. All rights reserved.
#
# Since: May, 2017
# Author: gerald.venzl@oracle.com
# Description: Checks the status of Oracle Database.
# Return codes: 0 = PDB is open and ready to use
#               1 = PDB is not open
#               2 = Sql Plus execution failed
# DO NOT ALTER OR REMOVE COPYRIGHT NOTICES OR THIS HEADER.
# 
# Updated: August 2019
# Author: oracle.sean@gmail.com
# Description: Modifications for handling Data Guard container environments.

ORACLE_SID="`grep $ORACLE_HOME /etc/oratab | cut -d: -f1`"
OPEN_MODE="READ WRITE"
ORAENV_ASK=NO
source oraenv

# Check Oracle at least one PDB has open_mode "READ WRITE" and store it in status
db_role=`sqlplus -s / as sysdba << EOF
   set heading off;
   set pagesize 0;
   select database_role from v\\$database;
   exit;
EOF`

# Store return code from SQL*Plus
ret=$?

# SQL Plus execution was successful and the database is PRIMARY:
if [ $ret -eq 0 ] && [ "$db_role" = "PRIMARY" ]; then

   # DB Role is PRIMARY; check for an open PDB
   status=`sqlplus -s / as sysdba << EOF
   set heading off;
   set pagesize 0;
   SELECT DISTINCT open_mode FROM v\\$pdbs WHERE open_mode = '$OPEN_MODE';
   exit;
EOF`

   # Store return code from SQL*Plus
   ret=$?

   # SQL Plus execution was successful and PDB is open
   if [ $ret -eq 0 ] && [ "$status" = "$OPEN_MODE" ]; then
      exit 0;
   # PDB is not open
   elif [ "$status" != "$OPEN_MODE" ]; then
      exit 1;
   # SQL Plus execution failed
   else
      exit 2;
   fi;
   
elif [ "$db_role" = "PHYSICAL STANDBY" ]; then
   # DB Role is STANDBY; check for DB state 
   status=`sqlplus -s / as sysdba << EOF
   set heading off;
   set pagesize 0;
   select 'HEALTHY' from v\\$database where open_mode in ('MOUNTED', 'READ ONLY', 'READ ONLY WITH APPLY');
   exit;
EOF`

   # Store return code from SQL*Plus
   ret=$?

   # SQL Plus execution was successful and mode is in the list
   if [ $ret -eq 0 ] && [ "$status" = "HEALTHY" ]; then
      exit 0;
   # Database mode is not in the list
   elif [ "$status" != "HEALTHY" ]; then
      exit 1;
   # SQL Plus execution failed
   else
      exit 2;
   fi;

else
  exit 2;
fi
