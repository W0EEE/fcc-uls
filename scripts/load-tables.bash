#!/bin/bash

# I know, this script is really bad about code duplication
# that said, it's a shell script. it was never designed for
# maximal efficiency. nonetheless, there's an explanation.
# unfortunately, this has a lot to do with the absolutely
# archaic way the FCC does things, and a desire to keep
# the data in this replica as consistent as possible
# that said, the FCC is discussing replacing the ULS
# (yes, please!), so if that ever happens, here's this:
# TODO: reduce code repetition

# config via environment vars
# PATCHFILE: the corrections patch file
# DB: the postgres database to use
# WEEKDAY: use to override week day if manually rebuilding the db

tmpdir=$(mktemp -d)
printf "entering temp directory %s\n" "$tmpdir"
pushd $tmpdir

INCREMENTAL=unknown

current_dow=$(date +%a | tr '[:upper:]' '[:lower:]')
dow="${WEEKDAY:=$current_dow}"
if [ "$dow" = 'sun' ]; then
	file_tail='amat'
  type='complete'
	INCREMENTAL=0
else
	file_tail="am_$dow"
  type='daily'
	INCREMENTAL=1
fi

PUBACC_URL_PREFIX="${PUBACC_URL_PREFIX:=https://data.fcc.gov/download/pub/uls/}"

function abort_if_update_unnecessary() {
  l_server_mod_date=$(curl -sI $PUBACC_URL_PREFIX/$type/l_$file_tail.zip | grep -i last-modified | cut -d ':' -f 2-)
  a_server_mod_date=$(curl -sI $PUBACC_URL_PREFIX/$type/a_$file_tail.zip | grep -i last-modified | cut -d ':' -f 2-)

  l_server_mod_ts=$(date --date="$l_server_mod_date" +%s)
  a_server_mod_ts=$(date --date="$a_server_mod_date" +%s)

  modtimes=$(psql fcculs -Atc "select l_mod, a_mod from db_version where weekday = '$dow';")
  l_local_mod_ts=$(echo $modtimes | cut -d '|' -f 1)
  a_local_mod_ts=$(echo $modtimes | cut -d '|' -f 2)

  # we want to keep the data consistent, so wait until BOTH sides have an update available
  if [ $l_local_mod_ts -lt $l_server_mod_ts ] && [ $a_local_mod_ts -lt $a_server_mod_ts ]; then
    return 0
  else
    echo "we are up to date - no need to do another pull"
    exit 0
  fi
}

function download_pubacc() {
  mkdir license application

  echo "begin database download $type/*_$file_tail.zip"
  curl -s $PUBACC_URL_PREFIX/$type/l_$file_tail.zip -o license.zip && unzip license.zip -d license -x counts &
  curl -s $PUBACC_URL_PREFIX/$type/a_$file_tail.zip -o application.zip && unzip application.zip -d application -x counts &
  wait
  echo "download complete"

  for i in license/*; do mv $i l_$(basename $i); done
  for i in application/*; do mv $i a_$(basename $i); done
  rm -d license application
}

DB="${DB:=fcculs}"

function patch_files() {
  PATCHFILE="${PATCHFILE:=/usr/lib/fcc-uls/fix-anomalies.patch}"
  echo "incremental = $INCREMENTAL"
  if [ "$INCREMENTAL" = 0 ]; then
    patch --no-backup-if-mismatch <"$PATCHFILE" || err
  fi
}

function gen_db_stmts() {
  echo "BEGIN;"

  for datfile in *.dat
  do
    table=$(echo $datfile | cut -d . -f 1)

    if [ "$INCREMENTAL" = 1 ]; then
      cut -d '|' -f 2 $datfile | sed "s/.*/DELETE FROM $table WHERE unique_system_identifier = &;/"
    else
      echo "TRUNCATE $table;"
    fi

    { mv $datfile $datfile.crlf && tr -d '\r\\' < $datfile.crlf | cut -d '|' -f 2- > $datfile; } || { echo "ROLLBACK;"; return 1; }

    echo "\copy $table from '$PWD/$datfile' with (delimiter '|', null '');"
  done

  echo "UPDATE db_version SET l_mod = $l_server_mod_ts, a_mod = $a_server_mod_ts WHERE weekday = '$dow';"

  echo "COMMIT;"
}

abort_if_update_unnecessary
download_pubacc
patch_files
gen_db_stmts | psql fcculs -a -f -

rm *.crlf *.dat *.zip
popd
rm -d $tmpdir

echo "goodbye"

