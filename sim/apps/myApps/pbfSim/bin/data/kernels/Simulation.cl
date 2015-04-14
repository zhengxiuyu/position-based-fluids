/*******************************************************************************
 * UpdatePositions.cl
 * - The OpenCL kernel responsible for apply external forces, like gravity
 *   for instance to each particle in the simulation, and subsequenly updating
 *   the predicted position of each particle using a simple explicit Euler
 *   step
 *
 * CIS563: Physically Based Animation final project
 * Created by Michael Woods & Michael O'Meara
 ******************************************************************************/

/*******************************************************************************
 * Preprocessor directives
 ******************************************************************************/

//#define DEBUG

/*******************************************************************************
 * Constants
 ******************************************************************************/

/**
 * Acceleration force due to gravity: 9.8 m/s
 */
const constant float G = 9.8f;

/**
 * Default kernel smoothing radius
 */
const constant float H_SMOOTHING_RADIUS = 1.2f;

/*
 * Vorticity Epsilon
 */
const constant float EPSILON_VORTICITY = 0.1f;
const constant float EPSILON_VISCOSITY = 0.1f;
const constant float H6 = H_SMOOTHING_RADIUS*H_SMOOTHING_RADIUS*H_SMOOTHING_RADIUS*H_SMOOTHING_RADIUS*H_SMOOTHING_RADIUS*H_SMOOTHING_RADIUS;
const constant float PI = 3.14159265358979;
const constant float NABLA2_W_VISCOSITY_COEFF = 45.0f / (PI * H6);

/**
 * Epsilon value, as described in the section 3 "Enforcing Incompressibility"
 * of the Position Based Fluids paper
 */
const constant float EPSILON_RELAXATION = 0.1f;

/**
 * Particle rest density: 1000kg/m^3
 */
const constant float REST_DENSITY     = 1000.0f;
const constant float INV_REST_DENSITY = 1.0f / REST_DENSITY;

/*******************************************************************************
 * Types
 ******************************************************************************/

// A particle type:

typedef struct {
    
    float4 pos;    // 4 words
    
    float4 vel;    // 4 words
    
    float4 curl;   // 4 words
    
    float  mass;   // 1 word

    float  radius; // 1 word

    /**
     * VERY IMPORTANT: This is needed so that the struct's size is aligned
     * for x86 memory access along 4/word 16 byte intervals.
     *
     * If the size is not aligned, results WILL be screwed up!!!
     * Don't be like me and waste hours trying to debug this issue. The
     * OpenCL compiler WILL NOT pad your struct to so that boundary aligned
     * like g++/clang will in host (C++) land!!!.
     *
     * See http://en.wikipedia.org/wiki/Data_structure_alignment
     */
    float  __dummy[2]; // 2 words

} Particle; // total = 12 words = 64 bytes

// A type to represent the position of a given particle in the spatial
// grid the simulated world is divided into

typedef struct {

    int particleIndex; // Index of particle in particle buffer (1 word)

    int cellI;         // Corresponding grid index in the x-axis (1 word)
    
    int cellJ;         // Corresponding grid index in the y-axis (1 word)
    
    int cellK;         // Corresponding grid index in the z-axis (1 word)

} ParticlePosition;

// A type that encodes the start and length of a grid cell in sortedParticleToCell

typedef struct {
    
    int  start; // Start of the grid cell in sortedParticleToCell
    
    int length;
    
    int __dummy[2]; // Padding
    
} GridCellOffset;

// Used to carry context into the forAllNeighbors function when
// computing the position delta

typedef struct {
    
    float4 posDelta;              // Accumulated position delta
    
    const global float* lambda;   // A pointer to the lambda array with
                                  // [0 .. numParticles - 1] indices
    
} _PositionDeltaContext;

/*******************************************************************************
 * Utility functions
 ******************************************************************************/

/**
 * A helper function that scales a value x in the range [a0,a1] to a new
 * range [b0,b1]
 */
float rescale(float x, float a0, float a1, float b0, float b1)
{
    return ((x - a0) / (a1 - a0)) * (b1 - b0) + b0;
}

/**
 * A function that converts a 3D subscript (i,j,k) into a linear index
 *
 * @param [in] int i x component of subscript
 * @param [in] int j y component of subscript
 * @param [in] int k z component of subscript
 * @param [in] int w grid width
 * @param [in] int h grid height
 */
int sub2ind(int i, int j, int k, int w, int h)
{
    return i + (j * w) + k * (w * h);
}

/**
 * A function that converts a linear index x into a 3D subscript (i,j,k)
 *
 * @param [in] int x The linear index x
 * @param [in] int w grid width
 * @param [in] int h grid height
 */
int3 ind2sub(int x, int w, int h)
{
    return (int3)(x % w, (x / w) % h, x / (w * h));
}

/**
 * Given the subscript (i,j,k) as an int3 of a cell to search the vicinity of,
 * this function will return a count of valid neighboring cells (including
 * itself) in the range [1,27], e.g. between 1 and 27 neighboring cells are
 * valid and need to be searched for neighbors. The indices from 
 * [0 .. neighborCount-1] will be populated with the indices of neighboring 
 * cells in gridCellOffsets, such that for each nerighboring grid cell
 * (i', j', k'), 0 <= i' < cellX, 0 <= j' < cellY, 0 <= k' < cellZ, and the
 * corresponding entry for cell (i',j',k') in gridCellOffsets has a cell 
 * start index != -1.
 *
 * @param [in]  sortedParticleToCell
 * @param [in]  GridCellOffset* gridCellOffsets
 * @param [in]  int cellsX
 * @param [in]  int cellsY
 * @param [in]  int cellsZ
 * @param [in]  int3 cellSubscript
 * @param [out] int* neighbors
 */
int getNeighborsBySubscript(const global ParticlePosition* sortedParticleToCell
                           ,const global GridCellOffset* gridCellOffsets
                           ,int cellsX
                           ,int cellsY
                           ,int cellsZ
                           ,int3 cellSubscript
                           ,int* neighbors)
{
    int i = cellSubscript.x;
    int j = cellSubscript.y;
    int k = cellSubscript.z;
    
    // Count of valid neighbors:

    int neighborCount = 0;

    // We need to search the following potential 27 cells about (i,j,k):
    // (i + [-1,0,1], j + [-1,0,1], k + [-1,0,1]):

    int offsets[3] = { -1, 0, 1};
    int I = -99;
    int J = -99;
    int K = -99;
    
    // -1 indicates an invalid/non-existent neighbor:

    for (int i = 0; i < 27; i++) {
        neighbors[i] = -1;
    }

    for (int u = 0; u < 3; u++) {

        I = i + offsets[u]; // I = i-1, i, i+1

        for (int v = 0; v < 3; v++) {
        
            J = j + offsets[v]; // J = j-1, j, j+1

            for (int w = 0; w < 3; w++) {
            
                K = k + offsets[w]; // K = k-1, k, k+1
                
                if (   (I >= 0 && I < cellsX)
                    && (J >= 0 && J < cellsY)
                    && (K >= 0 && K < cellsZ))
                {
                    /*
                    printf("getNeighborsBySubscript :: (%d,%d,%d) => (I=%d,J=%d,K=%d)\n",
                           i, j, k,
                           I, J, K);
                    */

                    int key = sub2ind(I, J, K, cellsX, cellsY);

                    // The specified grid cell offset has a valid starting
                    // index, so we can return it as a valid neighbor:
                    if (gridCellOffsets[key].start != -1) {
                        neighbors[neighborCount++] = key;
                    }
                }
            }
        }
    }
    
    return neighborCount;
}

/**
 * For all neighbors p_j of a particle p_i, this function will apply the given
 * function to all particle pairs (p_i, p_j), accumulating the result and
 * returning it
 *
 * @param [in]  Particle* particles
 * @param [in]  ParticlePosition* sortedParticleToCell
 * @param [in]  GridCellOffset* gridCellOffsets
 * @param [in]  int cellsX
 * @param [in]  int cellsY
 * @param [in]  int cellsZ
 * @param [in]  int3 cellSubscript
 * @param [in]  (*apply)(int, const global Particle*, int, const global Particle*, void* accum)
 * @param [out] void* accum The accumulated result, passed to and update by apply
 *              for every neighbor pair of particles
 */
void forAllNeighbors(const global Particle* particles
                     ,const global ParticlePosition* sortedParticleToCell
                     ,const global GridCellOffset* gridCellOffsets
                     ,int cellsX
                     ,int cellsY
                     ,int cellsZ
                     ,int3 cellSubscript
                     ,void (*apply)(int, const global Particle*, int, const global Particle*, void* accum)
                     ,void* accum)
{
    int id = sub2ind(cellSubscript.x, cellSubscript.y, cellSubscript.z, cellsX, cellsY);

    const global Particle *p_i = &particles[id];
    
    // 27 (3x3x3) possible neighbors to search:
    int neighbors[27];
    
    int neighborCellCount = getNeighborsBySubscript(sortedParticleToCell
                                                    ,gridCellOffsets
                                                    ,cellsX
                                                    ,cellsY
                                                    ,cellsZ
                                                    ,cellSubscript
                                                    ,neighbors);
    
    #ifdef DEBUG
        int contributingParticles = 0;
    
        printf("forAllNeighbors [%d] :: (%d,%d,%d) => neighboring search cells: %d\n",
               id, cellSubscript.x, cellSubscript.y, cellSubscript.z,
               neighborCellCount);
    #endif
    
    // For all neighbors found for the given cell at grid subscript (i,j, k):
    for (int j = 0; j < neighborCellCount; j++) {
        
        // We fetch the all indices returned in neighbors and check
        // the corresponding entries in gridCellOffsets (if neighbors[j]
        // is valid):
        
        if (neighbors[j] != -1) {
            
            const global GridCellOffset* g = &gridCellOffsets[neighbors[j]];
            
            // If the start index of the grid-cell is valid, we iterate over
            // every neighbor we find:
            
            if (g->start != -1) {
                
                int start = g->start;
                int end   = start + g->length;
                
                for (int k = start; k < end; k++) {
                    
                    int J = sortedParticleToCell[k].particleIndex;
                    
                    // Skip instances in which
                    // we'd be comparing a particle to itself:
                    
                    if (id == J) {
                        continue;
                    }
                    
                    const global Particle* p_j = &particles[J];
                    
                    // Now, we compute the distance between the two particles:

                    float r = distance(p_i->pos, p_j->pos);
                    
                    // If the position delta is less then the sum of the
                    // radii of both particles, then use the particle in the
                    // density calculation:
                    
                    float distThreshold = p_i->radius + p_j->radius;
                    
                    if (r < distThreshold) {
                        
                        #ifdef DEBUG
                            printf("  in-range: p_i [i=%d] - p_j [J=%d] = %f\n", id, J, r);
                        #endif
                        
                        // Apply the given function to the particle pair
                        // (p_i, p_j) and accumulate the result:

                        apply(id, p_i, J, p_j, accum);

                        #ifdef DEBUG
                            contributingParticles += 1;
                        #endif
                    }
                }
            }
        }
    }
}

/*******************************************************************************
 * Density estimation functions
 ******************************************************************************/

/**
 * Poly6 smoothing kernel
 *
 * From the PBF slides SIGGRAPH 2013, pg. 13
 *
 * @param float4 Particle i position
 * @param float4 particle j position
 * @param float h Smoothing kernel radius
 * @returns float
 */
float poly6(float4 pos_i, float4 pos_j, float h)
{
    float4 r   = pos_i - pos_j;
    float rBar = length(r);
    
//    if (rBar > h) {
//        return 0.0;
//    }

    // (315 / (64 * PI * h^9)) * (h^2 - |r|^2)^3
    float h9 = (h * h * h * h * h * h * h * h * h);
    float A  = 1.566681471061 * h9;
    float B  = (h * h) - (rBar * rBar);

    return A * (B * B * B);
}

/**
 * Spiky smoothing kernel
 *
 * From the PBF slides SIGGRAPH 2013, pg. 13
 *
 * @param float4 Particle i position
 * @param float4 particle j position
 * @param float h Smoothing kernel radius
 * @returns float4
 */
float4 spiky(float4 pos_i, float4 pos_j, float h)
{
    float4 r   = pos_i - pos_j;
    float rBar = length(r);
    
//    if (rBar > h) {
//        return 0.0;
//    }
    
    // (45 / (PI * h^6)) * (h - |r|)^2 * (r / |r|)
    float h6   = (h * h * h * h * h * h);
    float A    = 14.323944878271 * h6;
    float B    = (h - rBar);
    return A * (B * B) * (r / rBar);
}

float d2w_viscosity(float4 pos_i, float4 pos_j, float h)
{
    float r = distance(pos_i, pos_j);
    return NABLA2_W_VISCOSITY_COEFF * (H_SMOOTHING_RADIUS - r);
}
/**
 * SPH density estimator for a pair of particles p_i and p_j
 *
 * @param int i Index of particle i
 * @param Particle* p_i Pair particle p_i
 * @param int j Index of particle j
 * @param Particle* p_j Pair particle p_j
 * @param void* The data to update (generally a float of accumulated densities)
 */
void SPHDensityEstimator_i(int i
                          ,const global Particle* p_i
                          ,int j
                          ,const global Particle* p_j
                          ,void* data)
{
    // Cast the void pointer to the type we expect, so we can update the
    // variable accordingly:

    float* accumDensity = (float*)data;
    
    *accumDensity += poly6(p_i->pos, p_j->pos, H_SMOOTHING_RADIUS);
}

/**
 * Computes the SPH gradient of a constraint function C_i, w.r.t a particle p_j
 *
 * @param int i Index of particle i
 * @param Particle* p_i Pair particle p_i
 * @param int j Index of particle j
 * @param Particle* p_j Pair particle p_j
 * @param void* The data to update (generally a float4 gradient vector)
 */
void SPHGradient_i(int i
                  ,const global Particle* p_i
                  ,int j
                  ,const global Particle* p_j
                  ,void* data)
{
    // Cast the void pointer to the type we expect, so we can update the
    // variable accordingly:

    float4* gradVector = (float4*)data;
    
    *gradVector += spiky(p_i->pos, p_j->pos, H_SMOOTHING_RADIUS);
}

/**
 * Computes the position delta of a particle p_i given a neighbor particle p_j
 *
 * @param int i Index of particle i
 * @param Particle* p_i Pair particle p_i
 * @param int j Index of particle j
 * @param Particle* p_j Pair particle p_j
 */
void PositionDelta_i(int i
                    ,const global Particle* p_i
                    ,int j
                    ,const global Particle* p_j
                    ,void* data)
{
    _PositionDeltaContext* context = (_PositionDeltaContext*)data;
    
    float lambda_i = context->lambda[i];
    float lambda_j = context->lambda[j];
    
    context->posDelta += ((lambda_i + lambda_j) * spiky(p_i->pos, p_j->pos, H_SMOOTHING_RADIUS));
}

/**
 * Given particle indices i and j, this function computes the gradient of the
 * constraint for particle i, C_i, w.r.t. particle j
 *
 *                                 / if k = i, \sum_j \nabla(p_k) * W(p_i - p_j, h)
 * \nabla(p_k) C_i = (1 / \rho_0) |
 *                                 \ if k = j, -\nabla(p_k) * W(p_i - p_j, h)
 *
 * See the section "Enforcing Incompressibility" / figure (8)
 *
 * @param [in] Particle* particles
 * @param [in] ParticlePosition* sortedParticleToCell
 * @param [in] GridCellOffset* gridCellOffsets
 * @param [in] int cellsX The number of cells in the x axis of the spatial
 *             grid
 * @param [in] int cellsY The number of cells in the y axis of the spatial
 *             grid
 * @param [in] int cellsZ The number of cells in the z axis of the spatial
 *             grid
 * @param [in] int i The index of the i-th particle
 * @param [in] int j The index of the j-th particle
 * @returns float4 The computed constraint gradient vector
 */
float4 constraintGradient(const global Particle* particles
                         ,const global ParticlePosition* sortedParticleToCell
                         ,const global GridCellOffset* gridCellOffsets
                         ,int cellsX
                         ,int cellsY
                         ,int cellsZ
                         ,int i
                         ,int j)
{
    float4 gradVector = (float4)(0.0, 0.0, 0.0, 0.0);
    
    // Case: \sum_j \nabla(p_k) * W(p_i - p_j, h)
    if (i == j) {
        
        // Convert a linear index z into (i, j, k):
        
        int3 cellSubscript = ind2sub(i, cellsX, cellsY);

        forAllNeighbors(particles
                       ,sortedParticleToCell
                       ,gridCellOffsets
                       ,cellsX
                       ,cellsY
                       ,cellsZ
                       ,cellSubscript
                       ,SPHGradient_i
                       ,(void*)&gradVector);

        return INV_REST_DENSITY * gradVector;
    
    // Case: -\nabla(p_k) * W(p_i - p_j, h)
    } else {

        const global Particle* p_i = &particles[i];
        const global Particle* p_j = &particles[j];

        SPHGradient_i(i, p_i, j, p_j, (void*)&gradVector);
        
        return INV_REST_DENSITY * -gradVector;
    }
}

/*******************************************************************************
 * Kernels
 ******************************************************************************/

/**
 * For all particles p_i in particles, this kernel applies external forces to the
 * velocity of p_i
 *
 * Currently, only applies gravity to the y component of the velocity.
 * Additional forces may be added later like wind and other forms of
 * turbulence, etc.
 *
 *   v_i = v_i + dt + f_external(x_i)
 */
kernel void applyExternalForces(global Particle* particles, float dt)
{
    int id = get_global_id(0);
    
    // Apply the force of gravity along the y-axis:
    particles[id].vel.y += (dt * -G);
}

/**
 * For all particles p_i in particles, this kernel updates the predicted 
 * position of p_i using an explicit Euler step like so:
 *
 * x_i = x_i + (dt * v_i), where x_i is the position of p_i and v_i is
 * the velocity of p_i
 */
kernel void predictPosition(global Particle* particles, float dt)
{
    int id = get_global_id(0);

    // Explicit Euler step:
    particles[id].pos += (dt * particles[id].vel);
}

/**
 * For all particles p_i in particles, this kernel discretizes each p_i's
 * position into a grid of cells with dimensions specified by cellsPerAxis.
 *
 * @param [in] Particle* particles The particles to assign to cells
 * @param [out] int2* particleToCell Each entry contains a int2 pair
 * (i,j), where i is the particle in the i-th entry of particles, and j is
 * the linear index of the corresponding linear bin (j_x, j_y, j_z), where
 * 0 <= j_x < cellsPerAxis.x, 0 <= j_y < cellsPerAxis.y,
 * and 0 <= j_z < cellsPerAxis.z
 * @param [out] int* cellHistogram A histogram of counts of particles per cell
 * @param [in] int cellsX The number of cells in the x axis of the spatial
 *             grid
 * @param [in] int cellsY The number of cells in the y axis of the spatial
 *             grid
 * @param [in] int cellsZ The number of cells in the z axis of the spatial
 *             grid
 * @param [in] float3 minExtent The minimum extent of the simulation's
 *             bounding box in world space
 * @param [in] float3 maxExtent The maximum extent of the simulation's
 *             bounding box in world space
 */
kernel void discretizeParticlePositions(const global Particle* particles
                                       ,global ParticlePosition* particleToCell
                                       ,global int* cellHistogram
                                       ,int cellsX
                                       ,int cellsY
                                       ,int cellsZ
                                       ,float3 minExtent
                                       ,float3 maxExtent)
{
    int id = get_global_id(0);
    const global Particle *p = &particles[id];
    
    // Now we have the discretized cell at (i, j, k):
    int cellI = (int)round((rescale(p->pos.x, minExtent.x, maxExtent.x, 0.0, (float)(cellsX - 1))));
    int cellJ = (int)round((rescale(p->pos.y, minExtent.y, maxExtent.y, 0.0, (float)(cellsY - 1))));
    int cellK = (int)round((rescale(p->pos.z, minExtent.z, maxExtent.z, 0.0, (float)(cellsZ - 1))));

    particleToCell[id].particleIndex = id;
    
    // Set the (i,j,k) index of the cell:
    particleToCell[id].cellI = cellI;
    particleToCell[id].cellJ = cellJ;
    particleToCell[id].cellK = cellK;
    
    // Compute the linear index for the histogram counter
    int key = sub2ind(cellI, cellJ, cellK, cellsX, cellsY);
    
    #ifdef DEBUG
        printf("[PARTICLE %d] :: (%f, %f, %f)\t=> (%d/%d, %d/%d, %d/%d) => %d\n",
               id,
               p->pos.x, p->pos.y, p->pos.z,
               cellI, cellsX, cellJ, cellsY, cellK, cellsZ,
               key);
    #endif

    // This is needed; "cellHistogram[z] += 1" won't work here as multiple
    // threads are modifying cellHistogram simultaneously:

    atomic_add(&cellHistogram[key], 1);
}

/**
 * NOTE: This kernel is meant to be run with 1 thread. This is necessary
 * since we have to perform a sort and perform some other actions which are
 * inherently sequential in nature
 *
 * This kernel basically performs a counting sort 
 * (http://en.wikipedia.org/wiki/Counting_sort) on the particles, sorting
 * them by the grid cell they were each assigned to. Rather than sorting by
 * a 3 dimensional subscript (i,j,k), we linearize the subscript, and sort by
 * that
 *
 * @see discretizeParticlePositions
 *
 * @param [in] particleToCell
 * @param [in/out] cellHistogram
 * @param [out] sortedParticleToCell
 * @param [out] gridCellOffsets An array of size [0 .. numCells-1], where
 *              each index i contains the start and length of the i-th
 *              cell in the grid as it occurs in sortedParticleToCell
 * @param [in] numParticles The total number of particles in the simulation
 * @param [in] numCells The total number of cells in the spatial grid
 * @param [in] int cellsX The number of cells in the x axis of the spatial
 *             grid
 * @param [in] int cellsY The number of cells in the y axis of the spatial
 *             grid
 * @param [in] int cellsZ The number of cells in the z axis of the spatial
 *             grid
 */
kernel void sortParticlesByCell(const global ParticlePosition* particleToCell
                               ,global int* cellHistogram
                               ,global ParticlePosition* sortedParticleToCell
                               ,global GridCellOffset* gridCellOffsets
                               ,int numParticles
                               ,int numCells
                               ,int cellsX
                               ,int cellsY
                               ,int cellsZ)
{
    // First step of counting sort is done already, since we calculated
    //the histogram (cellHistogram) in the discretizeParticlePositions kernel:
    
    int prefixSum = 0;
    int totalSum  = 0;

    // Second step of counting sort:
    for (int i = 0; i < numCells; i++) {
        prefixSum        = cellHistogram[i];
        cellHistogram[i] = totalSum;
        totalSum        += prefixSum;
    }

    // Final step of counting sort:
    for (int i = 0; i < numParticles; i++) {

        const global ParticlePosition* pp = &particleToCell[i];

        int key = sub2ind(pp->cellI, pp->cellJ, pp->cellK, cellsX, cellsY);
        int j   = cellHistogram[key];

        sortedParticleToCell[j] = *pp;
        
        cellHistogram[key] += 1;
    }
    
    // Now, the ParticlePosition entries of sortedParticleToCell are sorted in
    // ascending order by the value sub2ind(pp[i].cellI, pp[i].cellJ, pp[i].cellK, cellsX, cellsY),
    // where pp is an instance of ParticlePosition  at index i, such that
    // 0 <= i < numParticles.

    // Record the offsets per grid cell:
    // The i-th entry of the gridCellOffsets contains the start and length
    // of the i-th linearized grid cell in sortedParticleToCell

    int lengthCount = 1;
    int cellStart   = 0;
    int currentKey  = -1;
    int nextKey     = -1;
    
    // We traverse the list to find sequences of consecutive particles that
    // are assigned the same cell. We record the start and length to these
    // sequences and store the results in gridCellOffsets, so we can
    // quickly find all of the particles in a given cell quickly.

    for (int i = 0; i < (numParticles - 1); i++) {

        // Compare the particle position at index i and i+1:
        
        const global ParticlePosition* currentP = &sortedParticleToCell[i];
        const global ParticlePosition* nextP    = &sortedParticleToCell[i+1];

        // If two particles p and q have cell subscripts (p_x, p_y, p_z) and
        // (q_x, q_y, q_z), then the keys are the linearized indices for p and
        // q, p_key and q_key.

        currentKey = sub2ind(currentP->cellI, currentP->cellJ, currentP->cellK, cellsX, cellsY);
        nextKey    = sub2ind(nextP->cellI, nextP->cellJ, nextP->cellK, cellsX, cellsY);
        
        // If p_key and q_key are equal, increase the length of the span:

        if (currentKey == nextKey) {

            lengthCount++;

        } else {
            
            // We hit a new key. Record this grid cell offset and continue;

            gridCellOffsets[currentKey].start  = cellStart;
            gridCellOffsets[currentKey].length = lengthCount;
            
            cellStart   = i + 1;
            lengthCount = 1;
        }
    }
    
    // For the last particle, since we iterate up to, but not including
    // the particle at index (numParticles - 1):

    if (nextKey != -1) {
        gridCellOffsets[nextKey].start  = cellStart;
        gridCellOffsets[nextKey].length = lengthCount;
    }

    #ifdef DEBUG
        printf("=======================\n");
        for (int i = 0; i < numParticles; i++) {
            global ParticlePosition* spp = &sortedParticleToCell[i];
            int key = sub2ind(spp->cellI, spp->cellJ, spp->cellK, cellsX, cellsY);
            printf("P [%d] :: particleIndex = %d, key = %d, cell = (%d,%d,%d) \n",
                   i, spp->particleIndex, key, spp->cellI, spp->cellJ, spp->cellK);
        }
        printf("\n");
        for (int i = 0; i < numCells; i++) {
            global GridCellOffset* gco = &gridCellOffsets[i];
            printf("C [%d] :: start = %d, length = %d\n", i, gco->start, gco->length);
        }
    #endif
}

/**
 * From the Macklin & Muller paper: SPH density estimation
 * 
 * The SPH density estimator calculates \rho_i = \sum_j * m_j * W(p_i - p_j, h),
 * where \rho_i is the density of the i-th particle, m_j is the mass of the 
 * j-th particle, p_i - p_j is the position delta between the particles p_i and
 * p_j and h is the smoothing radius
 *
 * @param [in]  Particle* particles
 * @param [in]  ParticlePosition* sortedParticleToCell
 * @param [in]  GridCellOffset* gridCellOffsets
 * @param [in]  int cellsX The number of cells in the x axis of the spatial
 *              grid
 * @param [in]  int cellsY The number of cells in the y axis of the spatial
 *              grid
 * @param [in]  int cellsZ The number of cells in the z axis of the spatial
 *              grid
 * @param [out] float* density
 */
void kernel estimateDensity(const global Particle* particles
                           ,const global ParticlePosition* sortedParticleToCell
                           ,const global GridCellOffset* gridCellOffsets
                           ,int cellsX
                           ,int cellsY
                           ,int cellsZ
                           ,global float* density)
{
    int id = get_global_id(0);
    
    // Convert a linear index z into (i, j, k):

    int3 cellSubscript = ind2sub(id, cellsX, cellsY);
    
    // For all neighboring particles p_j of the current particle (specified
    // by particles[id], aka p_i), apply the function estimateDensity for
    // all (p_i, p_j), accumulating the result into the density variable:

    float estDensity = 0.0f;
    
    forAllNeighbors(particles
                   ,sortedParticleToCell
                   ,gridCellOffsets
                   ,cellsX
                   ,cellsY
                   ,cellsZ
                   ,cellSubscript
                   ,SPHDensityEstimator_i
                   ,(void*)&estDensity);

    density[id] = estDensity;
    
    #ifdef DEBUG
        printf("estimateDensity [%d] :: density = %f\n", id, density[id]);
    #endif
}

/**
 * For all particles p_i in particles, this kernel computes the density
 * constraint lambda value, defined as
 *
 *   \lambda_i = -C_i(p_1, ..., p_n) / \sum_k |\nabla(p_k) C_i|^2
 *
 * where,
 * 
 *   1) C_i(p_1, ..., p_n) = (\rho_i / \rho_0) - 1 = 0,
 *
 *   2) \rho_0 is the rest density, and
 *
 *   3) \rho_i is the density for particle p_i
 *
 * NOTE:
 * This corresponds to Figure (1) in the section "Enforcing Incompressibility"
 *
 * @param [in]  const Particle* particles The particles in the simulation
 * @param [in]  const ParticlePosition* sortedParticleToCell
 * @param [in]  const GridCellOffset* gridCellOffsets
 * @param [in]  const float* density The density per particle. The i-th entry
 *              contains the density for the i-th particle
 * @param [in]  int numParticles The number of particles in the simulation
 * @param [in]  int cellsX The number of cells in the x axis of the spatial
 *              grid
 * @param [in]  int cellsY The number of cells in the y axis of the spatial
 *              grid
 * @param [in]  int cellsZ The number of cells in the z axis of the spatial
 *              grid
 * @param [out] float* lambda The constraint lambda value
 */
kernel void computeLambda(const global Particle* particles
                         ,const global ParticlePosition* sortedParticleToCell
                         ,const global GridCellOffset* gridCellOffsets
                         ,const global float* density
                         ,int numParticles
                         ,int cellsX
                         ,int cellsY
                         ,int cellsZ
                         ,global float* lambda)
{
    int id = get_global_id(0);

    // Compute the constraint value C_i(p_1, ... p_n) for all neighbors [1..n]
    // of particle i:

    float C_i = (density[id] * INV_REST_DENSITY) - 1.0f;
    
    // and the summation of the gradient of C_i w.r.t. each particle k:

    float gradientSum_i = 0.0f;

    for (int k = 0; k < numParticles; k++) {

        float4 gradient = constraintGradient(particles
                                            ,sortedParticleToCell
                                            ,gridCellOffsets
                                            ,cellsX
                                            ,cellsY
                                            ,cellsZ
                                            ,id
                                            ,k);

        float gradLength = length(gradient);

        gradientSum_i += (gradLength * gradLength);
    }

    lambda[id] = -(C_i / (gradientSum_i + EPSILON_RELAXATION));
}

/**
 * For all particles p_i in particles, this kernel computes the position
 * delta of p_i, p_i*
 *
 * @param [in]  const Particle* particles The particles in the simulation
 * @param [in]  const ParticlePosition* sortedParticleToCell
 * @param [in]  const GridCellOffset* gridCellOffsets
 * @param [in]  const float* density The density per particle. The i-th entry
 *              contains the density for the i-th particle
 * @param [in]  int numParticles The number of particles in the simulation
 * @param [in]  int cellsX The number of cells in the x axis of the spatial
 *              grid
 * @param [in]  int cellsY The number of cells in the y axis of the spatial
 *              grid
 * @param [in]  int cellsZ The number of cells in the z axis of the spatial
 *              grid
 * @param [out] float* posDeltaX position changes in X
 * @param [out] float* posDeltaY position changes in Y
 * @param [out] float* posDeltaZ position changes in Z
 */
kernel void computePositionDelta(const global Particle* particles
                                ,const global ParticlePosition* sortedParticleToCell
                                ,const global GridCellOffset* gridCellOffsets
                                ,const global float* lambda
                                ,int cellsX
                                ,int cellsY
                                ,int cellsZ
                                ,global float* posDeltaX
                                ,global float* posDeltaY
                                ,global float* posDeltaZ)
{
    int id = get_global_id(0);

    //const global Particle *p = &particles[id];
    
    // Convert a linear index z into (i, j, k):
    
    int3 cellSubscript = ind2sub(id, cellsX, cellsY);
    
    _PositionDeltaContext pd = { .posDelta = (float)(0.0, 0.0, 0.0, 0.0),
                                 .lambda = lambda };
    
    forAllNeighbors(particles
                   ,sortedParticleToCell
                   ,gridCellOffsets
                   ,cellsX
                   ,cellsY
                   ,cellsZ
                   ,cellSubscript
                   ,PositionDelta_i
                   ,(void*)&pd);

    float4 pStar = INV_REST_DENSITY * pd.posDelta;
    
    posDeltaX[id] = pStar.x;
    posDeltaY[id] = pStar.y;
    posDeltaZ[id] = pStar.z;
    
    /*
    printf("computePositionDelta [%d] :: delta => (%f,%f,%f)\n",
           id, pStar.x, pStar.y, pStar.z);
    */
}

/**
 * Apply position changes to all particles
 */
kernel void applyPositionDelta(global Particle* particles
                              ,global float* posDeltaX
                              ,global float* posDeltaY
                              ,global float* posDeltaZ)
{
    int id = get_global_id(0);
    
    global Particle *p = &particles[id];
    
    p->pos.x += posDeltaX[id];
    p->pos.y += posDeltaY[id];
    p->pos.z += posDeltaZ[id];
}


/**
 *  Add Viscosity to each particle
 *
 */
kernel void applyViscosity(global Particle* particles,
                           const global ParticlePosition* sortedParticleToCell,
                           const global GridCellOffset* gridCellOffsets,
                           const global float* density,
                           int cellsX, int cellsY, int cellsZ)
{
    int id = get_global_id(0);
    
    global Particle *p = &particles[id];
    
    int3 cellSubscript = ind2sub(id, cellsX, cellsY);
    
    // 27 (3x3x3) possible neighbors to search:
    int neighbors[27];
    
    int neighborCellCount = getNeighborsBySubscript(sortedParticleToCell, gridCellOffsets,
                                                    cellsX, cellsY, cellsZ,
                                                    cellSubscript, neighbors);
    
    
    float4 viscosity = float4(0.0f,0.0f,0.0f,0.0f);
    float4 r;
    int n_j;
    // For all neighbors found for the given cell at grid subscript (i,j, k):
    for (int j = 0; j < neighborCellCount; j++) {
        n_j = neighbors[j];
        if (neighbors[j] != -1 && n_j != id && density[n_j] != 0.0) {
            //r = length(p->pos - particles[n_j].pos);
            //if (H_SMOOTHING_RADIUS > r)
            {
                viscosity = particles[n_j].vel - p->vel;
                viscosity *= particles[n_j].mass * d2w_viscosity(p->pos, particles[n_j].pos, H_SMOOTHING_RADIUS);
                viscosity /= density[n_j];
                viscosity *= EPSILON_VISCOSITY;
                particles[id].vel += viscosity;
            }
        }
    }
    
}


/**
 *  Compute the Curl for each particle
 *
 */
kernel void computeCurl(global Particle* particles,
                        const global ParticlePosition* sortedParticleToCell,
                        const global GridCellOffset* gridCellOffsets,
                        int cellsX, int cellsY, int cellsZ)
{
    int id = get_global_id(0);
    
    global Particle *p = &particles[id];
    
    int3 cellSubscript = ind2sub(id, cellsX, cellsY);
    
    // 27 (3x3x3) possible neighbors to search:
    int neighbors[27];
    
    int neighborCellCount = getNeighborsBySubscript(sortedParticleToCell, gridCellOffsets,
                                                    cellsX, cellsY, cellsZ,
                                                    cellSubscript, neighbors);
    
    
     float4 curl = float4(0.0f,0.0f,0.0f,0.0f);
     float4 gradient, vel;
     int n_j;
     // For all neighbors found for the given cell at grid subscript (i,j, k):
     for (int j = 0; j < neighborCellCount; j++) {
         n_j = neighbors[j];
         if (neighbors[j] != -1) {
             vel = particles[n_j].vel - p->vel;
             gradient = spiky(p->pos, particles[n_j].pos, H_SMOOTHING_RADIUS);
             curl += cross(vel, gradient);
         }
     }
     
     particles[id].curl = curl;
    
}


/**
 * Vorticity Confinement
 *
 */
kernel void applyVorticity(global Particle* particles,
                           float dt,
                           const global ParticlePosition* sortedParticleToCell,
                           const global GridCellOffset* gridCellOffsets,
                           int cellsX, int cellsY, int cellsZ)
{
    int id = get_global_id(0);
    
    global Particle *p = &particles[id];
    
    int3 cellSubscript = ind2sub(id, cellsX, cellsY);
    
    // 27 (3x3x3) possible neighbors to search:
    int neighbors[27];
    
    int neighborCellCount = getNeighborsBySubscript(sortedParticleToCell
                                                    ,gridCellOffsets
                                                    ,cellsX
                                                    ,cellsY
                                                    ,cellsZ
                                                    ,cellSubscript
                                                    ,neighbors);
    
    float4 r; // r is the distance to the center of the vortex
    float4 gradVorticity = float4(0.0f,0.0f,0.0f,0.0f);
    float gradLength;
    int n_j;
    // For all neighbors found for the given cell at grid subscript (i,j, k):
    for (int j = 0; j < neighborCellCount; j++) {
        n_j = neighbors[j];
        if (neighbors[j] != -1) {
            r = particles[n_j].pos - p->pos;
            gradLength = length(particles[n_j].curl - p->curl);
            gradVorticity += gradLength / r;
        }
    }
    
    float4 vorticity, N;
    N = 1.0f / (length(gradVorticity) + EPSILON_VORTICITY) * gradVorticity;
    vorticity = dt * EPSILON_RELAXATION * cross(N, p->curl);
    particles[id].vel += vorticity;
    
}

/**
 * Tests for collisions between particles and objects/bounds and projects
 * the positions of the particles accordingly
 * 
 * TODO: For now, this just clamps the particle to the world bounds
 */
kernel void resolveCollisions(global Particle* particles
                             ,float3 minExtent
                             ,float3 maxExtent)
{
    int id = get_global_id(0);

    global Particle *p = &particles[id];

    p->pos.x = clamp(p->pos.x, minExtent.x + p->radius, maxExtent.x - p->radius);
    p->pos.y = clamp(p->pos.y, minExtent.y + p->radius, maxExtent.y - p->radius);
    p->pos.z = clamp(p->pos.z, minExtent.z + p->radius, maxExtent.z - p->radius);
}

