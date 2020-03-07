#!/bin/bash
# LICENSE UPL 1.0
#
# Copyright (c) 1982-2018 Oracle and/or its affiliates. All rights reserved.
#
# Since: November, 2016
# Author: gerald.venzl@oracle.com
# Description: Creates an Oracle Database based on following parameters:
#              $ORACLE_SID: The Oracle SID and CDB name
#              $ORACLE_PDB: The PDB name
#              $ORACLE_PWD: The Oracle password
#
# DO NOT ALTER OR REMOVE COPYRIGHT NOTICES OR THIS HEADER.
#

set -e

# Check whether ORACLE_SID is passed on
export ORACLE_SID=${1:-ORCLCDB}

# Check whether ORACLE_PDB is passed on
export ORACLE_PDB=${2:-ORCLPDB1}

# Auto generate ORACLE PWD if not passed on
export ORACLE_PWD=${3:-"`openssl rand -base64 8`1"}
echo "ORACLE PASSWORD FOR SYS, SYSTEM AND PDBADMIN: $ORACLE_PWD";

# Replace place holders in response file
cp $ORACLE_BASE/$CONFIG_RSP $ORACLE_BASE/dbca.rsp
sed -i -e "s|###ORACLE_SID###|$ORACLE_SID|g" $ORACLE_BASE/dbca.rsp
sed -i -e "s|###ORACLE_PDB###|$ORACLE_PDB|g" $ORACLE_BASE/dbca.rsp
sed -i -e "s|###ORACLE_PWD###|$ORACLE_PWD|g" $ORACLE_BASE/dbca.rsp
sed -i -e "s|###ORACLE_BASE###|$ORACLE_BASE|g" $ORACLE_BASE/dbca.rsp
sed -i -e "s|###ORACLE_CHARACTERSET###|$ORACLE_CHARACTERSET|g" $ORACLE_BASE/dbca.rsp

# If there is greater than 8 CPUs default back to dbca memory calculations
# dbca will automatically pick 40% of available memory for Oracle DB
# The minimum of 2G is for small environments to guarantee that Oracle has enough memory to function
# However, bigger environment can and should use more of the available memory
# This is due to Github Issue #307
if [ `nproc` -gt 8 ]; then
   sed -i -e "s|totalMemory=2048||g" $ORACLE_BASE/dbca.rsp
fi;

# Create directories:
mkdir -p $ORACLE_BASE/oradata/dbconfig/$ORACLE_SID
mkdir -p $ORACLE_BASE/oradata/$ORACLE_SID/archivelog
mkdir -p $ORACLE_BASE/oradata/$ORACLE_SID/autobackup
mkdir -p $ORACLE_BASE/oradata/$ORACLE_SID/flashback
mkdir -p $ORACLE_BASE/oradata/$ORACLE_SID/fast_recovery_area
mkdir -p $ORACLE_BASE/admin/$ORACLE_SID/adump

# Add aliases to set up the environment:
cat << EOF >> $HOME/env
alias $(echo $ORACLE_SID | tr [A-Z] [a-z])="export ORACLE_SID=$ORACLE_SID; export ORACLE_HOME=$ORACLE_HOME; export LD_LIBRARY_PATH=$ORACLE_HOME/lib; export PATH=$ORACLE_HOME/bin:$ORACLE_HOME/OPatch/:/usr/sbin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
EOF

chmod ug+x $HOME/env

# Create network related config files (sqlnet.ora, tnsnames.ora, listener.ora)
mkdir -p $ORACLE_HOME/network/admin
echo "NAME.DIRECTORY_PATH= (TNSNAMES, EZCONNECT, HOSTNAME)" > $ORACLE_HOME/network/admin/sqlnet.ora

# Listener.ora
cat << EOF > $ORACLE_HOME/network/admin/listener.ora
#DEDICATED_THROUGH_BROKER_LISTENER=ON
#DIAG_ADR_ENABLED = off

SID_LIST_LISTENER =
  (SID_LIST =
    (SID_DESC =
      (GLOBAL_DBNAME = $DB_UNQNAME)
      (ORACLE_HOME = $ORACLE_HOME)
      (SID_NAME = $DB_UNQNAME)
    )
    (SID_DESC =
      (GLOBAL_DBNAME = ${ORACLE_SID}_DGMGRL)
      (ORACLE_HOME = $ORACLE_HOME)
      (SID_NAME = $ORACLE_SID)
    )
  )
EOF

# TNSnames.ora
echo "$ORACLE_PDB=
(DESCRIPTION =
  (ADDRESS = (PROTOCOL = TCP)(HOST = 0.0.0.0)(PORT = 1521))
  (CONNECT_DATA =
    (SERVER = DEDICATED)
    (SERVICE_NAME = $ORACLE_PDB)
  )
)" > $ORACLE_HOME/network/admin/tnsnames.ora

# Copy the generated list of TNS entries to the local TNS file:
cat $ORACLE_BASE/scripts/tnsnames.ora >> $ORACLE_HOME/network/admin/tnsnames.ora

echo " "
echo "      Container name is: $CONTAINER_NAME"
echo "      Container role is: $ROLE"
echo " Container DG Target is: $DG_TARGET"
echo "              DB SID is: $ORACLE_SID"
echo "Database Unique Name is: $DB_UNQNAME"
echo " "

if [[ "$ROLE" = "PRIMARY" ]]; then

# #############################################################
#                  Prepare a primary database                 #
# #############################################################

# Start LISTENER and run DBCA
lsnrctl start

dbca -silent -createDatabase -responseFile $ORACLE_BASE/dbca.rsp \
  || cat /opt/oracle/cfgtoollogs/dbca/$ORACLE_SID/$ORACLE_SID.log \
  || cat /opt/oracle/cfgtoollogs/dbca/$ORACLE_SID.log

# Remove second control file, fix local_listener, make PDB auto open, enable EM global port
sqlplus / as sysdba << EOF
   ALTER SYSTEM SET control_files='$ORACLE_BASE/oradata/$ORACLE_SID/control01.ctl' scope=spfile;
   ALTER SYSTEM SET local_listener='';
   ALTER PLUGGABLE DATABASE $ORACLE_PDB SAVE STATE;
   EXEC DBMS_XDB_CONFIG.SETGLOBALPORTENABLED (TRUE);
   exit;
EOF

echo "###########################################"
echo " Running modifications to PRIMARY database"
echo "###########################################"
echo " "

sqlplus / as sysdba << EOF
alter database force logging;
--alter system set db_create_file_dest='/opt/oracle/oradata/$ORACLE_SID' scope=both;
alter system set db_recovery_file_dest_size=5g scope=both;
alter system set db_recovery_file_dest='$ORACLE_BASE/oradata/$ORACLE_SID/fast_recovery_area' scope=both;
alter system set dg_broker_start=true scope=both;
--alter system set open_links=16 scope=spfile;
--alter system set open_links_per_instance=16 scope=spfile;
--alter system set event='10798 trace name context forever, level 7' SCOPE=spfile;
shutdown immediate
startup mount
alter database archivelog;
alter database flashback on;
alter database open;
alter session set container=$ORACLE_PDB;
EOF

# Remove auditing
# noaudit all;
# noaudit all on default;

# If this database has a DG Target assigned, create the standby redo logs:
if [[ ! -z "$DG_TARGET" ]]; then

echo "#############################################"
echo " Preparing $ORACLE_SID standby configuration"
echo "#############################################"
echo " "

# Add standby logs
sqlplus "/ as sysdba" <<EOF
alter database add standby logfile thread 1 group 4 size 200m;
alter database add standby logfile thread 1 group 5 size 200m;
alter database add standby logfile thread 1 group 6 size 200m;
alter database add standby logfile thread 1 group 7 size 200m;
alter system set standby_file_management=AUTO;
EOF

# Duplicate database for DG
echo "#############################################"
echo " Beginning duplicate of $ORACLE_SID to $DG_TARGET"
echo "#############################################"
echo " "

mkdir -p $ORACLE_BASE/cfgtoollogs/rmanduplicate
rman target sys/$ORACLE_PWD@$ORACLE_SID auxiliary sys/$ORACLE_PWD@$DG_TARGET log=$ORACLE_BASE/cfgtoollogs/rmanduplicate/$ORACLE_SID.log << EOF
duplicate target database
      for standby
     from active database
          dorecover
          spfile set db_unique_name='$DG_TARGET'
          nofilenamecheck;
EOF

cat $ORACLE_BASE/cfgtoollogs/rmanduplicate/$ORACLE_SID.log

echo "#############################################"
echo " Starting and configuring DataGuard Broker"
echo "#############################################"
echo " "

sqlplus "/ as sysdba" <<EOF
alter system set dg_broker_start=true;
EOF

dgmgrl sys/$ORACLE_PWD@$ORACLE_SID << EOF
create configuration $DG_CONFIG as primary database is $ORACLE_SID connect identifier is $ORACLE_SID;
add database $DG_TARGET as connect identifier is $DG_TARGET maintained as physical;
enable configuration;
edit database $ORACLE_SID set property StaticConnectIdentifier='(DESCRIPTION=(ADDRESS=(PROTOCOL=tcp)(HOST=${ORACLE_SID})(PORT=1521))(CONNECT_DATA=(SERVICE_NAME=${ORACLE_SID}_DGMGRL)(INSTANCE_NAME=${ORACLE_SID})(SERVER=DEDICATED)))';
edit database $DG_TARGET set property StaticConnectIdentifier='(DESCRIPTION=(ADDRESS=(PROTOCOL=tcp)(HOST=${DG_TARGET})(PORT=1521))(CONNECT_DATA=(SERVICE_NAME=${ORACLE_SID}_DGMGRL)(INSTANCE_NAME=${ORACLE_SID})(SERVER=DEDICATED)))';
EOF

echo "Waiting for configuration to take effect"
echo " "

sleep 60s

dgmgrl sys/$ORACLE_PWD@$ORACLE_SID << EOF
show configuration;
show database verbose $ORACLE_SID
show database verbose $DG_TARGET
validate database verbose $ORACLE_SID
validate database verbose $DG_TARGET
EOF

fi

else

# #############################################################
#                  Prepare a standby database                 #
# #############################################################

# Prepare the standby database.
echo "###########################################"
echo " Running modifications to STANDBY database"
echo "###########################################"
echo " "

# Create an additional diagnostic directory location and dummy alert log based on
# the unique name for the DG standby. This registers the diagnostic locations with
# subdirectories based on both the ORACLE_SID and the UNIQUE_NAME with the "tail -f"
# command at the end of the runOracle.sh script. If both directories aren't present,
# the log output of the standby database following a DG switch won't appear in the
# output of "docker logs -f".
mkdir -p ${ORACLE_BASE}/diag/rdbms/$(echo ${DB_UNQNAME,,})/${ORACLE_SID}/trace
touch ${ORACLE_BASE}/diag/rdbms/$(echo ${DB_UNQNAME,,})/${ORACLE_SID}/trace/alert_${ORACLE_SID}.log

# Create an entry in /etc/oratab:
cat << EOF >> /etc/oratab
${ORACLE_SID}:${ORACLE_HOME}:N
EOF

# Create a pfile for startup of the DG replication target:
cat << EOF > $ORACLE_HOME/dbs/initDG.ora
*.db_name='$ORACLE_SID'
EOF

# Create a password file on the replication target.
$ORACLE_HOME/bin/orapwd file=${ORACLE_BASE}/oradata/dbconfig/${ORACLE_SID}/orapw${ORACLE_SID} force=yes format=12 <<< $(echo $ORACLE_PWD)
ln -s $ORACLE_BASE/oradata/dbconfig/$ORACLE_SID/orapw$ORACLE_SID $ORACLE_HOME/dbs

# Start the DG target database in nomount
sqlplus / as sysdba <<EOF
startup nomount pfile='$ORACLE_HOME/dbs/initDG.ora';
EOF

# Start listener
lsnrctl start

echo "#########################################"
echo " End of modifications to STANDBY database"
echo "#########################################"
echo " "
fi

# Remove temporary response file
rm $ORACLE_BASE/dbca.rsp

# Moved the moveFiles/symLinkFiles functionality from runOracle.sh to here to preserve the files and create the links properly.

   if [ ! -d $ORACLE_BASE/oradata/dbconfig/$ORACLE_SID ]; then
      mkdir -p $ORACLE_BASE/oradata/dbconfig/$ORACLE_SID/
   fi;

   mv $ORACLE_HOME/dbs/spfile$ORACLE_SID.ora $ORACLE_BASE/oradata/dbconfig/$ORACLE_SID/
   mv $ORACLE_HOME/dbs/orapw$ORACLE_SID $ORACLE_BASE/oradata/dbconfig/$ORACLE_SID/
   mv $ORACLE_HOME/network/admin/sqlnet.ora $ORACLE_BASE/oradata/dbconfig/$ORACLE_SID/
   mv $ORACLE_HOME/network/admin/listener.ora $ORACLE_BASE/oradata/dbconfig/$ORACLE_SID/
   mv $ORACLE_HOME/network/admin/tnsnames.ora $ORACLE_BASE/oradata/dbconfig/$ORACLE_SID/

   # oracle user does not have permissions in /etc, hence cp and not mv
   cp /etc/oratab $ORACLE_BASE/oradata/dbconfig/$ORACLE_SID/

   if [ ! -L $ORACLE_HOME/dbs/spfile$ORACLE_SID.ora ]; then
      if [ -f $ORACLE_HOME/dbs/spfile$ORACLE_SID.ora ]; then
         mv $ORACLE_HOME/dbs/spfile$ORACLE_SID.ora $ORACLE_BASE/oradata/dbconfig/$ORACLE_SID/
      fi;
      ln -s $ORACLE_BASE/oradata/dbconfig/$ORACLE_SID/spfile$ORACLE_SID.ora $ORACLE_HOME/dbs/spfile$ORACLE_SID.ora
   fi;

   if [ ! -L $ORACLE_HOME/dbs/orapw$ORACLE_SID ]; then
      if [ -f $ORACLE_HOME/dbs/orapw$ORACLE_SID ]; then
         mv $ORACLE_HOME/dbs/orapw$ORACLE_SID $ORACLE_BASE/oradata/dbconfig/$ORACLE_SID/
      fi;
      ln -s $ORACLE_BASE/oradata/dbconfig/$ORACLE_SID/orapw$ORACLE_SID $ORACLE_HOME/dbs/orapw$ORACLE_SID
   fi;

   if [ ! -L $ORACLE_HOME/network/admin/sqlnet.ora ]; then
      if [ -f $ORACLE_HOME/network/admin/sqlnet.ora ]; then
         mv $ORACLE_HOME/network/admin/sqlnet.ora $ORACLE_BASE/oradata/dbconfig/$ORACLE_SID/
      fi;
      ln -s $ORACLE_BASE/oradata/dbconfig/$ORACLE_SID/sqlnet.ora $ORACLE_HOME/network/admin/sqlnet.ora
   fi;

   if [ ! -L $ORACLE_HOME/network/admin/listener.ora ]; then
      if [ -f $ORACLE_HOME/network/admin/listener.ora ]; then
         mv $ORACLE_HOME/network/admin/listener.ora $ORACLE_BASE/oradata/dbconfig/$ORACLE_SID/
      fi;
      ln -s $ORACLE_BASE/oradata/dbconfig/$ORACLE_SID/listener.ora $ORACLE_HOME/network/admin/listener.ora
   fi;

   if [ ! -L $ORACLE_HOME/network/admin/tnsnames.ora ]; then
      if [ -f $ORACLE_HOME/network/admin/tnsnames.ora ]; then
         mv $ORACLE_HOME/network/admin/tnsnames.ora $ORACLE_BASE/oradata/dbconfig/$ORACLE_SID/
      fi;
      ln -s $ORACLE_BASE/oradata/dbconfig/$ORACLE_SID/tnsnames.ora $ORACLE_HOME/network/admin/tnsnames.ora
   fi;

   # oracle user does not have permissions in /etc, hence cp and not ln
   if [ -f $ORACLE_BASE/oradata/dbconfig/$ORACLE_SID/oratab ]; then
      cp $ORACLE_BASE/oradata/dbconfig/$ORACLE_SID/oratab /etc/oratab
   fi;

   # oracle user does not have permissions in /etc, hence cp and not ln 
#   cp $ORACLE_BASE/oradata/dbconfig/$ORACLE_SID/oratab /etc/oratab

# End of moveFiles/symLinkFiles component
