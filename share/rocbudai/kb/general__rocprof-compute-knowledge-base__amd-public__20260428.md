---
source: general__rocprof-compute-knowledge-base__amd-public__20260428.pdf
source_mtime: "2026-04-28 15:22:16.436698000 -0500"
pages: 33
extracted_with: "pdftotext -layout (poppler 22.02.0)"
extracted_at: "2026-04-28T15:22:54-05:00"
---

GPU Kernel Profiling

                  Presenter: Luka Stanisic
               Datacenter Solutions Group
HPC and Sovereign AI Customer Enablement
                          April 21-24, 2026
[Public]




            AMD has three main GPU profiling tools



                                                                                               rocprof-compute
                                                                                         GPU kernel performance analysis



                        rocprofv3                                     rocprof-sys
             GPU tracing and counter collection                    GPU and CPU tracing




                       librocprofiler-sdk library - tracing and profiling infrastructure for developing tools




              April 21-24, 2026                     AMD Instinct   GPU Training @ HLRS/MPCDF
    2   |
[Public]




            What is Rocprofiler-compute?

            • Rocprofiler-compute is a GPU kernel performance analysis tool added to ROCm with version 6.3
                 •   Predecessor (before ROCm 6.3) an AMD Research tool called Omniperf that needed separate install


            • Most notable features:
                 •   Roofline analysis to quantify performance of GPU kernels based on hardware limits
                 •   Kernel comparison to quantify improvements and visualize their impact on hardware memory
                 •   Executes kernels many times for automatic hardware counter collection providing many derived metrics




              April 21-24, 2026                       AMD Instinct   GPU Training @ HLRS/MPCDF
    3   |
[Public]




            Background – What is roofline?

            •   Attainable FLOPs/s =
                           𝑃𝑒𝑎𝑘 𝐹𝐿𝑂𝑃𝑠/𝑠                            1000
                 •   𝑚𝑖𝑛 ቊ                                                                  Unattainable performance
                           𝐴𝐼 ∗ 𝑃𝑒𝑎𝑘 𝐺𝐵/𝑠                                                   (greater than peak FLOPs/s)   Peak FLOPs/s
            •   Machine balance:                                                                                    Compute Bound




                                                      Attainable FLOPs/s
                                𝑃𝑒𝑎𝑘 𝐹𝐿𝑂𝑃𝑠/𝑠
                 •   Where 𝐴𝐼 =
                                 𝑃𝑒𝑎𝑘 𝐺𝐵/𝑠

            •   Five performance regions:                                  100
                 •   Unattainable compute
                 •   Unattainable bandwidth
                 •   Compute bound
                 •   Bandwidth bound
                 •   Poor performance
                                                                           10

                                                                                 0.1                         1                      10
                                                                                          Arithmetic Intensity (FLOPs/Byte)



                April 21-24, 2026              AMD Instinct                  GPU Training @ HLRS/MPCDF
    4   |
[Public]




            Visualize rooflines with Rocprofiler-compute
            rocprof-compute profile -n rooflines_PDF --roof-only --kernel-names -- ./GhostExchange -x 1 -y 1 -i
            20000 -j 20000 -h 2 -t -c -I 100




                                                                                           Note: In some Rocprofiler-
                                                                                           compute versions FP32 and
                                                   blur                                    FP64 lines overlapping –
                                                                                           fixed later




                                                    init_core2


               April 21-24, 2026               AMD Instinct   GPU Training @ HLRS/MPCDF
    5   |
[Public]




            Get kernels info with Rocprofiler-compute

            • To generate profiling data run:
            rocprof-compute profile -n v1 --no-roof -- ./GhostExchange -x 1 -y 1 -i 200 -j 200 -h 2 -t -c -I 100


            • You can then display the IDs of the kernels involved by doing:
            rocprof-compute analyze --list-stats -p workloads/v1/MI300A_A1/



                   blur kernel
                   has ID 0




               April 21-24, 2026                  AMD Instinct   GPU Training @ HLRS/MPCDF
    6   |
[Public]




            Get kernel dispatch ID with Rocprofiler-compute

            • The command below will also show you the dispatch IDs for each kernel. Let’s consider blur:
            rocprof-compute analyze --list-stats -p workloads/v1/MI300A_A1/ | grep blur




                               The dispatch IDs represent the IDs of the call to the specific kernel during the run



               April 21-24, 2026                        AMD Instinct   GPU Training @ HLRS/MPCDF
    7   |
[Public]




            Compare different kernels implementations

            • Modify the blur and init_core kernel grid size and block size at GhostExchange.hip:207 from:
            dim3 grid((isize+63)/64, (jsize+3)/4, 1);                   dim3 block(64, 4, 1);
            • To:
            dim3 grid((isize+255)/256, (jsize+3)/4, 1);                 dim3 block(256, 4, 1);


            • Then compile and generate the profiling data for this new version:
            rocprof-compute profile -n v2 --no-roof -- ./GhostExchange -x 1 -y 1 -i 200 -j 200 -h 2 -t -c -I 100


            • You can compare the two versions by using rocprof-compute analyze:
            rocprof-compute analyze -p workloads/v1/MI300A_A1 –p workloads/v2/MI300A_A1 --block 16.2 17.2




            Not specifying any dispatch in the rocprof-compute analyze command above will show averaged values
               April 21-24, 2026                  AMD Instinct   GPU Training @ HLRS/MPCDF
    8   |
[Public]




            Guided exercises


            1. Launch parameters

            2. LDS occupancy limiter

            3. VGPR occupancy limiter

            4. Strided data access pattern / representative problem size

            5. Algorithmic optimizations




               April 21-24, 2026                  AMD Instinct   GPU Training @ HLRS/MPCDF
    9   |
[Public]




            Guided exercises: Optimizing yAx kernel

            • For all exercises focusing on a simple kernel
              • yAx is a vector-matrix-vector product that can be implemented in serial as:


                         double result = 0.0;
                         for (int i = 0; i < n; i++){
                           double temp = 0.0;
                           for (int j = 0; j < m; j++){
                             temp += A[i*m + j] * x[j];
                           }
                           result += y[i] * temp;
                         }
            • Where:
              • A is a 1-D array of size n*m
              • x is an array of size m
              • y is an array of size n




               April 21-24, 2026                       AMD Instinct   GPU Training @ HLRS/MPCDF
   12   |
[Public]




            Exercise 1: First things first, generate a roofline

            • Run this command to generate roofline plots and a legend for each kernel (in PDF form):
              • rocprof-compute profile -n problem_roof_only --roof-only --kernel-names -- ./problem.exe
                • The files will appear in the ./workloads/problem_roof_only/MI300_A1 folder
                • --roof-only generates PDF roofline plots, and does not generate any non-roofline profiling data
                • --kernel-names generates a separate PDF showing which kernel names correspond to which icons in the roofline




            • Rooflines are a useful tool in determining which GPU kernels are good optimization targets
              • Only one perspective of performance, kernel runtime cannot be inferred from the roofline


            • Generated PDF roofline plots can have overlapping data points but should still be instructive


            • Complete sets of roofline plots and commands can be found in the READMEs for each exercise




               April 21-24, 2026                               AMD Instinct   GPU Training @ HLRS/MPCDF
   13   |
[Public]




            Exercise 1: Roofline plots
                      FP32 Roofline Plot                                                   FP16/INT8 Roofline Plot




                            Very poor performance!
                                                                                                       Note: The L2 data point
                                                                                                       is hidden behind the
                                                                                                       HBM data point




                                  Kernel legend in
                                  a separate PDF

              April 21-24, 2026
   14   |                                            AMD Instinct   GPU Training @ HLRS/MPCDF
[Public]




            Exercise 1: Prep to find kernel launch parameters

            • Launch parameters are given at the time of the kernel launch, as in lines 49 and 54:
              • yax<<<grid,block>>>(y,A,x,n,m,result);
                 •   Where grid and block are the kernel yax’s launch parameters
              • In problem, grid = (4,1,1), and block = (64,1,1)
              • In solution, grid = (2048,1,1), and block = (64,1,1)


            • Sometimes launch parameters can be obfuscated by OpenMP® and other parallelism layers

            • Rocprof-compute can easily show launch parameter information regardless of the code
              • You just need the dispatch ID – other forms of filtering may report aggregate launch parameters


            • To generate profiling data, use the commands:
              • rocprof-compute profile -n problem --no-roof -- ./problem.exe
              • rocprof-compute profile -n solution --no-roof -- ./solution.exe
                 •   --no-roof saves time by not generating roofline data – profile commands can take a while



            • Real benchmarks can take prohibitively long – use smaller representative problems when possible
               April 21-24, 2026                                   AMD Instinct    GPU Training @ HLRS/MPCDF
   15   |
[Public]




            Exercise 1: CLI Rocprof-compute comparisons are easy
             rocprof-compute analyze -p workloads/problem/MI300A_A1 -p workloads/solution/MI300A_A1                                               --dispatch 1 --block 7.1.0 7.1.1 7.1.2

                             Using problem as the baseline, and solution as the comparative
 INFO Analysis mode = cli
 INFO [analysis] deriving rocprofiler-compute metrics...

--------------------------------------------------------------------------------
0. Top Stats
0.1 Top Kernels
╒════╤══════════════════════════════════════════╤═════════╤════════════╤════════════╤══════════════╤═════════════════════╤══════════════╤═════════════════════╤══════════════╤═════════════════════╤════════╤═════════════
│    │ Kernel_Name                              │   Count │ Count      │   Abs Diff │      Sum(ns) │ Sum(ns)             │     Mean(ns) │ Mean(ns)            │   Median(ns) │ Median(ns)          │    Pct │ Pct
╞════╪══════════════════════════════════════════╪═════════╪════════════╪════════════╪══════════════╪═════════════════════╪══════════════╪═════════════════════╪══════════════╪═════════════════════╪════════╪═════════════
│ 0 │ yax(double*, double*, double*, int, int, │     1.00 │ 1.0 (0.0%) │       0.00 │ 543201153.00 │ 9589864.0 (-98.23%) │ 543201153.00 │ 9589864.0 (-98.23%) │ 543201153.00 │ 9589864.0 (-98.23%) │ 100.00 │ 100.0 (0.0%)
│    │ double*) [clone .kd]                     │         │            │            │              │                     │              │                     │              │                     │        │
╘════╧══════════════════════════════════════════╧═════════╧════════════╧════════════╧══════════════╧═════════════════════╧══════════════╧═════════════════════╧══════════════╧═════════════════════╧════════╧═════════════
0.2 Dispatch List
╒════╤═══════════════╤═══════════════════════════════════════════════════════════════╤══════════╕
│    │   Dispatch_ID │ Kernel_Name                                                   │   GPU_ID │
                                                                                                                                                56.6x speedup
╞════╪═══════════════╪═══════════════════════════════════════════════════════════════╪══════════╡
│ 0 │              1 │ yax(double*, double*, double*, int, int, double*) [clone .kd] │        4 │
╘════╧═══════════════╧═══════════════════════════════════════════════════════════════╧══════════╛       Typically, difficult to pre-determine optimal launch
--------------------------------------------------------------------------------
                                                                                                        parameters, so some experimentation often necessary
7. Wavefront
7.1 Wavefront Launch Stats
╒═════════════╤══════════════════╤════════╤═════════════════════╤════════════╤════════╤═════════════════════╤════════╤═════════════════════╤════════════╕
│ Metric_ID   │ Metric           │    Avg │ Avg                 │   Abs Diff │    Min │ Min
      │    Max │ Max                 │ Unit       │
╞═════════════╪══════════════════╪════════╪═════════════════════╪════════════╪════════╪═════════════════════╪════════╪═════════════════════╪════════════╡
│ 7.1.0       │ Grid Size        │ 256.00 │ 131072.0 (51100.0%) │ 130816.00 │ 256.00 │ 131072.0 (51100.0%) │ 256.00 │ 131072.0 (51100.0%) │ Work items │
├─────────────┼──────────────────┼────────┼─────────────────────┼────────────┼────────┼─────────────────────┼────────┼─────────────────────┼────────────┤
                                                                                                                                                            Increased launched wavefronts,
│ 7.1.1       │ Workgroup Size   │ 64.00 │ 64.0 (0.0%)          │       0.00 │ 64.00 │ 64.0 (0.0%)          │ 64.00 │ 64.0 (0.0%)          │ Work items │
├─────────────┼──────────────────┼────────┼─────────────────────┼────────────┼────────┼─────────────────────┼────────┼─────────────────────┼────────────┤   which increases grid size
│ 7.1.2       │ Total Wavefronts │   4.00 │ 2048.0 (51100.0%)   │    2044.00 │   4.00 │ 2048.0 (51100.0%)   │   4.00 │ 2048.0 (51100.0%)   │ Wavefronts │
╘═════════════╧══════════════════╧════════╧═════════════════════╧════════════╧════════╧═════════════════════╧════════╧═════════════════════╧════════════╛


              April 21-24, 2026                                                AMD Instinct       GPU Training @ HLRS/MPCDF
   16   |
[Public]




            Exercise 1: Comparing problem and solution roofline plots
                    Problem FP32 Roofline Plot                                         Solution FP32 Roofline Plot




                                            Generally, moving up and to the right is good

             April 21-24, 2026                   AMD Instinct   GPU Training @ HLRS/MPCDF
   17   |
[Public]




            Exercise 1: It’s easy to check launch parameters


            rocprof-compute analyze -p workloads/problem/MI300A_A1 --dispatch 1 --block 7.1.0 7.1.1 7.1.2
              • --block filters the output to only show launch parameters


            • Good launch parameters essential to a performant GPU kernel
              • Determining which parameters give the best performance usually requires experimenting


            • Can be difficult to track down where launch parameters are set in code
              • OpenMP® may decide (thread_limit)




               April 21-24, 2026                     AMD Instinct   GPU Training @ HLRS/MPCDF
   18   |
[Public]




            Exercise 2: Diagnosing shared memory occupancy limiter

            • Using LDS (Local Data Store) shared memory to cache re-used data can increase performance


            • Using too much LDS can restrict occupancy and reduce performance


            • LDS allocation example:
              • __shared__ double tmp[fully_allocate_lds];


            • Two solutions proposed in the exercises:
              • solution-no-lds removes the LDS allocation, and thus the occupancy limiter
              • solution reduces the size of the LDS allocation, removes occupancy limiter, and is faster than solution-no-lds


            • Rocprofiler-compute makes it easy to determine if LDS allocations restrict occupancy
              • rocprof-compute profile -n problem --no-roof -- ./problem.exe
              • rocprof-compute profile -n solution --no-roof -- ./solution.exe



               April 21-24, 2026                     AMD Instinct   GPU Training @ HLRS/MPCDF
   19   |
[Public]




            Exercise 2: LDS occupancy limiter – relevant output
             rocprof-compute analyze -p workloads/problem/MI300A_A1 -p workloads/solution/MI300A_A1 --dispatch 1 --block 2.1.15 6.2.7
  INFO Analysis mode = cli
  INFO [analysis] deriving rocprofiler-compute metrics...

 --------------------------------------------------------------------------------
 0. Top Stats
 0.1 Top Kernels
 ╒════╤══════════════════════════════════════════╤═════════╤════════════╤════════════╤════════════╤════════════════════╤════════════╤════════════════════╤══════════════╤════════════════════╤════════╤══════════════╕
 │    │ Kernel_Name                              │   Count │ Count      │   Abs Diff │    Sum(ns) │ Sum(ns)            │   Mean(ns) │ Mean(ns)           │   Median(ns) │ Median(ns)         │    Pct │ Pct          │
 ╞════╪══════════════════════════════════════════╪═════════╪════════════╪════════════╪════════════╪════════════════════╪════════════╪════════════════════╪══════════════╪════════════════════╪════════╪══════════════╡
 │ 0 │ yax(double*, double*, double*, int, int, │     1.00 │ 1.0 (0.0%) │       0.00 │ 7225180.00 │ 5736816.0 (-20.6%) │ 7225180.00 │ 5736816.0 (-20.6%) │   7225180.00 │ 5736816.0 (-20.6%) │ 100.00 │ 100.0 (0.0%) │
 │    │ double*) [clone .kd]                     │         │            │            │            │                    │            │                    │              │                    │        │              │
 ╘════╧══════════════════════════════════════════╧═════════╧════════════╧════════════╧════════════╧════════════════════╧════════════╧════════════════════╧══════════════╧════════════════════╧════════╧══════════════╛
 0.2 Dispatch List
 ╒════╤═══════════════╤═══════════════════════════════════════════════════════════════╤══════════╕                                                                     1.26x speedup
 │    │   Dispatch_ID │ Kernel_Name                                                    │  GPU_ID │
 ╞════╪═══════════════╪═══════════════════════════════════════════════════════════════╪══════════╡
 │ 0 │              1 │ yax(double*, double*, double*, int, int, double*) [clone .kd] │        4 │
 ╘════╧═══════════════╧═══════════════════════════════════════════════════════════════╧══════════╛


 --------------------------------------------------------------------------------
 2. System Speed-of-Light
 2.1 Speed-of-Light
 ╒═════════════╤═════════════════════╤════════╤══════════════════╤════════════╤════════════╤═════════╤═══════════════╤═══════════════╤════════════════╕

                                                                                                                                                            + ~3% Occupancy (overall)
 │ Metric_ID   │ Metric              │    Avg │ Avg              │   Abs Diff │ Unit       │    Peak │ Peak          │   Pct of Peak │ Pct of Peak    │
 ╞═════════════╪═════════════════════╪════════╪══════════════════╪════════════╪════════════╪═════════╪═══════════════╪═══════════════╪════════════════╡
 │ 2.1.15      │ Wavefront Occupancy │ 175.66 │ 418.68 (138.35%) │       3.33 │ Wavefronts │ 7296.00 │ 7296.0 (0.0%) │          2.41 │ 5.74 (138.31%) │
 ╘═════════════╧═════════════════════╧════════╧══════════════════╧════════════╧════════════╧═════════╧═══════════════╧═══════════════╧════════════════╛


 --------------------------------------------------------------------------------
 6. Workgroup Manager (SPI)
 6.2 Workgroup Manager - Resource Allocation
 ╒═════════════╤═════════════════════╤═══════╤═══════════════╤════════════╤═══════╤═══════════════╤═══════╤═══════════════╤════════╕
 │ Metric_ID   │ Metric              │   Avg │ Avg           │   Abs Diff │   Min │ Min           │   Max │ Max           │ Unit   │
 ╞═════════════╪═════════════════════╪═══════╪═══════════════╪════════════╪═══════╪═══════════════╪═══════╪═══════════════╪════════╡   Sharp decrease in Workgroup Manager stat
 │ 6.2.7       │ Insufficient CU LDS │ 57.33 │ 0.0 (-100.0%) │     -57.33 │ 57.33 │ 0.0 (-100.0%) │ 57.33 │ 0.0 (-100.0%) │ Pct    │
 ╘═════════════╧═════════════════════╧═══════╧═══════════════╧════════════╧═══════╧═══════════════╧═══════╧═══════════════╧════════╛


               April 21-24, 2026                                               AMD Instinct       GPU Training @ HLRS/MPCDF
   20   |
[Public]




            Exercise 2: Use SPI stats to determine if LDS limits occupancy

            • Occupancy limiters can negatively impact performance
              • Occupancy increases don’t always correspond to increased performance


            • Workgroup Manager (SPI – Shader Processor Input) stats in Rocprofiler-compute indicate whether a
              kernel resource limits occupancy


            • You can get the Workgroup Manager stat for LDS for a single kernel with dispatch ID 1:
              • rocprof-compute analyze -p workloads/problem/MI300_A1 --dispatch 1 --block 2.1.15 6.2.7


            Note:
            • In Rocprofiler-compute, the Workgroup Manager “insufficient resource” stats are percentages, meaning:
              • The magnitude of these fields does not necessarily indicate how severely occupancy is impacted
                •   Changes to the Workgroup Manager stat do not necessarily translate to changes to overall occupancy
              • If two fields are nonzero, the larger number indicates that resource is limiting occupancy more




               April 21-24, 2026                                  AMD Instinct   GPU Training @ HLRS/MPCDF
   21   |
[Public]




            Exercise 3: Diagnosing a register occupancy limiter

            • Seemingly innocuous function calls inside kernels can lead to unexpected performance characteristics
              • The solution simply removes the assert
              • Admittedly the occupancy limit is very minor, but this is a good excuse to look at register usage


            • The types of registers on AMD GPUs are:
              • VGPRs (Vector General Purpose Registers): registers that can hold distinct values for each thread in the wavefront
              • SGPRs (Scalar General Purpose Registers): uniform across a wavefront. If possible, using these is preferable
              • AGPRs (Accumulation vector General Purpose Registers): special-purpose registers for MFMA (Matrix Fused
                Multiply-Add) operations, or low-cost register spills


            • Using too many of one of these register types can impact occupancy and negatively impact performance


            • We use the same profile commands to get the profiling data:
              • rocprof-compute profile -n problem --no-roof -- ./problem.exe
              • rocprof-compute profile -n solution --no-roof -- ./solution.exe



               April 21-24, 2026                      AMD Instinct   GPU Training @ HLRS/MPCDF
   22   |
[Public]




        Exercise 3: Register occupancy limiter – relevant output
        rocprof-compute analyze -p workloads/problem/MI300A_A1 -p workloads/solution/MI300A_A1 --dispatch 1 --block 2.1.15 6.2.5 7.1.5 7.1.6 7.1.7
            --------------------------------------------------------------------------------
            0. Top Stats
            0.1 Top Kernels
            ╒════╤══════════════════════════════════════════╤═════════╤════════════╤════════════╤════════════╤════════════════════╤════════════╤════════════════════╤══════════════╤════════════════════╤════════╤═════════════
            │    │ Kernel_Name                              │   Count │ Count      │   Abs Diff │    Sum(ns) │ Sum(ns)            │    Mean(ns) │ Mean(ns)          │   Median(ns) │ Median(ns)         │    Pct │ Pct
            ╞════╪══════════════════════════════════════════╪═════════╪════════════╪════════════╪════════════╪════════════════════╪════════════╪════════════════════╪══════════════╪════════════════════╪════════╪═════════════
            │ 0 │ yax(double*, double*, double*, int, int, │     1.00 │ 1.0 (0.0%) │       0.00 │ 9993665.00 │ 9666265.0 (-3.28%) │ 9993665.00 │ 9666265.0 (-3.28%) │   9993665.00 │ 9666265.0 (-3.28%) │ 100.00 │ 100.0 (0.0%)
            │    │ double*) [clone .kd]                     │         │            │            │            │                    │             │                   │              │                    │        │
            ╘════╧══════════════════════════════════════════╧═════════╧════════════╧════════════╧════════════╧════════════════════╧════════════╧════════════════════╧══════════════╧════════════════════╧════════╧═════════════
            0.2 Dispatch List
            <omitted>                                                                                                                  Minor speedup
            --------------------------------------------------------------------------------
            2. System Speed-of-Light
            2.1 Speed-of-Light
            ╒═════════════╤═════════════════════╤════════╤═════════════════╤════════════╤════════════╤═════════╤═══════════════╤═══════════════╤═══════════════╕
            │ Metric_ID   │ Metric              │    Avg │ Avg             │   Abs Diff │ Unit       │    Peak │ Peak          │    Pct of Peak │ Pct of Peak   │

                                                                                                                                                                   Similar occupancies
            ╞═════════════╪═════════════════════╪════════╪═════════════════╪════════════╪════════════╪═════════╪═══════════════╪═══════════════╪═══════════════╡
            │ 2.1.15      │ Wavefront Occupancy │ 430.98 │ 427.36 (-0.84%) │      -0.05 │ Wavefronts │ 7296.00 │ 7296.0 (0.0%) │           5.91 │ 5.86 (-0.85%) │
            ╘═════════════╧═════════════════════╧════════╧═════════════════╧════════════╧════════════╧═════════╧═══════════════╧═══════════════╧═══════════════╛


            --------------------------------------------------------------------------------
            6. Workgroup Manager (SPI)
            6.2 Workgroup Manager - Resource Allocation
            ╒═════════════╤═════════════════════════╤═══════╤══════════════╤════════════╤═══════╤══════════════╤═══════╤══════════════╤════════╕
            │ Metric_ID   │ Metric                  │   Avg │ Avg          │   Abs Diff │   Min │ Min          │   Max │ Max          │ Unit   │
            ╞═════════════╪═════════════════════════╪═══════╪══════════════╪════════════╪═══════╪══════════════╪═══════╪══════════════╪════════╡
                                                                                                                                                       Minor change in Workgroup
            │ 6.2.5       │ Insufficient SIMD VGPRs │ 0.06 │ 0.0 (-99.7%) │       -0.06 │ 0.06 │ 0.0 (-99.7%) │ 0.06 │ 0.0 (-99.7%) │ Pct      │
            ╘═════════════╧═════════════════════════╧═══════╧══════════════╧════════════╧═══════╧══════════════╧═══════╧══════════════╧════════╛       Manager stat
            --------------------------------------------------------------------------------
            7. Wavefront                Exact values might be slightly different,
            7.1 Wavefront Launch Stats but conclusion stay the same
            ╒═════════════╤══════════╤════════╤═════════════════╤════════════╤════════╤═════════════════╤════════╤═════════════════╤═══════════╕
            │ Metric_ID   │ Metric   │    Avg │ Avg             │   Abs Diff │    Min │ Min             │    Max │ Max             │ Unit      │
            ╞═════════════╪══════════╪════════╪═════════════════╪════════════╪════════╪═════════════════╪════════╪═════════════════╪═══════════╡
            │ 7.1.5       │ VGPRs    │ 92.00 │ 32.0 (-65.22%) │       -60.00 │ 92.00 │ 32.0 (-65.22%) │ 92.00 │ 32.0 (-65.22%) │ Registers │
            ├─────────────┼──────────┼────────┼─────────────────┼────────────┼────────┼─────────────────┼────────┼─────────────────┼───────────┤
                                                                                                                                                   Fewer VGPRs
            │ 7.1.6       │ AGPRs    │ 132.00 │ 0.0 (-100.0%)   │    -132.00 │ 132.00 │ 0.0 (-100.0%)   │ 132.00 │ 0.0 (-100.0%)   │ Registers │
            ├─────────────┼──────────┼────────┼─────────────────┼────────────┼────────┼─────────────────┼────────┼─────────────────┼───────────┤
                                                                                                                                                   No AGPRs
            │ 7.1.7       │ SGPRs    │ 48.00 │ 112.0 (133.33%) │       64.00 │ 48.00 │ 112.0 (133.33%) │ 48.00 │ 112.0 (133.33%) │ Registers │
            ╘═════════════╧══════════╧════════╧═════════════════╧════════════╧════════╧═════════════════╧════════╧═════════════════╧═══════════╛   More SGPRs
                   April 21-24, 2026                                               AMD Instinct       GPU Training @ HLRS/MPCDF
   23   |
[Public]




            Exercise 3: Register occupancy limiter – takeaways

            • In this case the occupancy limit very minor


            • Seemingly harmless function calls inside kernels can lead to unexpected performance
              • Asserts and excessive use of math functions in kernels can degrade performance
              • Can be difficult to construct clear examples


            • AGPR usage in the absence of MFMA instructions can indicate degraded performance
              • Spilling registers to AGPRs, due to running out of VGPRs


            • To determine if any Workgroup Manager “insufficient resource” stats are nonzero, you can do:
              • rocprof-compute analyze -p workloads/problem/MI300A_A1 --block 6.2
                •   Note: This will report more than just all “insufficient resource” fields




               April 21-24, 2026                                        AMD Instinct     GPU Training @ HLRS/MPCDF
   24   |
[Public]




           Rocprofiler-compute tips

           • Filtering by kernel name and metrics during rocprof-compute profile will cut down on profiling time
             • rocprof-compute profile -k “<kernel1>” “<kernel2>” filters two kernel names
             • Surrounding kernel name in quotes allows spaces to appear in your kernel search string
             • Rocprofiler-compute applies wildcard automatically, so only unique kernel names substring required


           • Use a subset of metrics for rocprof-compute profile to reduce the number of rocprof runs
             • rocprof-compute profile --block SQ SQC -n <workload name> -- ./benchmark.sh
             • rocprof-compute profile --help displays all block strings you can filter by
             • Performance model doc goes over some of the meaning behind lower-level hardware units and metrics


           • MPI/srun support still brittle, safest way is to use node interactively and run only with 1 MPI rank
             • If your codes needs to be executed with multiple MPI ranks, check the documentation for your ROCm version


        • Don’t know where to start? → Easy things to check:
          • Are all the CUs being used? → If not, more parallelism is required (for most of the cases)
          • Are all the VGPRs being spilled? → Try smaller workgroup sizes
          • Is the code Integer limited? → Try reducing the integer ops, usually in the index calculation
   36 |
[Public]




            News since last year

            •   Several major and numerous minor ROCm releases and pre-releases: 7.0, 7.1, 7.2


            •   New features in presented tools:
                •     rocprof-compute


            •   New tools:
                • Thread Trace/Trace Decoder/ROCprof Compute Viewer


            • Showing highlights from an HPC engineer perspective, for a full list see ROCm release notes




                    April 21-24, 2026              AMD Instinct   GPU Training @ HLRS/MPCDF
   37   |
[Public]




            rocprof-compute: New features

            • Dynamic process attachment in ROCm Compute Profiler
            • CU utilization: The percent of total SIMD cycles in the kernel where any SIMD on a CU was actively doing
              any work, summed over all CUs (replacing Active CUs)
            • Single-pass counter collection using sets, see --set / --list-sets & filtering options
            • Textual User Interface (TUI) analysis
            • Support for FP4 and FP6
            • Support for rocpd output format


            Available in ROCm pre-releases (a.k.a “TheRock”), coming soon to the official releases:
            • Iteration multiplexing

               April 21-24, 2026                    AMD Instinct   GPU Training @ HLRS/MPCDF
   38   |
[Public]




            Thread Trace and ROCprof Compute Viewer

            • rocprofv3 enables basic GPU profiling and hardware counters
            • rocprof-sys gives a system level view including CPU, MPI, etc.
            • rocprof-compute provides a detailed overview kernel performance


            • What has been missing is a tool that looks at performance within a kernel
              • What lines of code in the kernel are taking the most time?
              • Where are stalls happening?
              • What parts of the kernel are consuming resources such as LDS memory?


            • Basic usage:
              • Install ROCprof Compute Viewer on a local machine
              • Collect data on a compute node: rocprofv3 --att -- ./app
              • Transfer data from compute node to the local machine, open data folder with ROCprof Compute Viewer


            • Limitations: no cache rates, no memory bandwidth, limited to few short (<1s) kernels

               April 21-24, 2026                    AMD Instinct   GPU Training @ HLRS/MPCDF
   39   |
[Public]




            ROCprof Compute Viewer: High-level view of kernels




                          Summary View

                                                                                    Instructions View
             April 21-24, 2026           AMD Instinct   GPU Training @ HLRS/MPCDF
   40   |
[Public]




            ROCprof Compute Viewer: Timeline views




                                                                                        Hotspot Timeline


                                 Wave States Timeline




                                                                                             Compute Unit Timeline

                                 Occupancy Timeline
             April 21-24, 2026                    AMD Instinct   GPU Training @ HLRS/MPCDF
   41   |
[Public]




            Summary

            •   Rocprofiler-compute: a GPU kernel-level profiling tool that automatically collects many counters

            •   Can create roofline analysis to understand kernel efficiency and distance to the theoretical peaks


            •   Displays many kernel metrics, but to correctly interpret it good knowledge of the kernel required
                •     Easy to start running it, but steep learning curve for the analysis


            •   Supports standalone GUI, and CLI

            •   Includes several features such as:
                •     System speed-of-light panel
                •     Memory chart analysis panel
                •     Vector L1D cache panel
                •     Shader processing input (SPI) panel



                    April 21-24, 2026                        AMD Instinct   GPU Training @ HLRS/MPCDF
   42   |
[Public]




            Additional resources

            • Introduction to profiling tools for AMD hardware:
                •   https://rocm.blogs.amd.com/software-tools-optimization/profilers/README.html


            • Three-part profiling guide on ROCm blogs:
                •   Intro: https://rocm.blogs.amd.com/software-tools-optimization/profiling-guide/intro/README.html
                •   Novice: https://rocm.blogs.amd.com/software-tools-optimization/profiling-guide/novice/README.html
                •   Advanced: https://rocm.blogs.amd.com/software-tools-optimization/profiling-guide/advanced/README.html




               April 21-24, 2026                     AMD Instinct   GPU Training @ HLRS/MPCDF
   43   |
[Public]




            Hands-on exercises

            • Located in our HPC Training Examples repo: https://github.com/amd/HPCTrainingExamples


            • rocprof-compute exercises:
              • rocprof-compute/1-LaunchParameters/README.md
              • rocprof-compute/2-LDSOccupancyLimit/README.md
              • rocprof-compute/3-RegisterOccupancyLimit/README.md
              • rocprof-compute/4-StridedAccess/README.md
              • rocprof-compute/5-AlgorithmicOptimizations/README.md
              • rocprof-compute/OpenMP/Fortran/1_collapse/README.md


            • Some details like block numbers may need update for newer tool version, but commands and workflow
              stay the same


            • Recommended module on AAC6: module load rocm/7.2.0
            • Recommended module on AAC7: module swap rocm rocm-new/7.2.0

               April 21-24, 2026                 AMD Instinct   GPU Training @ HLRS/MPCDF
   44   |
[Public]




            DISCLAIMERS AND ATTRIBUTIONS

            The information contained herein is for informational purposes only and is subject to change without notice. While every precaution has been taken in the preparation of this
            document, it may contain technical inaccuracies, omissions and typographical errors, and AMD is under no obligation to update or otherwise correct this
            information. Advanced Micro Devices, Inc. makes no representations or warranties with respect to the accuracy or completeness of the contents of this document, and
            assumes no liability of any kind, including the implied warranties of noninfringement, merchantability or fitness for particular purposes, with respect to the operation or use of
            AMD hardware, software or other products described herein. No license, including implied or arising by estoppel, to any intellectual property rights is granted by this
            document. Terms and limitations applicable to the purchase or use of AMD’s products are as set forth in a signed agreement between the parties or in AMD's Standard Terms
            and Conditions of Sale. GD-18​
            THIS INFORMATION IS PROVIDED ‘AS IS.” AMD MAKES NO REPRESENTATIONS OR WARRANTIES WITH RESPECT TO THE CONTENTS HEREOF AND
            ASSUMES NO RESPONSIBILITY FOR ANY INACCURACIES, ERRORS, OR OMISSIONS THAT MAY APPEAR IN THIS INFORMATION. AMD SPECIFICALLY
            DISCLAIMS ANY IMPLIED WARRANTIES OF NON-INFRINGEMENT, MERCHANTABILITY, OR FITNESS FOR ANY PARTICULAR PURPOSE. IN NO EVENT
            WILL AMD BE LIABLE TO ANY PERSON FOR ANY RELIANCE, DIRECT, INDIRECT, SPECIAL, OR OTHER CONSEQUENTIAL DAMAGES ARISING FROM
            THE USE OF ANY INFORMATION CONTAINED HEREIN, EVEN IF AMD IS EXPRESSLY ADVISED OF THE POSSIBILITY OF SUCH DAMAGES.
            Git and the Git logo are either registered trademarks or trademarks of Software Freedom Conservancy, Inc., corporate home of the Git Project, in the United
            States and/or other countries
            © 2026 Advanced Micro Devices, Inc. All rights reserved.
            AMD, the AMD Arrow logo, Radeon , Instinct , EPYC, Infinity Fabric, ROCm , and combinations thereof are trademarks of Advanced Micro Devices, Inc.
            Other product names used in this publication are for identification purposes only and may be trademarks of their respective companies.
            Git and the Git logo are either registered trademarks or trademarks of Software Freedom Conservancy, Inc., corporate home of the Git Project, in the United
            States and/or other countries
            The OpenMP name and the OpenMP logo are registered trademarks of the OpenMP Architecture Review Board




                April 21-24, 2026                                          AMD Instinct     GPU Training @ HLRS/MPCDF
   45   |
