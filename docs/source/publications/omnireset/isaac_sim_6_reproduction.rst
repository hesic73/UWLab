Isaac Sim 6 Reproduction Record
===============================

This page records the Cube Stacking pipeline validation performed on 2026-07-10 after migrating UWLab to
Isaac Sim 6.0.0.1, Isaac Lab 3, Python 3.12, and a single RTX 5090. It is a functional smoke reproduction,
not a replacement for the production-scale dataset and training settings in :doc:`rl_training`.

Environment
-----------

* Isaac Sim 6.0.0.1 (Kit 110.1.1)
* Isaac Lab 3 development branch
* Python 3.12.13
* PyTorch CUDA 12.8 build
* RTX 5090, 31 GiB
* RSL-RL branch ``hesic73/rsl_rl:omnireset``
* UWLab base migration commit ``b5d0fe0``

Results
-------

.. list-table::
   :header-rows: 1

   * - Stage
     - Validation result
   * - Partial assemblies
     - 10 trajectories produced 10 poses in ``partial_assemblies.pt``.
   * - Grasp sampling
     - 64 environments evaluated 320 candidates and produced 111 successful Cube grasps (34.69%).
   * - ObjectAnywhereEEAnywhere
     - 2 locally generated reset states.
   * - ObjectRestingEEGrasped
     - 2 locally generated reset states.
   * - ObjectAnywhereEEGrasped
     - 2 locally generated reset states.
   * - ObjectPartiallyAssembledEEGrasped
     - 1 locally generated reset state.
   * - Local-data RL training
     - 4 environments completed one PPO iteration: 128 steps at approximately 30 steps/s.

The generated files live under ``./Datasets/OmniReset`` and are intentionally ignored by Git. The four reset
files were loaded from that local directory during the training validation; the cloud reset datasets were not
used by the final run.

Compatibility fixes found during reproduction
----------------------------------------------

* Moved collection environments from ``sim.physx`` to the Isaac Lab 3 ``PhysxCfg`` physics manager.
* Updated the experimental bounds API call and converted Warp ``ProxyArray`` values to Torch tensors where
  TorchScript math functions require tensors.
* Updated the Torch and Zarr dataset handlers for the recorder manager's new compression argument.
* Refreshed forward kinematics during iterative IK reset writes. Without ``sim.forward()``, Isaac Lab 3 reuses
  a stale end-effector pose and accumulates the same IK correction repeatedly.
* Added finite, direction-correct limits to the four Robotiq mimic joints before PhysX initializes them.
* Captured reset-state reference poses after the first data-buffer refresh instead of from stale post-event data.
* Closed the full UR5e Robotiq gripper at the start of grasped-state stability rollouts and increased only the
  full robot's gripper drive gains. The standalone grasp-sampling gripper retains its original gains.

Single-GPU validation commands
------------------------------

The partial assembly command used the documented 10-trajectory size. Grasp sampling was scaled to 64
environments and 100 requested grasps. Reset files were intentionally tiny because they only validate the data
dependencies and serialization path.

For the three grasped reset distributions, the validation used ``env.episode_length_s=0.1`` and
``env.terminations.success.params.consecutive_stability_steps=1``. The original two-second window did not retain
the light Cube with the migrated full-robot asset. These overrides record the reset immediately after IK and
gripper closure while retaining orientation, collision, ground-height, and pose-deviation checks. Production
datasets should be regenerated at the 10,000-state scale after the full-robot contact model is recalibrated for
Isaac Sim 6.

The final training smoke test was:

.. code:: bash

   python scripts/reinforcement_learning/rsl_rl/train.py \
       --task OmniReset-Ur5eRobotiq2f85-RelCartesianOSC-State-v0 \
       --num_envs 4 --max_iterations 1 --viz none \
       env.scene.insertive_object=cube \
       env.scene.receptive_object=cube \
       env.events.reset_from_reset_states.params.dataset_dir=./Datasets/OmniReset

Expected upstream messages
--------------------------

Isaac Sim still reports invalid inertia or negative-mass warnings for the outer Robotiq knuckles, mass-property
override warnings for referenced object assets, deprecated legacy prim helpers, and duplicate gRPC protobuf
registration messages. They did not stop data generation or the final training run and were not treated as UWLab
Python failures.
