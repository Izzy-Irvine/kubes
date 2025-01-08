#!/bin/bash

# If already configered, don't do it again
if [ -s ~/.credentials ]; then
  exit
fi

./config.sh --unattended --replace --name runner --url $GHA_URL --token $GHA_TOKEN
