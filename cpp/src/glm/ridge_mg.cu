/*
 * Copyright (c) 2020, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include <common/cumlHandle.hpp>
#include <common/cuml_comms_int.hpp>
#include <common/device_buffer.hpp>
#include <cuda_utils.cuh>
#include <cuml/common/cuml_allocator.hpp>
#include <cuml/linear_model/ridge_mg.hpp>
#include <linalg/add.cuh>
#include <linalg/gemm.cuh>
#include <matrix/math.cuh>
#include <matrix/matrix.cuh>
#include <opg/linalg/mv_aTb.hpp>
#include <opg/linalg/svd.hpp>
#include <opg/preprocess.hpp>
#include <opg/stats/mean.hpp>

using namespace MLCommon;

namespace ML {
namespace Ridge {
namespace opg {

template <typename T>
void ridgeSolve(const cumlHandle &handle, T *S, T *V,
                std::vector<Matrix::Data<T> *> &U,
                const Matrix::PartDescriptor &UDesc,
                const std::vector<Matrix::Data<T> *> &b, const T *alpha,
                const int n_alpha, T *w, cudaStream_t *streams, int n_streams,
                bool verbose) {
  auto cublasH = handle.getImpl().getCublasHandle();
  auto cusolverH = handle.getImpl().getcusolverDnHandle();
  const MLCommon::cumlCommunicator &comm = handle.getImpl().getCommunicator();
  const std::shared_ptr<deviceAllocator> allocator =
    handle.getImpl().getDeviceAllocator();

  // Implements this: w = V * inv(S^2 + λ*I) * S * U^T * b
  T *S_nnz;
  T alp = T(1);
  T beta = T(0);
  T thres = T(1e-10);

  Matrix::setSmallValuesZero(S, UDesc.N, streams[0], thres);

  // TO-DO: Update to use `device_buffer` here
  // Tracking issue: https://github.com/rapidsai/cuml/issues/2524
  allocate(S_nnz, UDesc.N, true);
  copy(S_nnz, S, UDesc.N, streams[0]);
  Matrix::power(S_nnz, UDesc.N, streams[0]);
  LinAlg::addScalar(S_nnz, S_nnz, alpha[0], UDesc.N, streams[0]);
  Matrix::matrixVectorBinaryDivSkipZero(S, S_nnz, size_t(1), UDesc.N, false,
                                        true, streams[0], true);

  Matrix::matrixVectorBinaryMult(V, S, UDesc.N, UDesc.N, false, true,
                                 streams[0]);

  Matrix::Data<T> S_nnz_data;
  S_nnz_data.totalSize = UDesc.N;
  S_nnz_data.ptr = S_nnz;
  LinAlg::opg::mv_aTb(S_nnz_data, U, UDesc, b, comm, allocator, streams,
                      n_streams, cublasH);

  LinAlg::gemm(V, UDesc.N, UDesc.N, S_nnz, w, UDesc.N, 1, CUBLAS_OP_N,
               CUBLAS_OP_N, alp, beta, cublasH, streams[0]);

  CUDA_CHECK(cudaFree(S_nnz));
}

template <typename T>
void ridgeEig(cumlHandle &handle, const std::vector<Matrix::Data<T> *> &A,
              const Matrix::PartDescriptor &ADesc,
              const std::vector<Matrix::Data<T> *> &b, const T *alpha,
              const int n_alpha, T *coef, cudaStream_t *streams, int n_streams,
              bool verbose) {
  const MLCommon::cumlCommunicator &comm = handle.getImpl().getCommunicator();
  const cublasHandle_t cublas_handle = handle.getImpl().getCublasHandle();
  const cusolverDnHandle_t cusolver_handle =
    handle.getImpl().getcusolverDnHandle();
  const std::shared_ptr<deviceAllocator> allocator =
    handle.getImpl().getDeviceAllocator();

  int rank = comm.getRank();

  device_buffer<T> S(allocator, streams[0], ADesc.N);
  device_buffer<T> V(allocator, streams[0], ADesc.N * ADesc.N);
  std::vector<Matrix::Data<T> *> U;
  std::vector<Matrix::Data<T>> U_temp;

  std::vector<Matrix::RankSizePair *> partsToRanks = ADesc.blocksOwnedBy(rank);
  size_t total_size = 0;

  for (int i = 0; i < partsToRanks.size(); i++) {
    total_size += partsToRanks[i]->size;
  }
  total_size = total_size * ADesc.N;

  device_buffer<T> U_parts(allocator, streams[0], total_size);
  T *curr_ptr = U_parts.data();

  for (int i = 0; i < partsToRanks.size(); i++) {
    Matrix::Data<T> d;
    d.totalSize = partsToRanks[i]->size;
    d.ptr = curr_ptr;
    curr_ptr = curr_ptr + (partsToRanks[i]->size * ADesc.N);
    U_temp.push_back(d);
  }

  for (int i = 0; i < A.size(); i++) {
    U.push_back(&(U_temp[i]));
  }

  LinAlg::opg::svdEig(A, ADesc, U, S.data(), V.data(), comm, allocator, streams,
                      n_streams, cublas_handle, cusolver_handle);

  ridgeSolve(handle, S.data(), V.data(), U, ADesc, b, alpha, n_alpha, coef,
             streams, n_streams, verbose);
}

template <typename T>
void fit_impl(cumlHandle &handle, std::vector<Matrix::Data<T> *> &input_data,
              Matrix::PartDescriptor &input_desc,
              std::vector<Matrix::Data<T> *> &labels, T *alpha, int n_alpha,
              T *coef, T *intercept, bool fit_intercept, bool normalize,
              int algo, cudaStream_t *streams, int n_streams, bool verbose) {
  const std::shared_ptr<deviceAllocator> allocator =
    handle.getImpl().getDeviceAllocator();

  device_buffer<T> mu_input(allocator, streams[0]);
  device_buffer<T> norm2_input(allocator, streams[0]);
  device_buffer<T> mu_labels(allocator, streams[0]);

  if (fit_intercept) {
    mu_input.resize(input_desc.N, streams[0]);
    mu_labels.resize(1, streams[0]);
    if (normalize) {
      norm2_input.resize(input_desc.N, streams[0]);
    }

    GLM::opg::preProcessData(handle, input_data, input_desc, labels,
                             mu_input.data(), mu_labels.data(),
                             norm2_input.data(), fit_intercept, normalize,
                             streams, n_streams, verbose);
  }

  if (algo == 0 || input_desc.N == 1) {
    ASSERT(false, "olsFit: no algorithm with this id has been implemented");
  } else if (algo == 1) {
    ridgeEig(handle, input_data, input_desc, labels, alpha, n_alpha, coef,
             streams, n_streams, verbose);
  } else {
    ASSERT(false, "olsFit: no algorithm with this id has been implemented");
  }

  if (fit_intercept) {
    GLM::opg::postProcessData(handle, input_data, input_desc, labels, coef,
                              intercept, mu_input.data(), mu_labels.data(),
                              norm2_input.data(), fit_intercept, normalize,
                              streams, n_streams, verbose);
  } else {
    *intercept = T(0);
  }
}

/**
 * @brief performs MNMG fit operation for the ridge regression
 * @input param handle: the internal cuml handle object
 * @input param rank_sizes: includes all the partition size information for the rank
 * @input param n_parts: number of partitions
 * @input param input: input data
 * @input param n_rows: number of rows of the input data
 * @input param n_cols: number of cols of the input data
 * @input param labels: labels data
 * @input param alpha: ridge parameter
 * @input param n_alpha: number of ridge parameters. Only one parameter is supported right now.
 * @output param coef: learned regression coefficients
 * @output param intercept: intercept value
 * @input param fit_intercept: fit intercept or not
 * @input param normalize: normalize the data or not
 * @input param verbose
 */
template <typename T>
void fit_impl(cumlHandle &handle, std::vector<Matrix::Data<T> *> &input_data,
              Matrix::PartDescriptor &input_desc,
              std::vector<Matrix::Data<T> *> &labels, T *alpha, int n_alpha,
              T *coef, T *intercept, bool fit_intercept, bool normalize,
              int algo, bool verbose) {
  int rank = handle.getImpl().getCommunicator().getRank();

  // TODO: These streams should come from cumlHandle
  // Tracking issue: https://github.com/rapidsai/cuml/issues/2470

  int n_streams = input_desc.blocksOwnedBy(rank).size();
  cudaStream_t streams[n_streams];
  for (int i = 0; i < n_streams; i++) {
    CUDA_CHECK(cudaStreamCreate(&streams[i]));
  }

  fit_impl(handle, input_data, input_desc, labels, alpha, n_alpha, coef,
           intercept, fit_intercept, normalize, algo, streams, n_streams,
           verbose);

  for (int i = 0; i < n_streams; i++) {
    CUDA_CHECK(cudaStreamSynchronize(streams[i]));
  }

  for (int i = 0; i < n_streams; i++) {
    CUDA_CHECK(cudaStreamDestroy(streams[i]));
  }
}

template <typename T>
void predict_impl(cumlHandle &handle,
                  std::vector<Matrix::Data<T> *> &input_data,
                  Matrix::PartDescriptor &input_desc, T *coef, T intercept,
                  std::vector<Matrix::Data<T> *> &preds, cudaStream_t *streams,
                  int n_streams, bool verbose) {
  std::vector<Matrix::RankSizePair *> local_blocks = input_desc.partsToRanks;
  T alpha = T(1);
  T beta = T(0);

  for (int i = 0; i < input_data.size(); i++) {
    int si = i % n_streams;
    LinAlg::gemm(input_data[i]->ptr, local_blocks[i]->size, input_desc.N, coef,
                 preds[i]->ptr, local_blocks[i]->size, size_t(1), CUBLAS_OP_N,
                 CUBLAS_OP_N, alpha, beta, handle.getImpl().getCublasHandle(),
                 streams[si]);

    LinAlg::addScalar(preds[i]->ptr, preds[i]->ptr, intercept,
                      local_blocks[i]->size, streams[si]);
  }
}

template <typename T>
void predict_impl(cumlHandle &handle, Matrix::RankSizePair **rank_sizes,
                  size_t n_parts, Matrix::Data<T> **input, size_t n_rows,
                  size_t n_cols, T *coef, T intercept, Matrix::Data<T> **preds,
                  bool verbose) {
  int rank = handle.getImpl().getCommunicator().getRank();

  std::vector<Matrix::RankSizePair *> ranksAndSizes(rank_sizes,
                                                    rank_sizes + n_parts);
  std::vector<Matrix::Data<T> *> input_data(input, input + n_parts);
  Matrix::PartDescriptor input_desc(n_rows, n_cols, ranksAndSizes, rank);
  std::vector<Matrix::Data<T> *> preds_data(preds, preds + n_parts);

  // TODO: These streams should come from cumlHandle
  int n_streams = n_parts;
  cudaStream_t streams[n_streams];
  for (int i = 0; i < n_streams; i++) {
    CUDA_CHECK(cudaStreamCreate(&streams[i]));
  }

  predict_impl(handle, input_data, input_desc, coef, intercept, preds_data,
               streams, n_streams, verbose);

  for (int i = 0; i < n_streams; i++) {
    CUDA_CHECK(cudaStreamSynchronize(streams[i]));
  }

  for (int i = 0; i < n_streams; i++) {
    CUDA_CHECK(cudaStreamDestroy(streams[i]));
  }
}

void fit(cumlHandle &handle, std::vector<Matrix::Data<float> *> &input_data,
         Matrix::PartDescriptor &input_desc,
         std::vector<Matrix::Data<float> *> &labels, float *alpha, int n_alpha,
         float *coef, float *intercept, bool fit_intercept, bool normalize,
         int algo, bool verbose) {
  fit_impl(handle, input_data, input_desc, labels, alpha, n_alpha, coef,
           intercept, fit_intercept, normalize, algo, verbose);
}

void fit(cumlHandle &handle, std::vector<Matrix::Data<double> *> &input_data,
         Matrix::PartDescriptor &input_desc,
         std::vector<Matrix::Data<double> *> &labels, double *alpha,
         int n_alpha, double *coef, double *intercept, bool fit_intercept,
         bool normalize, int algo, bool verbose) {
  fit_impl(handle, input_data, input_desc, labels, alpha, n_alpha, coef,
           intercept, fit_intercept, normalize, algo, verbose);
}

void predict(cumlHandle &handle, Matrix::RankSizePair **rank_sizes,
             size_t n_parts, Matrix::Data<float> **input, size_t n_rows,
             size_t n_cols, float *coef, float intercept,
             Matrix::Data<float> **preds, bool verbose) {
  predict_impl(handle, rank_sizes, n_parts, input, n_rows, n_cols, coef,
               intercept, preds, verbose);
}

void predict(cumlHandle &handle, Matrix::RankSizePair **rank_sizes,
             size_t n_parts, Matrix::Data<double> **input, size_t n_rows,
             size_t n_cols, double *coef, double intercept,
             Matrix::Data<double> **preds, bool verbose) {
  predict_impl(handle, rank_sizes, n_parts, input, n_rows, n_cols, coef,
               intercept, preds, verbose);
}

}  // namespace opg
}  // namespace Ridge
}  // namespace ML
