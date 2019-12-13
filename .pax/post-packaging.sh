#!/bin/sh -e
#TODO -e is not documented as valid option, what is this supposed to do?
set -x

################################################################################
# This program and the accompanying materials are made available under the terms of the
# Eclipse Public License v2.0 which accompanies this distribution, and is available at
# https://www.eclipse.org/legal/epl-v20.html
#
# SPDX-License-Identifier: EPL-2.0
#
# Copyright IBM Corporation 2019
################################################################################

SCRIPT_NAME=$(basename "$0")
CURR_PWD=$(pwd)

#
# SCRIPT ENDS ON FIRST NON-ZERO RC
#

if [ "$BUILD_SMPE" != "yes" ]; then
  echo "[$SCRIPT_NAME] not building SMP/e package, skipping."
  exit 0
fi

if [ -z "${ZOWE_VERSION}" ]; then
  echo "[$SCRIPT_NAME][ERROR] ZOWE_VERSION environment variable is missing"
  exit 1
fi

# define constants for this build
SMPE_BUILD_ROOT=${CURR_PWD}/zowe
SMPE_BUILD_LOG_DIR=${SMPE_BUILD_ROOT}/logs # keep in sync with default log dir in smpe/bld/get-config.sh
SMPE_BUILD_SHIP_DIR=${SMPE_BUILD_ROOT}/ship # keep in sync with default ship dir in smpe/bld/get-config.sh
# random MLQ must begin with letter, @, #, or $, max 8 char
RANDOM_MLQ=ZWE$RANDOM  # RANDOM gives a random number between 0 & 32767
INPUT_TXT=input.txt
# FMID numbering is not VRM, just V(ersion)
ZOWE_VERSION_MAJOR=$(echo "${ZOWE_VERSION}" | awk -F. '{print $1}')
# pad ZOWE_VERSION_MAJOR to be at least 3 chars long, then keep last 3
FMID_VERSION=$(echo "00${ZOWE_VERSION_MAJOR}" | sed 's/.*\(...\)$/\1/')
FMID=AZWE${FMID_VERSION}

# define constants specific for Marist server
# to package on another server, we may need different settings
export TMPDIR=/ZOWE/tmp
SMPE_BUILD_HLQ=ZOWEAD3
SMPE_BUILD_VOLSER=ZOWE02

# add x permission to all smpe files
chmod -R 755 smpe

# create smpe.pax
cd ${CURR_PWD}/smpe/pax
pax -x os390 -w -f ../../smpe.pax *
cd ${CURR_PWD}

# extract last build log
LAST_BUILD_LOG=$(ls -1 ${CURR_PWD}/smpe/smpe-build-logs* || true)
if [ -n "${LAST_BUILD_LOG}" ]; then
  mkdir -p "${SMPE_BUILD_LOG_DIR}"
  cd "${SMPE_BUILD_LOG_DIR}"
  pax -rf "${CURR_PWD}/${LAST_BUILD_LOG}" *
  cd "${CURR_PWD}"
fi

# display all files, including input pax files & extracted log files
echo "[$SCRIPT_NAME] content of $CURR_PWD...."
find . -print

# find input pax files
if [ ! -f zowe.pax ]; then
  echo "[$SCRIPT_NAME][ERROR] Cannot find Zowe package."
  exit 1
fi
if [ ! -f smpe.pax ]; then
  echo "[$SCRIPT_NAME][ERROR] Cannot find SMP/e package."
  exit 1
fi

# SMPE build expects a text file specifying the files it must process
echo "[$SCRIPT_NAME] preparing ${INPUT_TXT} ..."
echo "${SMPE_BUILD_ROOT}.pax" > "${INPUT_TXT}"
echo "${CURR_PWD}/smpe.pax" >> "${INPUT_TXT}"
echo "[$SCRIPT_NAME] content of ${INPUT_TXT}:"
cat "${INPUT_TXT}"

mkdir -p ${SMPE_BUILD_ROOT}

# start SMPE build
#% required
#% -h hlq        use the specified high level qualifier
#% -i inputFile  reference file listing input files to process
#% -r rootDir    use the specified root directory
#% -v vrm        FMID 3-character version/release/modification
#% optional
#% -a alter.sh   execute script before/after install to alter setup
#% -d            enable debug messages
#% -V volume     allocate data sets on specified volume(s)

${CURR_PWD}/smpe/bld/smpe.sh \
  -V "${SMPE_BUILD_VOLSER}" \
  -a ${CURR_PWD}/smpe/bld/alter.sh \
  -d \
  -h "${SMPE_BUILD_HLQ}.${RANDOM_MLQ}" \
  -i "${CURR_PWD}/${INPUT_TXT}" \
  -r "${SMPE_BUILD_ROOT}" \
  -v ${FMID_VERSION}

# remove data sets, unless build option requested to keep temp stuff
if [ "$KEEP_TEMP_FOLDER" != "yes" ]; then
  datasets=$(${CURR_PWD}/smpe/bld/get-dsn.rex "${SMPE_BUILD_HLQ}.${RANDOM_MLQ}.**" || true)
  # rc is always 0, but error message has blanks while DSN list does not
  if [ -n "$(echo $datasets | grep ' ')" ]; then
    echo "$datasets"                     # variable holds error message
    # exit 1
  else
    # delete data sets
    for dsn in $datasets
    do
      tsocmd "DELETE '$dsn'" || true
    done    # for dsn
  fi
fi

# we no longer need the uppercase tempdir, so this should be obsolete
# remove tmp folder
UC_CURR_PWD=$(echo "${CURR_PWD}" | tr [a-z] [A-Z])
if [ "${UC_CURR_PWD}" != "${CURR_PWD}" ]; then
  # CURR_PWD will be removed after build automatically, we just need to delete
  # the extra temp folder in uppercase created by GIMZIP
  echo rm -fr "${UC_CURR_PWD}" # show in log whether this is still triggered
  rm -fr "${UC_CURR_PWD}"
fi

# save current build log, will be placed in artifactory
cd "${SMPE_BUILD_LOG_DIR}"
pax -w -f "${CURR_PWD}/smpe-build-logs.pax.Z" *

# find the final build results
cd "${SMPE_BUILD_SHIP_DIR}"
SMPE_FMID_ZIP="${FMID}.zip || true)" # keep in sync with smpe/bld/smpe-pd.sh
if [ ! -f "${SMPE_FMID_ZIP}" ]; then
  echo "[$SCRIPT_NAME][ERROR] cannot find SMPE_FMID_ZIP build result '${SMPE_FMID_ZIP}'"
  exit 1
fi
SMPE_PTF_ZIP="$(ls -1 ${FMID}.*.zip || true)" # keep in sync with smpe/bld/smpe-service.sh
if [ ! -f "${SMPE_PTF_ZIP}" ]; then
  echo "[$SCRIPT_NAME][ERROR] cannot find SMPE_PTF_ZIP build result '${SMPE_PTF_ZIP}'"
  exit 1
fi
SMPE_PD_HTM="${FMID}.htm || true)" # keep in sync with smpe/bld/smpe-pd.sh
if [ ! -f "${SMPE_PD_HTM}" ]; then
  echo "[$SCRIPT_NAME][ERROR] cannot find SMPE_PD_HTM build result '${SMPE_PD_HTM}'"
  exit 1
fi

# if ptf-bucket.txt exists then publish PTF, otherwise publish FMID
if [ -f ${CURR_PWD}/smpe/service/ptf-bucket.txt ]; then
  TO_PUBLISH=${SMPE_PTF_ZIP}
  NO_PUBLISH=${SMPE_FMID_ZIP}
else
  TO_PUBLISH=${SMPE_FMID_ZIP}
  NO_PUBLISH=${SMPE_PTF_ZIP}
fi

# stage build output for upload to artifactory
cd "${CURR_PWD}"
mv "${SMPE_BUILD_SHIP_DIR}/${NO_PUBLISH}  no-publish.zip"
mv "${SMPE_BUILD_SHIP_DIR}/${TO_PUBLISH}  publish.zip"
mv "${SMPE_BUILD_SHIP_DIR}/${SMPE_PD_HTM} pd.htm"

# prepare rename to original name
echo "mv no-publish.zip ${NO_PUBLISH}" >  "rename-back.sh.1047"
echo "mv publish.zip    ${TO_PUBLISH}" >> "rename-back.sh.1047"
# keep fixed name for PD to simplify automated processing by doc build
#echo "mv pd.htm         ${SMPE_PD_HTM}" >> "rename-back.sh.1047"
iconv -f IBM-1047 -t ISO8859-1 rename-back.sh.1047 > rename-back.sh
