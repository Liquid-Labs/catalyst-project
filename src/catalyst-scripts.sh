#!/usr/bin/env bash

# bash strict settings
set -o errexit # exit on errors
set -o nounset # exit on use of uninitialized variable
set -o pipefail

ACTION="$1"; shift

import real_path
import find_exec

CATALYST_SCRIPTS_REAL_PATH="$(dirname "$(real_path "${BASH_SOURCE[0]}")")"
CONFIG_PATH="${CATALYST_SCRIPTS_REAL_PATH}/../config"

_ADD_SCRIPT_WARNING=false
function add_script() {
  KEY="${1:-}"
  VALUE="${2:-}"
  if [[ -z "$KEY" ]] || [[ -z "$VALUE" ]] || [[ -z "$ADDSCRIPT" ]]; then
    echo "INTERNAL ERROR: add script called without requried args." >&2
    exit 255
  fi

  $ADDSCRIPT -k "$KEY" -v "$VALUE" >/dev/null 2>/dev/null || (_ADD_SCRIPT_WARNING=true && $ADDSCRIPT -f -k "$KEY" -v "$VALUE" >/dev/null)
}

function test_all() {
  test -z "${TEST_TYPES:-}" || ( test_unit && test_integration )
}

function test_unit() {
  [[ -z "${TEST_TYPES:-}" ]] || echo "$TEST_TYPES" | grep -qE '(^|, *| +)unit?(, *| +|$)'
}

function test_integration() {
  [[ -z "${TEST_TYPES:-}" ]] || echo "$TEST_TYPES" | grep -qE '(^|, *| +)int(egration)?(, *| +|$)'
}

case "$ACTION" in
  setup-scripts)
    ADDSCRIPT=`require-exec npmAddScript "$LOCAL_TARGET_PACKAGE_ROOT"`
    add_script build 'catalyst-scripts build'
    add_script start 'catalyst-scripts start'
    add_script lint 'catalyst-scripts lint'
    add_script lint-fix 'catalyst-scripts lint-fix'
    add_script install-clean 'rm -rf package-lock.json node_modules/ && npm install'
    add_script prepare 'rm -rf dist && npm run lint && npm run build'
    add_script pretest 'catalyst-scripts pretest'
    add_script test 'catalyst-scripts test'
    if [[ "$_ADD_SCRIPT_WARNING" -eq "true" ]]; then
      echo "Possibly verwrote some existing scripts. Check your package.json diff and update as necessary."
    fi
  ;;
  pretest)
    if [[ -d 'go' ]]; then
      if test_integration && [[ -n "$(find go -name "sql.go" -print -quit)" ]]; then
        COMMAND='catalyst data rebuild sql || ( EXIT=$?; echo -e "If you want to run only unit tests, you can invoke the NPM command like\nTEST_TYPES=unit npm run test"; exit $EXIT )'
      else
        COMMAND=""
      fi
    fi
    if [[ -d 'js' ]]; then
      BABEL=`require-exec babel "$LOCAL_TARGET_PACKAGE_ROOT"`
      BABEL_CONFIG="${CONFIG_PATH}/babel.config.js"
      # Jest is not picking up the external maps, so we inline them for the test.
      COMMAND="${COMMAND}rm -rf test-staging; ${BABEL} --config-file ${BABEL_CONFIG} $LOCAL_TARGET_PACKAGE_ROOT/src --out-dir test-staging --source-maps=inline"
    fi
  ;;
  test)
    if [[ -d 'go' ]]; then
      if test_all; then
        COMMAND='cd go && env $(catalyst environments show | tail -n +2 | xargs) go test -v ./...;'
      elif test_unit; then
        COMMAND='cd go && env $(catalyst environments show | tail -n +2 | xargs) SKIP_INTEGRATION=true go test -v ./...;'
      elif test_integration; then
        COMMAND='cd go && env $(catalyst environments show | tail -n +2 | xargs) go test -v ./... -run Integration;'
      fi
    fi
    if [[ -d 'js' ]]; then
      JEST=`require-exec jest "$LOCAL_TARGET_PACKAGE_ROOT"`
      JEST_CONFIG="${CONFIG_PATH}/jest.config.js"
      # the '--runInBand' is necessary for the 'seqtests' to work.
      COMMAND="${COMMAND}${JEST} --config=${JEST_CONFIG} --runInBand ./test-staging"
    fi
  ;;
  build | start)
    ROLLUP=`require-exec rollup "$LOCAL_TARGET_PACKAGE_ROOT"`
    ROLLUP_CONFIG="${CONFIG_PATH}/rollup.config.js"
    COMMAND="${ROLLUP} --config ${ROLLUP_CONFIG}"
    if [[ "$ACTION" == 'start' ]]; then
      COMMAND="$COMMAND --watch"
    fi
  ;;
  lint | lint-fix)
    ESLINT_CONFIG="${CONFIG_PATH}/eslintrc.json"
    ESLINT=`require-exec eslint "$LOCAL_TARGET_PACKAGE_ROOT"`
    COMMAND="$ESLINT --ext .js,.jsx --config $ESLINT_CONFIG src/**"
    if [[ "$ACTION" == 'lint-fix' ]]; then
      COMMAND="$COMMAND --fix"
    fi
  ;;
  *)
    echo "Unknown catalyst-scripts action: '$ACTION'." >&2
    exit 1
  ;;
esac

eval $COMMAND
