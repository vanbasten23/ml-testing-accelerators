// Copyright 2020 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

local experimental = import '../experimental.libsonnet';
local common = import 'common.libsonnet';
local gpus = import 'templates/gpus.libsonnet';
local mixins = import 'templates/mixins.libsonnet';
local timeouts = import 'templates/timeouts.libsonnet';
local tpus = import 'templates/tpus.libsonnet';
# local base = import 'templates/base.libsonnet';
# local gpus = import 'templates/gpus.libsonnet';

{
  local resnet50 = self.resnet50, # local defines a variable
  resnet50:: common.PyTorchTest { #Hidden fields, defined with ::, which do not appear in generated JSON
    modelName: 'resnet50-mp',
    trainScript: 'pytorch/xla/test/test_train_mp_imagenet.py',
    batch_size: null,
    command: [
      'python3',
      self.trainScript,
      '--model=resnet50',
      '--log_steps=200',
    ] + (
      if self.flags.modelDir != null then [
        '--logdir=%s' % self.flags.modelDir,
      ] else []
    ) + (
      if self.batch_size != null then [
        '--batch_size=%s' % self.batch_size,
      ] else []
    ),
    flags:: {
      modelDir: '$(MODEL_DIR)',
    },
    volumeMap+: {
      datasets: common.datasetsVolume,
    },

    cpu: '90.0',
    memory: '400Gi',
  },

  local fake_data = self.fake_data,
  fake_data:: common.Functional {
    mode: 'fake',
    command+: [
      '--fake_data',
    ],
  },
  local functional = self.functional,
  functional:: common.Functional {
    command+: [
      '--num_epochs=2',
      '--datadir=/datasets/imagenet-mini',
    ],
  },
  local convergence = self.convergence,
  convergence:: common.Convergence {
    local config = self,

    command+: [
      '--num_epochs=90',
      '--datadir=/datasets/imagenet',
    ],
    metricConfig+: {
      sourceMap+:: {
        tensorboard+: {
          aggregateAssertionsMap+:: {
            'Accuracy/test': {
              FINAL: {
                fixed_value: {
                  comparison: 'GREATER',
                  // Larger global batch size gives lower final accuracy
                  value: if config.accelerator.replicas == 1 then 75 else 74,
                },
                inclusive_bounds: false,
                wait_for_n_data_points: 0,
              },
            },
          },
        },
      },
    },
  },
  // DDP converges worse than MP.
  local convergence_ddp = self.convergence_ddp,
  convergence_ddp:: convergence {
    metricConfig+: {
      sourceMap+:: {
        tensorboard+: {
          aggregateAssertionsMap+:: {
            'Accuracy/test': {
              FINAL: {
                fixed_value: {
                  comparison: 'GREATER',
                  value: 65,
                },
                inclusive_bounds: false,
                wait_for_n_data_points: 0,
              },
            },
          },
        },
      },
    },
  },

  local v2_8 = self.v2_8,
  v2_8:: {
    accelerator: tpus.v2_8,
  },
  local v3_8 = self.v3_8,
  v3_8:: {
    accelerator: tpus.v3_8,
  },
  local v3_32 = self.v3_32,
  v3_32:: {
    accelerator: tpus.v3_32,
  },
  local v4_8 = self.v4_8,
  v4_8:: {
    accelerator: tpus.v4_8,
    // Keep same global batch size as v3
    batch_size: 256,
  },
  local v4_32 = self.v4_32,
  v4_32:: {
    accelerator: tpus.v4_32,
    batch_size: 256,
  },

  local gpu = self.gpu, # xw32: so is it true that `self.gpu` refers to `gpu::` below? A: yes, we can omit `self` and write `gpu` directly.
  gpu:: common.GpuMixin {
    cpu: '7.0',
    memory: '40Gi',

    // Disable XLA metrics report on GPU
    command+: [
      '--nometrics_debug',
    ],
    flags+: {
      modelDir: null,
    },
    tpuSettings+: {
      tpuVmExports+: |||
        export PJRT_DEVICE=GPU
      |||,
    },
  },
  local v100x4 = self.v100x4,
  v100x4:: gpu {
    accelerator: gpus.teslaV100 { count: 4 },
  },

#  local multinodeTraining = base.BaseTest {
#    // Configure job name
#    frameworkPrefix: "pytorch-nightly",
#    modelName: "resnet50",
#    mode: "training",
#    timeout: 3600, # 1 hour, in seconds
#
#    // Set up runtime environment
#    image: 'us-central1-docker.pkg.dev/tpu-pytorch-releases/docker/xla',
#    imageTag: 'nightly_3.10_cuda_12.1',
#    accelerator: gpus.teslaV100,
#    outputBucket: null,
#
#    podTemplate+:: {
#      spec+: { # why sometimes it uses single : but sometimes use double : such as 'initContainerMap+:: {'
#        completionMode: 'Indexed',
#        completions: 4,
#        parallelism: 4,
#        tolerations: [
#          {
#            key: "nvidia.com/gpu",
#            operator: "Exists",
#            effect: "NoSchedule",
#          },
#        ],
#        ports: [
#          {
#            containerPort: 1234,
#          },
#        ],
#        initContainers+:: {
#          kubectl expose kubernetes-bootcamp --type="ClusterIP" --port 1234 --selector="job-name: ptxla-hello-world"
#        },
#      },
#    },
#
#    // Override entrypoint to install PyTorch/XLA official models before running `command`.
#    entrypoint: [
#      'bash',
#      '-c',
#      |||
#        export PATH=/usr/local/nvidia/bin:/usr/local/cuda/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
#        export LD_LIBRARY_PATH=/usr/local/nvidia/lib:/usr/local/nvidia/lib64
#        pip3 install --pre torch torchvision torchaudio --index-url https://download.pytorch.org/whl/nightly/cu121
#        pip install --user \
#          https://storage.googleapis.com/pytorch-xla-releases/wheels/cuda/12.1/torch_xla-2.1.0-cp310-cp310-manylinux_2_28_x86_64.whl
#        git clone --depth=1 https://github.com/pytorch/pytorch.git
#        cd pytorch
#        git clone https://github.com/pytorch/xla.git
#
#        while true
#        do
#          ip=$(getent hosts ptxla-hello-world-0.headless-svc | awk {'print $1'})
#          if [ $? -eq 0 ] && [ \"${ip}\" != \"\" ]
#          then
#            break
#          else
#            sleep 10
#          fi
#        done
#        echo $ip
#
#        # Run whatever is in `command` here
#        ${@:0}
#      |||
#    ],
#    command: [
#      'PJRT_DEVICE=CUDA',
#      'torchrun',
#      '--nnodes=2',
#      '--node_rank=$JOB_COMPLETION_INDEX',
#      '--nproc_per_node=2',
#      '--rdzv_endpoint=$ip:12355',
#      'xla/test/test_train_mp_imagenet.py',
#      '--fake_data',
#      '--pjrt_distributed',
#      '--batch_size=128',
#      '--num_epochs=1',
#    ],
#  },

  local pjrt_ddp = self.pjrt_ddp,
  pjrt_ddp:: {
    modelName+: '-ddp',
    command+: [
      '--ddp',
      '--pjrt_distributed',
    ],
  },

  local tpuVm = {
    tpuSettings+: {
      tpuVmExtraSetup: |||
        pip install tensorboardX google-cloud-storage
      |||,
    },
  },
  local pjrt = self.pjrt,
  pjrt:: common.PyTorchTpuVmMixin + tpuVm {
    modelName: 'resnet50-pjrt',
  },
  local pjrtCuda = self.pjrtCuda,
  pjrtCuda:: common.GpuMixin {
    modelName: 'resnet50-pjrtCuda',
  },

  local spmd(sharding) = self.spmd(sharding),
  spmd(sharding):: pjrt {
    // Include sharding spec in the test name
    modelName: std.join('-', ['resnet50-spmd'] + sharding),
    trainScript: 'pytorch/xla/test/spmd/test_train_spmd_imagenet.py',
    command+: ['--sharding=' + std.join(',', sharding)],
    // Keep the same global batch size. In SPMD, the global batch size is
    // divided across all devices.
    batch_size: self.accelerator.size * 128,
    tpuSettings+: {
      tpuVmExports+: |||
        export XLA_USE_SPMD=1
      |||,
    },
  },

  configs: [
    # no need to change `functional`, 
    resnet50 + functional + v100x4 + timeouts.Hours(1),
    // PJRT
    resnet50 + fake_data + v2_8 + timeouts.Hours(3) + pjrt,
    resnet50 + fake_data + v3_8 + timeouts.Hours(2) + pjrt,
    resnet50 + convergence + v3_8 + timeouts.Hours(24) + pjrt,
    resnet50 + fake_data + v3_8 + timeouts.Hours(2) + pjrt + pjrt_ddp,
    resnet50 + fake_data + v3_32 + timeouts.Hours(1) + pjrt,
    resnet50 + fake_data + v4_8 + timeouts.Hours(2) + pjrt,
    resnet50 + convergence + v4_8 + timeouts.Hours(14) + pjrt,
    resnet50 + fake_data + v4_8 + timeouts.Hours(2) + pjrt + pjrt_ddp,
    resnet50 + convergence_ddp + v4_8 + timeouts.Hours(14) + pjrt + pjrt_ddp,
    resnet50 + fake_data + v4_32 + timeouts.Hours(2) + pjrt,
    resnet50 + convergence + v4_32 + timeouts.Hours(24) + pjrt,
    // SPMD
    resnet50 + functional + v4_8 + timeouts.Hours(2) + spmd(['batch']),
    resnet50 + functional + v4_8 + timeouts.Hours(2) + spmd(['spatial']),
  ],
}
