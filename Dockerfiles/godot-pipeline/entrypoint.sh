#!/bin/bash
./config.sh --unattended --replace --name runner --url $GHA_URL --token $GHA_TOKEN
./run.sh

