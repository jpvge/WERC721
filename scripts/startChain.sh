#!/bin/bash

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

# Load environment variables
source $SCRIPT_DIR/loadEnv.sh

anvil --fork-url $EXTERNAL_PROVIDER --steps-tracing --fork-block-number 17187072
