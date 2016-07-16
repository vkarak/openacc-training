#include <iostream>
#include <fstream>
#include <cstdio>

#include <cuda.h>

#include "util.h"
#include "CudaStream.h"
#include "CudaEvent.h"

// 2D diffusion example
// the grid has a fixed width of nx=128
// the use specifies the height, ny, as a power of two
// note that nx and ny have 2 added to them to account for halos

template <typename T>
void fill_gpu(T *v, T value, int n);

void write_to_file(int nx, int ny, double* data);

__global__
void diffusion(double *x0, double *x1, int nx, int ny, double dt) {
    auto i = threadIdx.x + blockIdx.x*blockDim.x;
    auto j = threadIdx.y + blockIdx.y*blockDim.y;

    if(i<nx && j<ny) {
        auto width = nx+2;
        auto pos = (i+1) + (j+1)*width;

        x1[pos] = x0[pos] + dt * (-4.*x0[pos]
                + x0[pos-width] + x0[pos+width]
                + x0[pos-1]  + x0[pos+1]);

    }
}

__global__
void diffusion_shared(double *x0, double *x1, int nx, int ny, double dt) {
    extern __shared__ double buffer[];

    auto i = threadIdx.x + blockIdx.x*blockDim.x;
    auto j = threadIdx.y + blockIdx.y*blockDim.y;

    if(i<nx && j<ny) {
        auto width = nx+2;
        auto shared_width = blockDim.x+2;

        auto pos = (i+1) + (j+1)*width;
        auto shared_pos = (threadIdx.x+1) + (threadIdx.y+1)*shared_width;

        buffer[shared_pos] = x0[pos];
        if(threadIdx.x==0) {
            buffer[shared_pos-1] = x0[pos-1];
        }
        if(threadIdx.x==blockDim.x-1) {
            buffer[shared_pos+1] = x0[pos+1];
        }
        if(threadIdx.y==0) {
            buffer[shared_pos-shared_width] = x0[pos-width];
        }
        if(threadIdx.y==blockDim.y-1) {
            buffer[shared_pos+shared_width] = x0[pos+width];
        }

        __syncthreads();

        x1[pos] = buffer[shared_pos] + dt * (-4.*buffer[shared_pos]
                + buffer[shared_pos-shared_width] + buffer[shared_pos+shared_width]
                + buffer[shared_pos-1]  + buffer[shared_pos+1]);
    }
}

int main(int argc, char** argv) {
    // set up parameters
    // first argument is the y dimension = 2^arg
    size_t pow    = read_arg(argc, argv, 1, 8);
    // second argument is the number of time steps
    size_t nsteps = read_arg(argc, argv, 2, 100);
    // third argument is nonzero if shared memory version is to be used
    bool use_shared = read_arg(argc, argv, 3, 0);

    // set domain size
    size_t nx = 128+2;
    size_t ny = (1 << pow)+2;
    double dt = 0.1;

    std::cout << "\n## " << nx << "x" << ny
              << " for " << nsteps << " time steps"
              << " (" << nx*ny << " grid points)"
              << std::endl;

    // allocate memory on device and host
    // note : allocate enough memory for the halo around the boundary
    auto buffer_size = nx*ny;
    double *x_host = malloc_host_pinned<double>(buffer_size);
    double *x0     = malloc_device<double>(buffer_size);
    double *x1     = malloc_device<double>(buffer_size);

    // set initial conditions of 0 everywhere
    fill_gpu(x0, 0., buffer_size);
    fill_gpu(x1, 0., buffer_size);

    // set boundary conditions of 1 on south border
    fill_gpu(x0, 1., nx);
    fill_gpu(x1, 1., nx);
    fill_gpu(x0+nx*(ny-1), 1., nx);
    fill_gpu(x1+nx*(ny-1), 1., nx);

    CudaStream stream;
    CudaStream copy_stream(true);
    auto start_event = stream.enqueue_event();

    dim3 block_dim(16, 16);
    dim3 grid_dim(
        (nx-2+block_dim.x-1)/block_dim.x,
        (ny-2+block_dim.y-1)/block_dim.y
    );

    // time stepping loop
    for(auto step=0; step<nsteps; ++step) {
        if(use_shared) {
            auto shared_size = (block_dim.x+2)*(block_dim.y+2)*sizeof(double);
            diffusion_shared<<<grid_dim, block_dim, shared_size>>>
                (x0, x1, nx-2, ny-2, dt);
        }
        else {
            diffusion<<<grid_dim, block_dim>>>
                (x0, x1, nx-2, ny-2, dt);
        }

        std::swap(x0, x1);
    }
    auto stop_event = stream.enqueue_event();
    stop_event.wait();

    copy_to_host<double>(x0, x_host, buffer_size);

    double time = stop_event.time_since(start_event);

    std::cout << "## " << time << "s, "
              << nsteps*(nx-2)*(ny-2) / time << " points/second"
              << std::endl << std::endl;

    std::cout << "writing to output.bin/bov" << std::endl;
    write_to_file(nx, ny, x_host);

    return 0;
}

template <typename T>
__global__
void fill(T *v, T value, int n) {
    int tid  = threadIdx.x + blockDim.x*blockIdx.x;

    if(tid<n) {
        v[tid] = value;
    }
}

template <typename T>
void fill_gpu(T *v, T value, int n) {
    auto block_dim = 192ul;
    auto grid_dim = n/block_dim + (n%block_dim ? 1 : 0);

    fill<T><<<grid_dim, block_dim>>>(v, value, n);
}

void write_to_file(int nx, int ny, double* data) {
    {
        FILE* output = fopen("output.bin", "w");
        fwrite(data, sizeof(double), nx * ny, output);
        fclose(output);
    }

    std::ofstream fid("output.bov");
    fid << "TIME: 0.0" << std::endl;
    fid << "DATA_FILE: output.bin" << std::endl;
    fid << "DATA_SIZE: " << nx << ", " << ny << ", 1" << std::endl;;
    fid << "DATA_FORMAT: DOUBLE" << std::endl;
    fid << "VARIABLE: phi" << std::endl;
    fid << "DATA_ENDIAN: LITTLE" << std::endl;
    fid << "CENTERING: nodal" << std::endl;
    fid << "BRICK_SIZE: 1.0 1.0 1.0" << std::endl;
}
