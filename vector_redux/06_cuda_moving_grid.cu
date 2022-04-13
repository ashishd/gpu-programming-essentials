#include <stdio.h>
#include <stdlib.h>
#include <time.h>

#define CUDA_CHECK_ERROR(X)({\
    if((X) != cudaSuccess){\
        fprintf(stderr, "ERROR %d (%s:%d): %s\n", (X), __FILE__, __LINE__, cudaGetErrorString((X)));\
        exit(1);\
    }\
})

#define NTHREADS 1024 
#define ALL_THREADS_MASK 0xffffffff
#define WARPSIZE 32


__global__ void vector_reduction_kernel(unsigned char *values, unsigned int nitems, unsigned long long* result){
    unsigned int idx = blockIdx.x * blockDim.x + threadIdx.x;
    __shared__ unsigned int partial_sums[WARPSIZE];
    unsigned int warpId = threadIdx.x / warpSize;
    unsigned int laneId = threadIdx.x % warpSize; 
    unsigned int gridSize = gridDim.x * blockDim.x;
    unsigned int nloops = (nitems + gridSize  - 1) / gridSize;
    unsigned int l = 0;
    unsigned int myvalue;

    while(l++ < nloops){
        if(idx < nitems){ 
            myvalue = values[idx]; 
        }else{
            myvalue = 0;
        }
 
        // step 1
        for(unsigned int i = warpSize/2; i >= 1; i >>= 1){
            unsigned int up = __shfl_down_sync(ALL_THREADS_MASK, myvalue, i, warpSize); 
            if(laneId < i){
                myvalue += up; 
            }
        }
        if(laneId == 0 && warpId > 0) partial_sums[warpId] = myvalue;
       
        __syncthreads();
        // step 2
        if(warpId == 0){
            if(laneId > 0) myvalue = partial_sums[laneId];
            for(unsigned int i = warpSize/2; i >= 1; i >>= 1){
                unsigned int up = __shfl_down_sync(ALL_THREADS_MASK, myvalue, i, warpSize); 
                    if(laneId < i){
                        myvalue += up; 
                    }
                }
            if(laneId == 0) atomicAdd(result, myvalue);
        }  
        idx += gridSize;
        __syncthreads();
    }
}



int main(int argc, char **argv){
    
    unsigned int nitems = 1e9; 
    unsigned char *values = (unsigned char*) malloc(sizeof(unsigned int) * nitems);
    if(!values){
        fprintf(stderr, "Error while allocating memory\n");
        return -1;
    }
    // Initialise the vector of n elements to random values
    unsigned long long correct_result = 0;
    for(int i = 0; i < nitems; i++){
        values[i] = (i + 1) % 128;
        correct_result += values[i];
    }
    unsigned long long sum = 0ull;
    unsigned long long *dev_sum;
    unsigned char *dev_values;
    CUDA_CHECK_ERROR(cudaMalloc(&dev_values, sizeof(unsigned char) * nitems));
    CUDA_CHECK_ERROR(cudaMalloc(&dev_sum, sizeof(unsigned long long)));
    CUDA_CHECK_ERROR(cudaMemset(dev_sum, 0, sizeof(unsigned long long)));
    CUDA_CHECK_ERROR(cudaMemcpy(dev_values, values, sizeof(unsigned char) * nitems, cudaMemcpyHostToDevice));
    struct cudaDeviceProp props;
    CUDA_CHECK_ERROR(cudaGetDeviceProperties(&props, 0));
    unsigned int nblocks = props.multiProcessorCount * 2;
    printf("Number of cuda blocks: %u\n", nblocks);
    cudaEvent_t start, stop;
    CUDA_CHECK_ERROR(cudaEventCreate(&start));
    CUDA_CHECK_ERROR(cudaEventCreate(&stop));
    CUDA_CHECK_ERROR(cudaEventRecord(start)); 
    vector_reduction_kernel<<<nblocks, NTHREADS>>>(dev_values, nitems, dev_sum);
    CUDA_CHECK_ERROR(cudaGetLastError());
    CUDA_CHECK_ERROR(cudaEventRecord(stop)); 
    CUDA_CHECK_ERROR(cudaDeviceSynchronize());
    CUDA_CHECK_ERROR(cudaMemcpy(&sum, dev_sum, sizeof(unsigned long long), cudaMemcpyDeviceToHost));
    CUDA_CHECK_ERROR(cudaDeviceSynchronize());
    float time_spent;
    CUDA_CHECK_ERROR(cudaEventElapsedTime(&time_spent, start, stop));
    printf("Result: %llu - Time elapsed: %f\n", sum, time_spent/1000.0f);
    if(correct_result != sum) {
        fprintf(stderr, "Error: sum is not correct, should be %llu\n", correct_result);
        return EXIT_FAILURE;
    }
    return EXIT_SUCCESS;

}