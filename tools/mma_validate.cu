// Correctness of the unlocked path: HMMA m16n8k8 FP16 x FP16 -> FP32 accumulate,
// chained over K, checked against a CPU double reference on random inputs.
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cuda_fp16.h>
#include <vector>

constexpr int M = 16, N = 8, KS = 8, KT = 4096, TILES = 256;  // per tile: 16x8 output, K=4096

#define CK(x) do { cudaError_t e = (x); if (e != cudaSuccess) { \
    printf("%s: %s\n", #x, cudaGetErrorString(e)); return 1; } } while (0)

__global__ void gemm_tiles(const __half *A, const __half *B, float *C) {
    // A: TILES x M x KT (row-major), B: TILES x N x KT (B^T row-major = col-major KxN)
    int t = blockIdx.x, lane = threadIdx.x, g = lane >> 2, q = lane & 3;
    const __half *a = A + (size_t)t * M * KT, *b = B + (size_t)t * N * KT;
    float c[4] = {};
    for (int k = 0; k < KT; k += KS) {
        __half2 a0 = __halves2half2(a[g * KT + k + q * 2], a[g * KT + k + q * 2 + 1]);
        __half2 a1 = __halves2half2(a[(g + 8) * KT + k + q * 2], a[(g + 8) * KT + k + q * 2 + 1]);
        __half2 b0 = __halves2half2(b[g * KT + k + q * 2], b[g * KT + k + q * 2 + 1]);
        asm volatile("mma.sync.aligned.m16n8k8.row.col.f32.f16.f16.f32 "
                     "{%0,%1,%2,%3}, {%4,%5}, {%6}, {%0,%1,%2,%3};"
                     : "+f"(c[0]), "+f"(c[1]), "+f"(c[2]), "+f"(c[3])
                     : "r"(*(unsigned *)&a0), "r"(*(unsigned *)&a1), "r"(*(unsigned *)&b0));
    }
    float *o = C + (size_t)t * M * N;
    o[g * N + q * 2] = c[0];       o[g * N + q * 2 + 1] = c[1];
    o[(g + 8) * N + q * 2] = c[2]; o[(g + 8) * N + q * 2 + 1] = c[3];
}

int main() {
    size_t na = (size_t)TILES * M * KT, nb = (size_t)TILES * N * KT, nc = (size_t)TILES * M * N;
    std::vector<__half> A(na), B(nb);
    std::vector<float> fa(na), fb(nb), C(nc);
    srand(12345);
    for (size_t i = 0; i < na; i++) fa[i] = __half2float(A[i] = __float2half((rand() / (float)RAND_MAX) * 2 - 1));
    for (size_t i = 0; i < nb; i++) fb[i] = __half2float(B[i] = __float2half((rand() / (float)RAND_MAX) * 2 - 1));
    __half *dA, *dB; float *dC;
    CK(cudaMalloc(&dA, na * 2)); CK(cudaMalloc(&dB, nb * 2)); CK(cudaMalloc(&dC, nc * 4));
    CK(cudaMemcpy(dA, A.data(), na * 2, cudaMemcpyHostToDevice));
    CK(cudaMemcpy(dB, B.data(), nb * 2, cudaMemcpyHostToDevice));
    gemm_tiles<<<TILES, 32>>>(dA, dB, dC);
    CK(cudaGetLastError());
    CK(cudaMemcpy(C.data(), dC, nc * 4, cudaMemcpyDeviceToHost));
    double worst = 0; size_t bad = 0;
    for (int t = 0; t < TILES; t++)
        for (int i = 0; i < M; i++)
            for (int j = 0; j < N; j++) {
                double ref = 0, mag = 0;
                for (int k = 0; k < KT; k++) {
                    double p = (double)fa[(size_t)t * M * KT + i * KT + k] * fb[(size_t)t * N * KT + j * KT + k];
                    ref += p; mag += fabs(p);
                }
                double err = fabs(C[(size_t)t * M * N + i * N + j] - ref) / mag;  // relative to sum |products|
                if (err > worst) worst = err;
                if (err > 1e-5) bad++;  // fp32 accumulate over K=4096: expect ~1e-7
            }
    printf("outputs=%zu K=%d worst_rel_err=%.3e (vs sum|a*b|) over_1e-5=%zu -> %s\n",
           nc, KT, worst, bad, bad ? "FAIL" : "PASS");
    return bad != 0;
}
