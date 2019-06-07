#!/bin/bash
# Shared functions for tools/$OSI/deploy_jenkins_slave.sh files.
#
# Usage: sh tools/$OSI/deploy_jenkins_slave.sh [ARG]
#
# Possible ARG:
#     --build: build the package
#     --build-ext: build the FinderSync extension (macOS only)
#     --install: install all dependencies
#     --start: start Nuxeo Drive
#     --tests: launch the tests suite
#
# See /docs/deployment.md for more information.
#
# ---
#
# You can tweak tests checks by setting the SKIP envar:
#    - SKIP=flake8 to skip code style
#    - SKIP=mypy to skip type annotations
#    - SKIP=rerun to not rerun failed test(s)
#    - SKIP=all to skip all above (equivalent to flake8,mypy,rerun)
#    - SKIP=tests tu run only code checks
#
# There is no strict syntax about multiple skips (coma, coma + space, no separator, ... ).
#

set -e

# Global variables
PYTHON="python -Xutf8 -E -s"
PIP="${PYTHON} -m pip install --upgrade --upgrade-strategy=only-if-needed"

build_installer() {
    local version

    echo ">>> Building the release package"
    ${PYTHON} -m PyInstaller ndrive.spec --clean --noconfirm

    # Do some clean-up
    ${PYTHON} tools/cleanup_application_tree.py dist/ndrive
    if [ "${OSI}" = "osx" ]; then
        ${PYTHON} tools/cleanup_application_tree.py dist/*.app/Contents/Resources
        ${PYTHON} tools/cleanup_application_tree.py dist/*.app/Contents/MacOS

        # Move problematic folders out of Contents/MacOS
        ${PYTHON} tools/osx/fix_app_qt_folder_names_for_codesign.py dist/*.app

        # Remove broken symlinks pointing to an inexistant target
        find dist/*.app/Contents/MacOS -type l -exec sh -c 'for x; do [ -e "$x" ] || rm -v "$x"; done' _ {} +
    fi

    # Remove empty folders
    find dist/ndrive -depth -type d -empty -delete
    if [ "${OSI}" = "osx" ]; then
        find dist/*.app -depth -type d -empty -delete
    fi

    # Stop now if we only want the application to be frozen (for integration tests)
    if [ "${FREEZE_ONLY:=0}" = "1" ]; then
        exit 0
    fi

    version="$(${PYTHON} -m nxdrive --version)"
    cd dist
    zip -9 -r "nuxeo-drive-${OSI}-${version}.zip" "ndrive"
    cd -

    create_package
}

check_import() {
    # Check module import to know if it must be installed
    # i.e: check_import "from PyQt4 import QtWebKit"
    #  or: check_import "import cx_Freeze"
    local import="$1"
    local ret=0

    /bin/echo -n ">>> Checking Python code: ${import} ... "
    ${PYTHON} -c "${import}" 2>/dev/null || ret=1
    if [ ${ret} -ne 0 ]; then
        echo "Failed."
        return 1
    fi
    echo "OK."
}

check_vars() {
    # Check required variables
    if [ "${PYTHON_DRIVE_VERSION:=unset}" = "unset" ]; then
        export PYTHON_DRIVE_VERSION="3.6.8"  # XXX_PYTHON
    fi
    if [ "${WORKSPACE:=unset}" = "unset" ]; then
        echo "WORKSPACE not defined. Aborting."
        exit 1
    fi
    if [ "${OSI:=unset}" = "unset" ]; then
        echo "OSI not defined. Aborting."
        echo "Please do not call this script directly. Use the good one from 'tools/OS/deploy_jenkins_slave.sh'."
        exit 1
    fi
    if [ "${SKIP:=unset}" = "unset" ]; then
        export SKIP=""
    fi
    if [ "${WORKSPACE_DRIVE:=unset}" = "unset" ]; then
        if [ -d "${WORKSPACE}/sources" ]; then
            export WORKSPACE_DRIVE="${WORKSPACE}/sources"
        elif [ -d "${WORKSPACE}/nuxeo-drive" ]; then
            export WORKSPACE_DRIVE="${WORKSPACE}/nuxeo-drive"
        else
            export WORKSPACE_DRIVE="${WORKSPACE}"
        fi
    fi
    export STORAGE_DIR="${WORKSPACE}/deploy-dir"

    echo "    PYTHON_DRIVE_VERSION = ${PYTHON_DRIVE_VERSION}"
    echo "    WORKSPACE            = ${WORKSPACE}"
    echo "    WORKSPACE_DRIVE      = ${WORKSPACE_DRIVE}"
    echo "    STORAGE_DIR          = ${STORAGE_DIR}"
    echo "    SKIP                 = ${SKIP}"

    cd "${WORKSPACE_DRIVE}"

    if [ "${SPECIFIC_TEST:=unset}" = "unset" ] || [ "${SPECIFIC_TEST}" = "" ]; then
        export SPECIFIC_TEST="tests"
    else
        echo "    SPECIFIC_TEST        = ${SPECIFIC_TEST}"
        export SPECIFIC_TEST="tests/${SPECIFIC_TEST}"
    fi
}

install_deps() {
    echo ">>> Installing requirements"
    # Do not delete, it fixes "Could not import setuptools which is required to install from a source distribution."
    ${PIP} setuptools
    # NXDRIVE-1521: pip 19.0.1 prevents PyInstaller installation
    ${PIP} pip==18.1
    ${PIP} -r requirements.txt
    ${PIP} -r requirements-dev.txt
    if [ "${INSTALL_RELEASE_ARG:=0}" != "1" ]; then
        ${PIP} -r requirements-tests.txt
        pyenv rehash
        pre-commit install
    fi
}

install_pyenv() {
    local url="https://raw.githubusercontent.com/yyuu/pyenv-installer/master/bin/pyenv-installer"
    local venv_plugin
    local venv_plugin_url="https://github.com/yyuu/pyenv-virtualenv.git"

    export PYENV_ROOT="${STORAGE_DIR}/.pyenv"
    export PATH="${PYENV_ROOT}/bin:$PATH"

    venv_plugin="${PYENV_ROOT}/plugins/pyenv-virtualenv"

    if [ "${INSTALL_ARG:=0}" = "1" ]; then
        if [ ! -d "${PYENV_ROOT}" ]; then
            echo ">>> [pyenv] Downloading and installing"
            curl -L "${url}" | bash
        else
            echo ">>> [pyenv] Updating"
            cd "${PYENV_ROOT}"
            git pull
            cd -
        fi
        if [ ! -d "${venv_plugin}" ]; then
            echo ">>> [pyenv] Installing virtualenv plugin"
            git clone "${venv_plugin_url}" "${venv_plugin}"
        fi
    fi

    echo ">>> [pyenv] Initializing"
    eval "$(pyenv init -)"
    eval "$(pyenv virtualenv-init -)"
}

install_python() {
    local version="$1"

    # To fix Mac error when building the package "libpython27.dylib does not exist"
    [ "${OSI}" = "osx" ] && export PYTHON_CONFIGURE_OPTS="--enable-shared"

    pyenv install --skip-existing "${version}"

    echo ">>> [pyenv] Using Python ${version}"
    pyenv global "${version}"
}

launch_test() {
    # Launch tests on a specific path. On failure, retry failed tests.
    local cmd="${PYTHON} -bb -Wall -m pytest"
    local path="${1}"
    local pytest_args="${2:-}"

    ${cmd} ${pytest_args} "${path}" && return

    if [[ "${SKIP}" = *"rerun"* ]] || [[ "${SKIP}" = *"all"* ]]; then
        # Do not fail on error as all failures will be re-run another time at the end
        ${cmd} --last-failed --last-failed-no-failures none || true
    fi
}

launch_tests() {
    local ret

    # If a specific test is asked, just run it and bypass all over checks
    if [ "${SPECIFIC_TEST}" != "tests" ]; then
        echo ">>> Launching the specific tests"
        launch_test "${SPECIFIC_TEST}"
        return
    fi

    if [[ ! "${SKIP}" = *"flake8"* ]] && [[ ! "${SKIP}" = *"all"* ]]; then
        echo ">>> Checking the style"
        ${PYTHON} -m flake8 .
    fi

    if [[ ! "${SKIP}" = *"mypy"* ]] && [[ ! "${SKIP}" = *"all"* ]]; then
        echo ">>> Checking type annotations"
        ${PYTHON} -m mypy nxdrive
    fi

    if [[ "${SKIP}" = *"tests"* ]]; then
        # Skip all test cases
        return
    fi

    echo ">>> Launching unit tests"
    launch_test "tests/unit"

    echo ">>> Launching functional tests"
    launch_test "tests/functional"

    echo ">>> Launching synchronization functional tests, file by file"
    echo "    (first, run for each test file, failures are ignored to have"
    echo "     a whole picture of errors)"
    total="$(find tests/old_functional -name "test_*.py" | wc -l)"
    number=1
    for test_file in $(find tests/old_functional -name "test_*.py"); do
        echo ""
        echo ">>> [${number}/${total}] Testing ${test_file} ..."
        launch_test "${test_file}" "-q --durations=3"
        number=$(( number + 1 ))
    done

    if [[ ! "${SKIP}" = *"rerun"* ]] && [[ ! "${SKIP}" = *"all"* ]]; then
        echo ">>> Re-rerun failed tests"
        set +e
        ${PYTHON} -bb -Wall -m pytest --last-failed --last-failed-no-failures none
        # The above command will exit with error code 5 if there is no failure to rerun
        ret=$?
        set -e
        if [ $ret -ne 0 ] && [ $ret -ne 5 ]; then
            exit 1
        fi
    fi
}

start_nxdrive() {
    echo ">>> Starting Nuxeo Drive"

    export PYTHONPATH="${WORKSPACE_DRIVE}"
    ${PYTHON} -m nxdrive
}

verify_python() {
    local version="$1"
    local cur_version=$(${PYTHON} --version 2>&1 | head -n 1 | awk '{print $2}')

    echo ">>> Verifying Python version in use"

    if [ "${cur_version}" != "${version}" ]; then
        echo ">>> Python version ${cur_version}"
        echo ">>> Drive requires ${version}"
        exit 1
    fi

    # Also, check that primary modules are present (in case of wrong build)
    if ! check_import "import sqlite3"; then
        echo ">>> Uninstalling wrong Python version"
        pyenv uninstall -f "${PYTHON_DRIVE_VERSION}"
        install_python "${PYTHON_DRIVE_VERSION}"
    fi
}

# The main function, last in the script
main() {
    # Adjust PATH for Mac
    [ "${OSI}" = "osx" ] && export PATH="$PATH:/usr/local/bin:/usr/sbin"

    check_vars

    # The FinderSync extension build does not require extra setup
    if [ $# -eq 1 ]; then
        case "$1" in
            "--build-ext")
                build_extension
                exit 0
            ;;
            "--install")
                export INSTALL_ARG="1"
            ;;
            "--install-release")
                export INSTALL_ARG="1"
                export INSTALL_RELEASE_ARG="1"
            ;;
        esac
    fi

    # Launch operations
    install_pyenv
    install_python "${PYTHON_DRIVE_VERSION}"
    verify_python "${PYTHON_DRIVE_VERSION}"

    if [ $# -eq 1 ]; then
        case "$1" in
            "--build") build_installer ;;
            "--install" | "--install-release")
                install_deps
                if ! check_import "import PyQt5" >/dev/null; then
                    echo ">>> No PyQt5. Installation failed."
                    exit 1
                fi
                ;;
            "--start") start_nxdrive ;;
            "--tests") launch_tests ;;
        esac
    fi
}
