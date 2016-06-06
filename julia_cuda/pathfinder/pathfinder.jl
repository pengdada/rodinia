#!/usr/bin/env julia

using CUDAnative

# Configuration
const BLOCK_SIZE = 256
const HALO = 1

const M_SEED = 7
const OUTPUT = false

# Helper function

@target ptx function inrange(x, min, max)
    return x >= min && x <= max
end

function min(a, b)
    return a <= b ? a : b
end

@target ptx function dev_min(a, b)
    return a <= b ? a : b
end

# Override rng functions with libc implementations
function srand(seed)
    ccall( (:srand, "libc"), Void, (Int,), seed)
end

function rand()
    r = ccall( (:rand, "libc"), Int, ())
    return r
end

# Device code

@target ptx function kernel_dynproc(
    iteration,
    gpu_wall, gpu_src, gpu_results, 
    cols, rows, start_step, border)
    
    # Define shared memory
    #=
    #cuSharedMem(Int64) returns the same pointer twice, we want separate values, 
    prev = cuSharedMem(Int64)
    result = cuSharedMem(Int64)
    =#

    #For now use 1 shared mem block together with offsets
    shared_mem = cuSharedMem(Int64)  # size: 2*256*8 bytes (Int64 -> 8 bytes), indicated when calling using @cuda macro
    # prev = shared_mem[0:256]
    # result = shared_mem[265:512]
    prev_offset = 0
    result_offset = 256

    bx = blockIdx().x
    tx = threadIdx().x

    # Will this be a problem: references to global vars
    # but will likely be replaced by a constant when jitting, or not?
    small_block_cols = BLOCK_SIZE - iteration * HALO * 2

    blk_x = small_block_cols * (bx-1) - border;
    blk_x_max = blk_x + BLOCK_SIZE -1

    xidx = blk_x + tx

    valid_x_min = (blk_x < 0) ? -blk_x : 0
    valid_x_max = (blk_x_max > cols -1)  ? BLOCK_SIZE -1 -(blk_x_max - cols +1) : BLOCK_SIZE -1
    valid_x_min = valid_x_min +1
    valid_x_max = valid_x_max +1

    W = tx - 1
    E = tx + 1
    W = (W < valid_x_min) ? valid_x_min : W
    E = (E > valid_x_max) ? valid_x_max : E

    is_valid = inrange(tx, valid_x_min, valid_x_max)

    if inrange(xidx, 1, cols)
        #prev[tx] = gpu_src[xidx]
        shared_mem[prev_offset+tx] = gpu_src[xidx]
    end

    sync_threads()

    computed = false
    for i = 1:iteration
        computed = false
        if inrange(tx, i+1, BLOCK_SIZE -i) && is_valid
            computed = true

            #left = prev[W]
            left = shared_mem[prev_offset+W]
            #up = prev[tx]
            up = shared_mem[prev_offset+tx]
            #right = prev[E]
            right = shared_mem[prev_offset+E]

            shortest = dev_min(left, up)
            shortest = dev_min(shortest, right)

            index = cols * (start_step + (i-1)) + xidx
            #result[tx] = shortest + gpu_wall[index]
            shared_mem[result_offset+tx] = shortest + gpu_wall[index]
        end
        sync_threads()
        if i == iteration
            break
        end
        if computed
            #prev[tx] = result[tx]
            shared_mem[prev_offset+tx] = shared_mem[result_offset+tx]
        end
        sync_threads()
    end

    if computed
        #gpu_result[xidx] = result[tx]
        gpu_results[xidx] = shared_mem[result_offset+tx]
    end

    return nothing
end

# Host code

function init(args)

    if length(args) == 3 
        cols = parse(Int, args[1])
        rows = parse(Int, args[2])
        pyramid_height = parse(Int, args[3])
    else
        println("Usage: dynproc row_len col_len pyramid_height")
        exit(0) 
    end

    srand(M_SEED)

    # Initialize en fill wall
    # Switch semantics of row & col -> easy copy to gpu array in run function
    wall = Array{Int64}(cols, rows)
    for i = 1:length(wall)
        wall[i] = Int64(rand() % 10)
    end

    # Print wall
    if OUTPUT
        file = open("output.txt", "w")
        println(file, "wall:")
        for i = 1:rows
            for j = 1:cols
                print(file, "$(wall[j,i]) ")
            end
            println(file, "")
        end
        close(file)
    end

    return wall, rows, cols, pyramid_height

end

function calcpath(wall, result, rows, cols, 
    pyramid_height, block_cols, border_cols)

    dim_block = BLOCK_SIZE
    dim_grid = block_cols

    src = 2
    dst = 1

    for t = 0:pyramid_height:rows-1

        tmp = src
        src = dst
        dst = tmp
        iter = min(pyramid_height, rows -t -1)

        @cuda (dim_grid, dim_block, 256*2*8) kernel_dynproc(
            iter,
            wall, 
            result[src],        # Does not work with slice: CuIn(gpu_result[src,:])
            result[dst],
            cols, rows, t, border_cols
        ) 
    end

    return dst
end

function main(args)
    # Initialize data
    wall, rows, cols, pyramid_height = init(args)

    # Calculate parameters
    border_cols = pyramid_height * HALO
    small_block_col = BLOCK_SIZE - pyramid_height*HALO * 2
    block_cols = floor(Int, cols/small_block_col) + ((cols % small_block_col == 0) ? 0 : 1)

    
    println(
        """pyramid_height: $pyramid_height
        grid_size: [$cols]
        border: [$border_cols]
        block_size: $BLOCK_SIZE
        block_grid: [$block_cols]
        target_block: [$small_block_col]""")

    # Setup GPU memory
    gpu_result = Array{CuArray{Int64,1},1}(2)
    gpu_result[1] = CuArray(wall[:,1])
    gpu_result[2] = CuArray(Int64, cols)

    gpu_wall = CuArray(wall[cols+1:end])

    final_ret = calcpath(
        gpu_wall, gpu_result,
        rows, cols, pyramid_height,
        block_cols, border_cols)

    result = to_host(gpu_result[final_ret])

    free(gpu_result[1])
    free(gpu_result[2])
    free(gpu_wall)

    # Store the result into a file
    # TODO: static because it boxes no_of_nodes (#15276)
    @static if haskey(ENV, "OUTPUT")
        open("output.txt", "w") do fpo
            println(fpo, "wall:")

            for i=1:cols
                print(fpo, "$(wall[i]) ")
            end
            println(fpo, "")

            println(fpo, "result:")
            for i=1:cols
                print(fpo, "$(result[i]) ")
            end
            println(fpo, "")
        end
    end
end


dev = CuDevice(0)
ctx = CuContext(dev)

main(ARGS)

destroy(ctx)