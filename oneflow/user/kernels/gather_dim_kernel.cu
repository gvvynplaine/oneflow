/*
Copyright 2020 The OneFlow Authors. All rights reserved.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/
#include "oneflow/core/framework/framework.h"
#include "oneflow/user/kernels/gather_dim_util.h"

namespace oneflow {

namespace user_op {

template<DeviceType device_type, typename IN_T, typename IDX_T>
class GatherDimGpuKernel final : public user_op::OpKernel {
 public:
  GatherDimGpuKernel() = default;
  ~GatherDimGpuKernel() override = default;

 private:
  void Compute(KernelComputeContext* ctx) const override {
    const Tensor* input_tensor = ctx->Tensor4ArgNameAndIndex("input", 0);
    const Tensor* index_tensor = ctx->Tensor4ArgNameAndIndex("index", 0);
    Tensor* out_tensor = ctx->Tensor4ArgNameAndIndex("out", 0);
    const int64_t dim = ctx->Attr<int64_t>("dim");

    if (index_tensor->shape().elem_cnt() == 0) { return; }

    const IN_T* input = input_tensor->dptr<IN_T>();
    const IDX_T* index = index_tensor->dptr<IDX_T>();
    IN_T* output = out_tensor->mut_dptr<IN_T>();

    CoordinateOffsetConverter<IDX_T> input_nd_helper(input_tensor->shape());
    CoordinateOffsetConverter<IDX_T> index_nd_helper(index_tensor->shape());
    int64_t elem_cnt = input_tensor->shape().elem_cnt();
    RUN_CUDA_KERNEL((DoCUDAGatherDim<IN_T, IDX_T>), ctx->device_ctx(),
                    BlocksNum4ThreadsNum(elem_cnt),  // TODO: how to choose thread num?
                    input_nd_helper, index_nd_helper, elem_cnt, dim, index, input, output);
  }

  bool AlwaysComputeWhenAllOutputsEmpty() const override { return false; }
};

template<DeviceType device_type, typename IN_T, typename IDX_T>
class ScatterDimAddGpuKernel final : public user_op::OpKernel {
 public:
  ScatterDimAddGpuKernel() = default;
  ~ScatterDimAddGpuKernel() override = default;

 private:
  void Compute(KernelComputeContext* ctx) const override {
    const Tensor* src_tensor = ctx->Tensor4ArgNameAndIndex("src", 0);
    const Tensor* index_tensor = ctx->Tensor4ArgNameAndIndex("index", 0);
    Tensor* out_tensor = ctx->Tensor4ArgNameAndIndex("out", 0);
    const int64_t dim = ctx->Attr<int64_t>("dim");
    const Shape& shape = ctx->Attr<Shape>("shape");

    if (index_tensor->shape().elem_cnt() == 0) { return; }

    const IN_T* src = src_tensor->dptr<IN_T>();
    const IDX_T* index = index_tensor->dptr<IDX_T>();
    IN_T* output = out_tensor->mut_dptr<IN_T>();

    CoordinateOffsetConverter<IDX_T> src_nd_helper(src_tensor->shape());
    CoordinateOffsetConverter<IDX_T> output_nd_helper(out_tensor->shape());
    int64_t elem_cnt = src_tensor->shape().elem_cnt();
    RUN_CUDA_KERNEL((DoCUDAScatterDimAdd<IN_T, IDX_T>), ctx->device_ctx(),
                    BlocksNum4ThreadsNum(elem_cnt),  // TODO: how to choose thread num?
                    src_nd_helper, output_nd_helper, elem_cnt, dim, index, src, output);
  }
  bool AlwaysComputeWhenAllOutputsEmpty() const override { return false; }
};

template<typename IDX_T>
class ScatterDimAddGpuKernel<DeviceType::kGPU, float16, IDX_T> final : public user_op::OpKernel {
 public:
  ScatterDimAddGpuKernel() = default;
  ~ScatterDimAddGpuKernel() override = default;

 private:
  void Compute(KernelComputeContext* ctx) const override {
    const Tensor* src_tensor = ctx->Tensor4ArgNameAndIndex("src", 0);
    const Tensor* index_tensor = ctx->Tensor4ArgNameAndIndex("index", 0);
    Tensor* out_tensor = ctx->Tensor4ArgNameAndIndex("out", 0);
    const int64_t dim = ctx->Attr<int64_t>("dim");
    const Shape& shape = ctx->Attr<Shape>("shape");

    if (index_tensor->shape().elem_cnt() == 0) { return; }

    const float16* src = src_tensor->dptr<float16>();
    const IDX_T* index = index_tensor->dptr<IDX_T>();
    float16* output = out_tensor->mut_dptr<float16>();

    CoordinateOffsetConverter<IDX_T> src_nd_helper(src_tensor->shape());
    CoordinateOffsetConverter<IDX_T> output_nd_helper(out_tensor->shape());
    int64_t elem_cnt = src_tensor->shape().elem_cnt();
    RUN_CUDA_KERNEL((DoCUDAScatterDimAdd<half, IDX_T>), ctx->device_ctx(),
                    BlocksNum4ThreadsNum(elem_cnt), src_nd_helper, output_nd_helper, elem_cnt, dim,
                    index, reinterpret_cast<const half*>(src), reinterpret_cast<half*>(output));
  }
  bool AlwaysComputeWhenAllOutputsEmpty() const override { return false; }
};

#define REGISTER_GATHERDIM_GPUKERNEL(device, in_type, indices_type)                                \
  REGISTER_USER_KERNEL("gather_dim")                                                               \
      .SetCreateFn<                                                                                \
          GatherDimGpuKernel<device, OF_PP_PAIR_FIRST(in_type), OF_PP_PAIR_FIRST(indices_type)>>() \
      .SetIsMatchedHob((user_op::HobDeviceTag() == device)                                         \
                       & (user_op::HobDataType("input", 0) == OF_PP_PAIR_SECOND(in_type))          \
                       & (user_op::HobDataType("index", 0) == OF_PP_PAIR_SECOND(indices_type)));

#define REGISTER_SCATTERDIMADD_GPUKERNEL(device, in_type, indices_type)                 \
  REGISTER_USER_KERNEL("scatter_dim_add")                                               \
      .SetCreateFn<ScatterDimAddGpuKernel<device, OF_PP_PAIR_FIRST(in_type),            \
                                          OF_PP_PAIR_FIRST(indices_type)>>()            \
      .SetIsMatchedHob((user_op::HobDeviceTag() == device)                              \
                       & (user_op::HobDataType("src", 0) == OF_PP_PAIR_SECOND(in_type)) \
                       & (user_op::HobDataType("index", 0) == OF_PP_PAIR_SECOND(indices_type)));

#define GATHER_DATA_TYPE_SEQ ARITHMETIC_DATA_TYPE_SEQ FLOAT16_DATA_TYPE_SEQ

OF_PP_SEQ_PRODUCT_FOR_EACH_TUPLE(REGISTER_GATHERDIM_GPUKERNEL, (DeviceType::kGPU),
                                 GATHER_DATA_TYPE_SEQ, INDEX_DATA_TYPE_SEQ)

OF_PP_SEQ_PRODUCT_FOR_EACH_TUPLE(REGISTER_SCATTERDIMADD_GPUKERNEL, (DeviceType::kGPU),
                                 GATHER_DATA_TYPE_SEQ, INDEX_DATA_TYPE_SEQ)

}  // namespace user_op
}  // namespace oneflow