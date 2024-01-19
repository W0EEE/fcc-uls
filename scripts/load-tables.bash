#!/bin/bash

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

mkdir license application db

echo "begin database download $type/d_$file_tail.zip"
curl -s https://data.fcc.gov/download/pub/uls/$type/l_$file_tail.zip -o license.zip && unzip license.zip -d license -x counts &
curl -s https://data.fcc.gov/download/pub/uls/$type/a_$file_tail.zip -o application.zip && unzip application.zip -d application -x counts &
wait
echo "download complete"

for i in license/*; do mv $i db/l_$(basename $i); done
for i in application/*; do mv $i db/a_$(basename $i); done
rm -d license application

pushd db

function err() {
  echo LT_ERROR
  touch error
}

DB="${DB:=fcculs}"

PATCHFILE="${PATCHFILE:=/usr/lib/fcc-uls/fix-anomalies.patch}"
echo "incremental = $INCREMENTAL"
if [ "$INCREMENTAL" = 0 ]; then
  patch <"$PATCHFILE" || err
fi

# take the database offline using version-lock behavior
echo "taking the database offline"
psql $DB -c "UPDATE db_version SET last_update = NULL;" || err

if [ ! -e error ]; then
for datfile in *.dat
do
  {
    table=$(echo $datfile | cut -d . -f 1)

    if [ "$INCREMENTAL" = 1 ]; then
      cut -d '|' -f 2 $datfile | sed "s/.*/DELETE FROM $table WHERE unique_system_identifier = &;/" | psql $DB -f - > /dev/null || err
    else
      psql $DB -c "DELETE FROM $table;" || err
    fi

    <$datfile tr -d '\r\\' | psql $DB -c "\copy $table from /dev/stdin with (delimiter '|', null '');" || err
  } &
done

wait
fi

# if something went wrong with the update, leave the db offline
if [ ! -e error ]; then
  echo "putting the database back online"
  psql $DB -c "UPDATE db_version SET last_update = 'now';"
else
  echo "leaving the database offline due to problems"
  rm error
fi

popd # back in the tempdir; clean up
rm db/* *.zip
rm -d db
popd
rm -d $tmpdir

echo "goodbye"

