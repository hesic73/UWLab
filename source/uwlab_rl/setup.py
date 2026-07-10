# Copyright (c) 2024-2026, The UW Lab Project Developers. (https://github.com/uw-lab/UWLab/blob/main/CONTRIBUTORS.md).
# All Rights Reserved.
#
# SPDX-License-Identifier: BSD-3-Clause

"""Installation script for the 'uwlab_rl' python package."""

import itertools
import os
import toml

from setuptools import setup

# Obtain the extension data from the extension.toml file
EXTENSION_PATH = os.path.dirname(os.path.realpath(__file__))
# Read the extension.toml file
EXTENSION_TOML_DATA = toml.load(os.path.join(EXTENSION_PATH, "config", "extension.toml"))

# Minimum dependencies required prior to installation
INSTALL_REQUIRES = [
    # generic
    # Keep click compatible with Isaac Sim 6.0.0.1 while allowing protobuf 6,
    # which is required by Isaac Lab 3.0's TensorBoard version.
    "wandb==0.20.1",
    "click==8.1.7",
    "protobuf>=6.31.1,<7",
]

PYTORCH_INDEX_URL = ["https://download.pytorch.org/whl/cu128"]

# Extra dependencies for RL agents
EXTRAS_REQUIRE = {
    "rsl-rl": [
        # RSL-RL 5.4.1 plus the UW OmniReset gSDE distribution, maintained on
        # the project owner's long-lived integration branch.
        "rsl-rl-lib @ git+https://github.com/hesic73/rsl_rl.git@omnireset",
    ],
}

# Cumulation of all extra-requires
EXTRAS_REQUIRE["all"] = list(itertools.chain.from_iterable(EXTRAS_REQUIRE.values()))
# Remove duplicates in the all list to avoid double installations
EXTRAS_REQUIRE["all"] = list(set(EXTRAS_REQUIRE["all"]))

# Installation operation
setup(
    name="uwlab_rl",
    author="UW Lab Project Developers",
    maintainer="UW Lab Project Developers",
    url=EXTENSION_TOML_DATA["package"]["repository"],
    version=EXTENSION_TOML_DATA["package"]["version"],
    description=EXTENSION_TOML_DATA["package"]["description"],
    keywords=EXTENSION_TOML_DATA["package"]["keywords"],
    license="BSD-3-Clause",
    include_package_data=True,
    python_requires=">=3.12,<3.13",
    install_requires=INSTALL_REQUIRES,
    dependency_links=PYTORCH_INDEX_URL,
    extras_require=EXTRAS_REQUIRE,
    packages=["uwlab_rl"],
    classifiers=[
        "Natural Language :: English",
        "Programming Language :: Python :: 3.12",
        "Isaac Sim :: 6.0.0",
    ],
    zip_safe=False,
)
