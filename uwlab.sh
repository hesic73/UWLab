#!/usr/bin/env bash

# Copyright (c) 2022-2025, The UW Lab Project Developers (https://github.com/uw-lab/UWLab/blob/main/CONTRIBUTORS.md).
# All rights reserved.
#
# SPDX-License-Identifier: BSD-3-Clause

#==
# Configurations
#==

# Exits if error occurs
set -e

# Set tab-spaces
tabs 4

# get source directory
export UWLAB_PATH="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

#==
# Helper functions
#==

# install system dependencies
install_system_deps() {
    # check if cmake is already installed
    if command -v cmake &> /dev/null; then
        echo "[INFO] cmake is already installed."
    else
        # check if running as root
        if [ "$EUID" -ne 0 ]; then
            echo "[INFO] Installing system dependencies..."
            sudo apt-get update && sudo apt-get install -y --no-install-recommends \
                cmake \
                build-essential
        else
            echo "[INFO] Installing system dependencies..."
            apt-get update && apt-get install -y --no-install-recommends \
                cmake \
                build-essential
        fi
    fi
}

# Print the installed Isaac Sim version. Works with both binary and pip installs.
extract_isaacsim_version() {
    local version=""
    local python_exe
    python_exe=$(extract_python_exe)

    # 0) Fast path: read VERSION file from the symlinked _isaac_sim directory (binary install)
    # If the repository has _isaac_sim → <IsaacSimRoot> symlink, the VERSION file is the simplest source of truth.
    if [[ -f "${UWLAB_PATH}/_isaac_sim/VERSION" ]]; then
        # Read first line of the VERSION file; don't fail the whole script on errors.
        version=$(head -n1 "${UWLAB_PATH}/_isaac_sim/VERSION" || true)
    fi

    # 1) Package-path probe: import isaacsim and walk up to ../../VERSION (pip or nonstandard layouts)
    # If we still don't know the version, ask Python where the isaacsim package lives
    if [[ -z "$version" ]]; then
        local sim_file=""
        # Print isaacsim.__file__; suppress errors so set -e won't abort.
        sim_file=$("${python_exe}" -c 'import isaacsim, os; print(isaacsim.__file__)' 2>/dev/null || true)
        if [[ -n "$sim_file" ]]; then
            local version_path
            version_path="$(dirname "$sim_file")/../../VERSION"
            # If that VERSION file exists, read it.
            [[ -f "$version_path" ]] && version=$(head -n1 "$version_path" || true)
        fi
    fi

    # 2) Fallback: use package metadata via importlib.metadata.version("isaacsim")
    if [[ -z "$version" ]]; then
        version=$("${python_exe}" <<'PY' 2>/dev/null || true
from importlib.metadata import version, PackageNotFoundError
try:
    print(version("isaacsim"))
except PackageNotFoundError:
    pass
PY
)
    fi

    echo "$version"
}

# Isaac Lab 3.0 targets Isaac Sim 6.0 and Python 3.12. Fail before pip can
# partially replace a working simulator environment with incompatible packages.
validate_isaacsim_6_env() {
    local python_exe
    local python_version
    local isaacsim_version
    python_exe=$(extract_python_exe)
    python_version=$(${python_exe} -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
    isaacsim_version=$(extract_isaacsim_version)

    if [[ "$python_version" != "3.12" ]]; then
        echo "[ERROR] Isaac Sim 6.x requires Python 3.12; found Python ${python_version} at ${python_exe}." >&2
        exit 1
    fi
    if [[ "$isaacsim_version" != 6.0.0.1* ]]; then
        echo "[ERROR] UW Lab is configured for Isaac Sim 6.0.0.1; found '${isaacsim_version:-not installed}'." >&2
        echo "[ERROR] Install 'isaacsim[all,extscache]==6.0.0.1' in the active environment first." >&2
        exit 1
    fi
}

# check if running in docker
is_docker() {
    [ -f /.dockerenv ] || \
    grep -q docker /proc/1/cgroup || \
    [[ $(cat /proc/1/comm) == "containerd-shim" ]] || \
    grep -q docker /proc/mounts || \
    [[ "$(hostname)" == *"."* ]]
}

# check if running on ARM architecture
is_arm() {
    [[ "$(uname -m)" == "aarch64" ]] || [[ "$(uname -m)" == "arm64" ]]
}

# extract isaac sim path
extract_isaacsim_path() {
    # Use the sym-link path to Isaac Sim directory
    local isaac_path=${UWLAB_PATH}/_isaac_sim
    # If above path is not available, try to find the path using python
    if [ ! -d "${isaac_path}" ]; then
        # Use the python executable to get the path
        local python_exe=$(extract_python_exe)
        # Retrieve the path importing isaac sim and getting the environment path
        if [ $(${python_exe} -m pip list | grep -c 'isaacsim-rl') -gt 0 ]; then
            local isaac_path=$(${python_exe} -c "import isaacsim; import os; print(os.environ['ISAAC_PATH'])")
        fi
    fi
    # check if there is a path available
    if [ ! -d "${isaac_path}" ]; then
        # throw an error if no path is found
        echo -e "[ERROR] Unable to find the Isaac Sim directory: '${isaac_path}'" >&2
        echo -e "\tThis could be due to the following reasons:" >&2
        echo -e "\t1. Conda environment is not activated." >&2
        echo -e "\t2. Isaac Sim pip package 'isaacsim-rl' is not installed." >&2
        echo -e "\t3. Isaac Sim directory is not available at the default path: ${UWLAB_PATH}/_isaac_sim" >&2
        # exit the script
        exit 1
    fi
    # return the result
    echo ${isaac_path}
}

# extract the python from isaacsim
extract_python_exe() {
    # check if using conda
    if ! [[ -z "${CONDA_PREFIX}" ]]; then
        # use conda python
        local python_exe=${CONDA_PREFIX}/bin/python
    elif ! [[ -z "${VIRTUAL_ENV}" ]]; then
        # use uv virtual environment python
        local python_exe=${VIRTUAL_ENV}/bin/python
    else
        # use kit python
        local python_exe=${UWLAB_PATH}/_isaac_sim/python.sh

    if [ ! -f "${python_exe}" ]; then
            # note: we need to check system python for cases such as docker
            # inside docker, if user installed into system python, we need to use that
            # otherwise, use the python from the kit
            if [ $(python -m pip list | grep -c 'isaacsim-rl') -gt 0 ]; then
                local python_exe=$(which python)
            fi
        fi
    fi
    # check if there is a python path available
    if [ ! -f "${python_exe}" ]; then
        echo -e "[ERROR] Unable to find any Python executable at path: '${python_exe}'" >&2
        echo -e "\tThis could be due to the following reasons:" >&2
        echo -e "\t1. Conda or uv environment is not activated." >&2
        echo -e "\t2. Isaac Sim pip package 'isaacsim-rl' is not installed." >&2
        echo -e "\t3. Python executable is not available at the default path: ${UWLAB_PATH}/_isaac_sim/python.sh" >&2
        exit 1
    fi
    # return the result
    echo ${python_exe}
}

# extract the simulator exe from isaacsim
extract_isaacsim_exe() {
    # obtain the isaac sim path
    local isaac_path=$(extract_isaacsim_path)
    # isaac sim executable to use
    local isaacsim_exe=${isaac_path}/isaac-sim.sh
    # check if there is a python path available
    if [ ! -f "${isaacsim_exe}" ]; then
        # check for installation using Isaac Sim pip
        # note: pip installed Isaac Sim can only come from a direct
        # python environment, so we can directly use 'python' here
        if [ $(python -m pip list | grep -c 'isaacsim-rl') -gt 0 ]; then
            # Isaac Sim - Python packages entry point
            local isaacsim_exe="isaacsim isaacsim.exp.full"
        else
            echo "[ERROR] No Isaac Sim executable found at path: ${isaac_path}" >&2
            exit 1
        fi
    fi
    # return the result
    echo ${isaacsim_exe}
}

# find pip command based on virtualization
extract_pip_command() {
    # detect if we're in a uv environment
    if [ -n "${VIRTUAL_ENV}" ] && [ -f "${VIRTUAL_ENV}/pyvenv.cfg" ] && grep -q "uv" "${VIRTUAL_ENV}/pyvenv.cfg"; then
        pip_command="uv pip install"
    else
        # retrieve the python executable
        python_exe=$(extract_python_exe)
        pip_command="${python_exe} -m pip install"
    fi

    echo ${pip_command}
}

extract_pip_uninstall_command() {
    # detect if we're in a uv environment
    if [ -n "${VIRTUAL_ENV}" ] && [ -f "${VIRTUAL_ENV}/pyvenv.cfg" ] && grep -q "uv" "${VIRTUAL_ENV}/pyvenv.cfg"; then
        pip_uninstall_command="uv pip uninstall"
    else
        # retrieve the python executable
        python_exe=$(extract_python_exe)
        pip_uninstall_command="${python_exe} -m pip uninstall -y"
    fi

    echo ${pip_uninstall_command}
}

# check if input directory is a python extension and install the module
install_uwlab_extension() {
    # retrieve the python executable
    python_exe=$(extract_python_exe)
    pip_command=$(extract_pip_command)

    # if the directory contains setup.py then install the python module
    if [ -f "$1/setup.py" ]; then
        echo -e "\t module: $1"
        $pip_command --editable "$1"
    fi
}

# Build PyTorch3D against the active Torch/CUDA ABI. Python 3.12 + Torch 2.11
# has no compatible prebuilt PyTorch3D wheel, and its build imports torch, so
# PEP 517 build isolation cannot be used.
ensure_pytorch3d() {
    local python_exe
    local pip_command
    python_exe=$(extract_python_exe)
    pip_command=$(extract_pip_command)

    if "${python_exe}" -c 'import torch; from pytorch3d import _C' >/dev/null 2>&1; then
        echo "[INFO] PyTorch3D with compiled extensions is already installed."
        return 0
    fi

    local torch_cuda
    torch_cuda=$("${python_exe}" -c 'import torch; print(torch.version.cuda or "")')
    if [[ "$torch_cuda" != 12.8* ]]; then
        echo "[ERROR] PyTorch3D build expects the Isaac Lab Torch cu128 build; found CUDA '${torch_cuda}'." >&2
        exit 1
    fi

    local cuda_root="/usr/local/cuda-12.8"
    if [[ ! -x "${cuda_root}/bin/nvcc" ]] || ! "${cuda_root}/bin/nvcc" --version | grep -q 'release 12.8'; then
        echo "[ERROR] PyTorch3D requires the system CUDA 12.8 toolkit at ${cuda_root}." >&2
        echo "[ERROR] Install it with: sudo apt install cuda-toolkit-12-8" >&2
        exit 1
    fi

    local pytorch3d_ref="${UWLAB_PYTORCH3D_REF:-c8fcd83ff96fa0a5893c0b994f9285d7aa772540}"
    echo "[INFO] Building required PyTorch3D (${pytorch3d_ref}) for Torch ${torch_cuda}, sm_120 ..."
    CUDA_HOME="${cuda_root}" \
    CC=/usr/bin/gcc-11 \
    CXX=/usr/bin/g++-11 \
    FORCE_CUDA=1 \
    TORCH_CUDA_ARCH_LIST=12.0 \
    MAX_JOBS="${MAX_JOBS:-8}" \
        ${pip_command} --no-build-isolation \
        "pytorch3d @ git+https://github.com/facebookresearch/pytorch3d.git@${pytorch3d_ref}"

    "${python_exe}" -c 'import torch; from pytorch3d import _C' || {
        echo "[ERROR] PyTorch3D installed but its compiled extension could not be imported." >&2
        exit 1
    }
}

# Resolve Torch-bundled libgomp and prepend to LD_PRELOAD, once per shell session
write_torch_gomp_hooks() {
  mkdir -p "${CONDA_PREFIX}/etc/conda/activate.d" "${CONDA_PREFIX}/etc/conda/deactivate.d"

  # activation: resolve Torch's libgomp via this env's Python and prepend to LD_PRELOAD
  cat > "${CONDA_PREFIX}/etc/conda/activate.d/torch_gomp.sh" <<'EOS'
# Resolve Torch-bundled libgomp and prepend to LD_PRELOAD (quiet + idempotent)
: "${_IL_PREV_LD_PRELOAD:=${LD_PRELOAD-}}"

__gomp="$("$CONDA_PREFIX/bin/python" - <<'PY' 2>/dev/null || true
import pathlib
try:
    import torch
    p = pathlib.Path(torch.__file__).parent / 'lib' / 'libgomp.so.1'
    print(p if p.exists() else "", end="")
except Exception:
    pass
PY
)"

if [ -n "$__gomp" ] && [ -r "$__gomp" ]; then
  case ":${LD_PRELOAD:-}:" in
    *":$__gomp:"*) : ;;  # already present
    *) export LD_PRELOAD="$__gomp${LD_PRELOAD:+:$LD_PRELOAD}";;
  esac
fi
unset __gomp
EOS

  # deactivation: restore original LD_PRELOAD
  cat > "${CONDA_PREFIX}/etc/conda/deactivate.d/torch_gomp_unset.sh" <<'EOS'
# restore LD_PRELOAD to pre-activation value
if [ -v _IL_PREV_LD_PRELOAD ]; then
  export LD_PRELOAD="$_IL_PREV_LD_PRELOAD"
  unset _IL_PREV_LD_PRELOAD
fi
EOS
}

# Temporarily unset LD_PRELOAD (ARM only) for a block of commands
begin_arm_install_sandbox() {
    if is_arm && [[ -n "${LD_PRELOAD:-}" ]]; then
        export _IL_SAVED_LD_PRELOAD="$LD_PRELOAD"
        unset LD_PRELOAD
        echo "[INFO] ARM install sandbox: temporarily unsetting LD_PRELOAD for installation."
    fi
    # ensure we restore even if a command fails (set -e)
    trap 'end_arm_install_sandbox' EXIT
}

end_arm_install_sandbox() {
    if [[ -n "${_IL_SAVED_LD_PRELOAD:-}" ]]; then
        export LD_PRELOAD="$_IL_SAVED_LD_PRELOAD"
        unset _IL_SAVED_LD_PRELOAD
    fi
    # remove trap so later exits don’t re-run restore
    trap - EXIT
}

# setup anaconda environment for UW Lab
setup_conda_env() {
    # get environment name from input
    local env_name=$1
    # check conda is installed
    if ! command -v conda &> /dev/null
    then
        echo "[ERROR] Conda could not be found. Please install conda and try again."
        exit 1
    fi

    # check if _isaac_sim symlink exists and isaacsim-rl is not installed via pip
    if [ ! -L "${UWLAB_PATH}/_isaac_sim" ] && ! python -m pip list | grep -q 'isaacsim-rl'; then
        echo -e "[WARNING] _isaac_sim symlink not found at ${UWLAB_PATH}/_isaac_sim"
        echo -e "\tThis warning can be ignored if you plan to install Isaac Sim via pip."
        echo -e "\tIf you are using a binary installation of Isaac Sim, please ensure the symlink is created before setting up the conda environment."
    fi

    # check if the environment exists
    if { conda env list | grep -w ${env_name}; } >/dev/null 2>&1; then
        echo -e "[INFO] Conda environment named '${env_name}' already exists."
    else
        echo -e "[INFO] Creating conda environment named '${env_name}'..."
        echo -e "[INFO] Installing dependencies from ${UWLAB_PATH}/environment.yml"

        conda env create -y --file ${UWLAB_PATH}/environment.yml -n ${env_name}
    fi

    # cache current paths for later
    cache_pythonpath=$PYTHONPATH
    cache_ld_library_path=$LD_LIBRARY_PATH
    # clear any existing files
    rm -f ${CONDA_PREFIX}/etc/conda/activate.d/setenv.sh
    rm -f ${CONDA_PREFIX}/etc/conda/deactivate.d/unsetenv.sh
    # activate the environment
    source $(conda info --base)/etc/profile.d/conda.sh
    conda activate ${env_name}
    # setup directories to load Isaac Sim variables
    mkdir -p ${CONDA_PREFIX}/etc/conda/activate.d
    mkdir -p ${CONDA_PREFIX}/etc/conda/deactivate.d

    # add variables to environment during activation
    printf '%s\n' '#!/usr/bin/env bash' '' \
        '# for UW Lab' \
        'export UWLAB_PATH='${UWLAB_PATH}'' \
        'alias uwlab='${UWLAB_PATH}'/uwlab.sh' \
        '' \
        '# show icon if not running headless' \
        'export RESOURCE_NAME="IsaacSim"' \
        '' > ${CONDA_PREFIX}/etc/conda/activate.d/setenv.sh

    write_torch_gomp_hooks
    # check if we have _isaac_sim directory -> if so that means binaries were installed.
    # we need to setup conda variables to load the binaries
    local isaacsim_setup_conda_env_script=${UWLAB_PATH}/_isaac_sim/setup_conda_env.sh

    if [ -f "${isaacsim_setup_conda_env_script}" ]; then
        # add variables to environment during activation
        printf '%s\n' \
            '# for Isaac Sim' \
            'source '${isaacsim_setup_conda_env_script}'' \
            '' >> ${CONDA_PREFIX}/etc/conda/activate.d/setenv.sh
    fi

    # reactivate the environment to load the variables
    # needed because deactivate complains about UW Lab alias since it otherwise doesn't exist
    conda activate ${env_name}

    # remove variables from environment during deactivation
    printf '%s\n' '#!/usr/bin/env bash' '' \
        '# for UW Lab' \
        'unalias uwlab &>/dev/null' \
        'unset UWLAB_PATH' \
        '' \
        '# restore paths' \
        'export PYTHONPATH='${cache_pythonpath}'' \
        'export LD_LIBRARY_PATH='${cache_ld_library_path}'' \
        '' \
        '# for Isaac Sim' \
        'unset RESOURCE_NAME' \
        '' > ${CONDA_PREFIX}/etc/conda/deactivate.d/unsetenv.sh

    # check if we have _isaac_sim directory -> if so that means binaries were installed.
    if [ -f "${isaacsim_setup_conda_env_script}" ]; then
        # add variables to environment during activation
        printf '%s\n' \
            '# for Isaac Sim' \
            'unset CARB_APP_PATH' \
            'unset EXP_PATH' \
            'unset ISAAC_PATH' \
            '' >> ${CONDA_PREFIX}/etc/conda/deactivate.d/unsetenv.sh
    fi

    # deactivate the environment
    conda deactivate
    # add information to the user about alias
    echo -e "[INFO] Added 'uwlab' alias to conda environment for 'uwlab.sh' script."
    echo -e "[INFO] Created conda environment named '${env_name}'.\n"
    echo -e "\t\t1. To activate the environment, run:                conda activate ${env_name}"
    echo -e "\t\t2. To install UW Lab extensions, run:            uwlab -i"
    echo -e "\t\t3. To perform formatting, run:                      uwlab -f"
    echo -e "\t\t4. To deactivate the environment, run:              conda deactivate"
    echo -e "\n"
}

# setup uv environment for UW Lab
setup_uv_env() {
    # get environment name from input
    local env_name="$1"
    local python_path="$2"

    # check uv is installed
    if ! command -v uv &>/dev/null; then
        echo "[ERROR] uv could not be found. Please install uv and try again."
        echo "[ERROR] uv can be installed here:"
        echo "[ERROR] https://docs.astral.sh/uv/getting-started/installation/"
        exit 1
    fi

    # check if _isaac_sim symlink exists and isaacsim-rl is not installed via pip
    if [ ! -L "${UWLAB_PATH}/_isaac_sim" ] && ! python -m pip list | grep -q 'isaacsim-rl'; then
        echo -e "[WARNING] _isaac_sim symlink not found at ${UWLAB_PATH}/_isaac_sim"
        echo -e "\tThis warning can be ignored if you plan to install Isaac Sim via pip."
        echo -e "\tIf you are using a binary installation of Isaac Sim, please ensure the symlink is created before setting up the conda environment."
    fi

    # check if the environment exists
    local env_path="${UWLAB_PATH}/${env_name}"
    if [ ! -d "${env_path}" ]; then
        echo -e "[INFO] Creating uv environment named '${env_name}'..."
        uv venv --clear --python "${python_path}" "${env_path}"
    else
        echo "[INFO] uv environment '${env_name}' already exists."
    fi

    # define root path for activation hooks
    local uwlab_root="${UWLAB_PATH}"

    # cache current paths for later
    cache_pythonpath=$PYTHONPATH
    cache_ld_library_path=$LD_LIBRARY_PATH

    # ensure activate file exists
    touch "${env_path}/bin/activate"

     # add variables to environment during activation
    cat >> "${env_path}/bin/activate" <<EOF
export UWLAB_PATH="${UWLAB_PATH}"
alias uwlab="${UWLAB_PATH}/uwlab.sh"
export RESOURCE_NAME="IsaacSim"

if [ -f "${UWLAB_PATH}/_isaac_sim/setup_conda_env.sh" ]; then
    . "${UWLAB_PATH}/_isaac_sim/setup_conda_env.sh"
fi
EOF

    # add information to the user about alias
    echo -e "[INFO] Added 'uwlab' alias to uv environment for 'uwlab.sh' script."
    echo -e "[INFO] Created uv environment named '${env_name}'.\n"
    echo -e "\t\t1. To activate the environment, run:                source ${env_name}/bin/activate."
    echo -e "\t\t2. To install UW Lab extensions, run:            uwlab -i"
    echo -e "\t\t3. To perform formatting, run:                      uwlab -f"
    echo -e "\t\t4. To deactivate the environment, run:              deactivate"
    echo -e "\n"
}


# update the vscode settings from template and isaac sim settings
update_vscode_settings() {
    echo "[INFO] Setting up vscode settings..."
    # retrieve the python executable
    python_exe=$(extract_python_exe)
    # path to setup_vscode.py
    setup_vscode_script="${UWLAB_PATH}/.vscode/tools/setup_vscode.py"
    # check if the file exists before attempting to run it
    if [ -f "${setup_vscode_script}" ]; then
        ${python_exe} "${setup_vscode_script}"
    else
        echo "[WARNING] Unable to find the script 'setup_vscode.py'. Aborting vscode settings setup."
    fi
}

# print the usage description
print_help () {
    echo -e "\nusage: $(basename "$0") [-h] [-i] [-f] [-p] [-s] [-t] [-o] [-v] [-d] [-n] [-c] [-u] -- Utility to manage UW Lab."
    echo -e "\noptional arguments:"
    echo -e "\t-h, --help           Display the help content."
    echo -e "\t-i, --install [LIB]  Install the extensions inside UW Lab and learning frameworks as extra dependencies. Default is 'all'."
    echo -e "\t-f, --format         Run pre-commit to format the code and check lints."
    echo -e "\t-p, --python         Run the python executable provided by Isaac Sim or virtual environment (if active)."
    echo -e "\t-s, --sim            Run the simulator executable (isaac-sim.sh) provided by Isaac Sim."
    echo -e "\t-t, --test           Run all python pytest tests."
    echo -e "\t-o, --docker         Run the docker container helper script (docker/container.sh)."
    echo -e "\t-v, --vscode         Generate the VSCode settings file from template."
    echo -e "\t-d, --docs           Build the documentation from source using sphinx."
    echo -e "\t-n, --new            Create a new external project or internal task from template."
    echo -e "\t-c, --conda [NAME]   Create the conda environment for UW Lab. Default name is 'env_uwlab'."
    echo -e "\t-u, --uv [NAME]      Create the uv environment for UW Lab. Default name is 'env_uwlab'."
    echo -e "\n" >&2
}


#==
# Main
#==

# check argument provided
if [ -z "$*" ]; then
    echo "[Error] No arguments provided." >&2;
    print_help
    exit 0
fi

# pass the arguments
while [[ $# -gt 0 ]]; do
    # read the key
    case "$1" in
        -i|--install)
            validate_isaacsim_6_env
            # install system dependencies first
            install_system_deps
            # install the python packages in UWLab/source directory
            echo "[INFO] Installing extensions inside the UW Lab repository..."
            python_exe=$(extract_python_exe)
            pip_command=$(extract_pip_command)
            pip_uninstall_command=$(extract_pip_uninstall_command)

            # if on ARM arch, temporarily clear LD_PRELOAD
            # LD_PRELOAD is restored below, after installation
            begin_arm_install_sandbox

            # Recursively look into UW Lab directories and install them.
            export -f extract_python_exe
            export -f extract_pip_command
            export -f extract_pip_uninstall_command
            export -f install_uwlab_extension
            # Isaac Sim 6.0 requires Isaac Lab 3.0. The legacy main branch is
            # Isaac Lab 2.x and only supports Isaac Sim through 5.1.
            isaaclab_ref="${UWLAB_ISAACLAB_REF:-develop}"
            echo "[INFO] Installing upstream Isaac Lab 3.0 (${isaaclab_ref}) into ${UWLAB_PATH}/_isaaclab ..."
            repo_root="${UWLAB_PATH}/_isaaclab/IsaacLab"
            mkdir -p "${UWLAB_PATH}/_isaaclab"
            if [ ! -d "${repo_root}/.git" ]; then
                git clone --depth 1 --branch "${isaaclab_ref}" https://github.com/isaac-sim/IsaacLab.git "${repo_root}"
            else
                if [ -n "$(git -C "${repo_root}" status --porcelain)" ]; then
                    echo "[ERROR] ${repo_root} has local changes; refusing to change its Isaac Lab revision." >&2
                    echo "[ERROR] Commit/stash those changes, or remove this generated dependency checkout and retry." >&2
                    exit 1
                fi
                echo "[INFO] Updating existing Isaac Lab checkout to ${isaaclab_ref} ..."
                git -C "${repo_root}" fetch --depth 1 origin "${isaaclab_ref}"
                git -C "${repo_root}" checkout --detach FETCH_HEAD
            fi
            # Delegate the centralized Isaac Lab 3.0 dependency set (including
            # the matching Torch build) to its own installer. UW Lab installs
            # its chosen RL framework below.
            "${repo_root}/isaaclab.sh" --install core
            # Isaac Sim 6.0.0.1 declares the complete Torch trio. Isaac Lab's
            # current installer pins torch/torchvision but does not install
            # torchaudio, so complete the matching cu128 stack here.
            ${pip_command} --index-url https://download.pytorch.org/whl/cu128 "torchaudio==2.11.0"
            # Isaac Lab develop currently upgrades several packages beyond the
            # versions embedded in Isaac Sim 6.0.0.1. Restore the simulator's
            # native ABI pins; the PhysX workflow remains compatible with them.
            ${pip_command} \
                "typing_extensions==4.12.2" \
                "llvmlite==0.46.0" \
                "numba==0.63.1" \
                "onnx==1.19.1" \
                "newton[sim]==1.2.0" \
                "newton-usd-schemas==0.2.0"
            if [ -n "${CONDA_PREFIX:-}" ]; then
                write_torch_gomp_hooks
            fi
            echo "[INFO] Upstream Isaac Lab 3.0 core installed from ${repo_root}."
            ensure_pytorch3d
            # source directory
            find -L "${UWLAB_PATH}/source" -mindepth 1 -maxdepth 1 -type d -exec bash -c 'install_uwlab_extension "{}"' \;
            # install the python packages for supported reinforcement learning frameworks
            echo "[INFO] Installing extra requirements such as learning frameworks..."
            # check if specified which rl-framework to install
            if [ -z "$2" ]; then
                echo "[INFO] Installing all rl-frameworks..."
                framework_name="all"
            elif [ "$2" = "none" ]; then
                echo "[INFO] No rl-framework will be installed."
                framework_name="none"
                shift # past argument
            else
                echo "[INFO] Installing rl-framework: $2"
                framework_name=$2
                shift # past argument
            fi
            # install the learning frameworks specified
            if [ "${framework_name}" != "none" ]; then
                ${pip_command} -e "${UWLAB_PATH}/source/uwlab_rl[${framework_name}]"
            fi

            # restore LD_PRELOAD if we cleared it
            end_arm_install_sandbox

            # check if we are inside a docker container or are building a docker image
            # in that case don't setup VSCode since it asks for EULA agreement which triggers user interaction
            if is_docker; then
                echo "[INFO] Running inside a docker container. Skipping VSCode settings setup."
                echo "[INFO] To setup VSCode settings, run 'uwlab -v'."
            else
                # update the vscode settings
                update_vscode_settings
            fi

             # unset local variables
            unset extract_python_exe
            unset extract_pip_command
            unset extract_pip_uninstall_command
            unset install_uwlab_extension
            shift # past argument
            ;;
        -c|--conda)
            # use default name if not provided
            if [ -z "$2" ]; then
                echo "[INFO] Using default conda environment name: env_uwlab"
                conda_env_name="env_uwlab"
            else
                echo "[INFO] Using conda environment name: $2"
                conda_env_name=$2
                shift # past argument
            fi
            # setup the conda environment for UW Lab
            setup_conda_env ${conda_env_name}
            shift # past argument
            ;;
        -u|--uv)
            # use default name if not provided
            if [ -z "$2" ]; then
                echo "[INFO] Using default uv environment name: env_uwlab"
                uv_env_name="env_uwlab"
            else
                echo "[INFO] Using uv environment name: $2"
                uv_env_name=$2
                shift # past argument
            fi
            # setup the uv environment for UW Lab
            setup_uv_env ${uv_env_name}
            shift # past argument
            ;;
        -f|--format)
            # reset the python path to avoid conflicts with pre-commit
            # this is needed because the pre-commit hooks are installed in a separate virtual environment
            # and it uses the system python to run the hooks
            if [ -n "${CONDA_DEFAULT_ENV}" ] || [ -n "${VIRTUAL_ENV}" ]; then
                cache_pythonpath=${PYTHONPATH}
                export PYTHONPATH=""
            fi
            # run the formatter over the repository
            # check if pre-commit is installed
            if ! command -v pre-commit &>/dev/null; then
                echo "[INFO] Installing pre-commit..."
                pip_command=$(extract_pip_command)
                ${pip_command} pre-commit
                sudo apt-get install -y pre-commit
            fi
            # always execute inside the UW Lab directory
            echo "[INFO] Formatting the repository..."
            cd ${UWLAB_PATH}
            pre-commit run --all-files
            cd - > /dev/null
            # set the python path back to the original value
            if [ -n "${CONDA_DEFAULT_ENV}" ] || [ -n "${VIRTUAL_ENV}" ]; then
                export PYTHONPATH=${cache_pythonpath}
            fi

            shift # past argument
            # exit neatly
            break
            ;;
        -p|--python)
            # ensures Kit loads Isaac Sim’s icon instead of a generic icon on aarch64
            if is_arm; then
                export RESOURCE_NAME="${RESOURCE_NAME:-IsaacSim}"
            fi
            # run the python provided by isaacsim
            python_exe=$(extract_python_exe)
            echo "[INFO] Using python from: ${python_exe}"
            shift # past argument
            ${python_exe} "$@"
            # exit neatly
            break
            ;;
        -s|--sim)
            # run the simulator exe provided by isaacsim
            isaacsim_exe=$(extract_isaacsim_exe)
            echo "[INFO] Running isaac-sim from: ${isaacsim_exe}"
            shift # past argument
            ${isaacsim_exe} --ext-folder ${UWLAB_PATH}/source $@
            # exit neatly
            break
            ;;
        -n|--new)
            # run the template generator script
            python_exe=$(extract_python_exe)
            pip_command=$(extract_pip_command)
            shift # past argument
            echo "[INFO] Installing template dependencies..."
            ${pip_command} -q -r ${UWLAB_PATH}/tools/template/requirements.txt
            echo -e "\n[INFO] Running template generator...\n"
            ${python_exe} ${UWLAB_PATH}/tools/template/cli.py $@
            # exit neatly
            break
            ;;
        -t|--test)
            # run the python provided by isaacsim
            python_exe=$(extract_python_exe)
            shift # past argument
            ${python_exe} -m pytest ${UWLAB_PATH}/tools $@
            # exit neatly
            break
            ;;
        -o|--docker)
            # run the docker container helper script
            docker_script=${UWLAB_PATH}/docker/container.sh
            echo "[INFO] Running docker utility script from: ${docker_script}"
            shift # past argument
            bash ${docker_script} $@
            # exit neatly
            break
            ;;
        -v|--vscode)
            # update the vscode settings
            update_vscode_settings
            shift # past argument
            # exit neatly
            break
            ;;
        -d|--docs)
            # build the documentation
            echo "[INFO] Building documentation..."
            # retrieve the python executable
            python_exe=$(extract_python_exe)
            pip_command=$(extract_pip_command)
            # install pip packages
            cd ${UWLAB_PATH}/docs
            ${pip_command} -r requirements.txt > /dev/null
            # build the documentation
            ${python_exe} -m sphinx -b html -d _build/doctrees . _build/current
            # open the documentation
            echo -e "[INFO] To open documentation on default browser, run:"
            echo -e "\n\t\txdg-open $(pwd)/_build/current/index.html\n"
            # exit neatly
            cd - > /dev/null
            shift # past argument
            # exit neatly
            break
            ;;
        -h|--help)
            print_help
            exit 0
            ;;
        *) # unknown option
            echo "[Error] Invalid argument provided: $1"
            print_help
            exit 1
            ;;
    esac
done
