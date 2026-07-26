---
source: general__rocprofv3-rocprof-sys-knowledge-base__amd-public__20260428.pdf
source_mtime: "2026-04-28 15:22:04.219352000 -0500"
pages: 42
extracted_with: "pdftotext -layout (poppler 22.02.0)"
extracted_at: "2026-04-28T15:22:54-05:00"
---

GPU Timeline Profiling

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




            AMD has three main GPU profiling tools



                                                                                               rocprof-compute
                                                                                         GPU kernel performance analysis



                        rocprofv3                                     rocprof-sys
             GPU tracing and counter collection                    GPU and CPU tracing




                       librocprofiler-sdk library - tracing and profiling infrastructure for developing tools




              April 21-24, 2026                     AMD Instinct   GPU Training @ HLRS/MPCDF
    4   |
[Public]




            What is rocprofv3?

            • Performance analysis tool for ROCm based applications (single or multi process)


            • Main capabilities:
              • GPU hotspot analysis – identify performance bottlenecks
              • Device activity tracing – visualize HIP, HSA , GPU kernels, and data transfers a GUI
              • Performance counter collection – analyze kernel performance further


            • Supports Python       and OpenMP® offload profiling


            • Documented at: https://rocm.docs.amd.com/projects/rocprofiler-sdk/en/latest/how-to/using-rocprofv3.html




               April 21-24, 2026                       AMD Instinct   GPU Training @ HLRS/MPCDF
    5   |
[Public]




            Running rocprofv3 with single and multiple processes

            • rocprofv3 requires double-hyphen (--) before the application to be executed:
              • $ rocprofv3 [<rocprofv3-options> ...] -- <application> [<application-args> ...]
              • $ rocprofv3 --runtime-trace -- ./myapp -n 1




            • For MPI applications or if using Slurm, place rocprofv3 inside the job launcher:
              • $ mpirun -np 4 rocprofv3 --runtime-trace -- ./mympiapp
              • Output files will be generated for each MPI process automatically




               NOTE: rocprofv3 can run with MPI but it does not trace MPI calls




               April 21-24, 2026                  AMD Instinct   GPU Training @ HLRS/MPCDF
    7   |
[Public]




            rocprofv3: Collecting application traces

            • rocprofv3 can collect a variety of trace event types and generate timelines        Can combine options in a run

               Trace Event                                                     rocprofv3 Trace Mode
               Collect HIP, Kernels, Memory Copy, Marker API                   --runtime-trace
               GPU Kernels (including OpenMP offload)                          --kernel-trace
               HIP API call                                                    --hip-trace
               Host <-> Device Memory copies                                   --hip-trace or --memory-copy-trace
               User code markers                                               --marker-trace
               CPU HSA Calls                                                   --hsa-trace
               Kokkos calls                                                    --kokkos-trace
               Collect HSA, HIP, Kernels, Memory Copy, Marker API              --sys-trace

            • For timeline traces pftrace output format (--output-format pftrace) currently recommended
            • Starting from ROCm 7, csv not default anymore, so need --output-format csv
               April 21-24, 2026                  AMD Instinct   GPU Training @ HLRS/MPCDF
    8   |
[Public]




            rocprofv3: Collecting GPU hotspots

            $ rocprofv3 --stats --kernel-trace --truncate-kernels --summary -- <app with arguments>
                                   Combine --stats             Truncate kernel               Print hotspot summary
                                   with --kernel-trace         names, remove args            on the console


            • GPU kernel hotspots summary in XXXXX_kernel_stats.csv
              • Use --output-file --output-directory to control output file name




            • Might be easier to read with a spreadsheet viewer:​




               April 21-24, 2026                         AMD Instinct   GPU Training @ HLRS/MPCDF
    9   |
[Public]




            rocprofv3: Collecting hardware counters

            • rocprofv3 can collect a number of hardware counters and derived counters
              • $ rocprofv3 -L


            • To collect, specify counters in an input file:
              • $ rocprofv3 -i rocprof_counters.txt -- <app with args>
              • $ cat rocprof_counters.txt                                                                      One pass per pmc line
                pmc: VALUUtilization VALUBusy FetchSize WriteSize MemUnitStalled
                pmc: GPU_UTIL CU_OCCUPANCY MeanOccupancyPerCU MeanOccupancyPerActiveCU                          Hardware limits on how
                                                                                                                many counters can be
                                                                                                                collected in one pass
            • Or specify on command line:
              • $ rocprofv3 --pmc VALUUtilization FetchSize -- <app with args>


            • In the <pid>_counter_collection.csv output file:
              2,2,8,2,43371,43371,16384,18,"NormKernel1",128,1024,0,12,4,32,"FetchSize",131073.625000,116935428165636,116935428564998
              2,2,8,2,43371,43371,16384,18,"NormKernel1",128,1024,0,12,4,32,"VALUUtilization",99.962183,116935428165636,116935428564998

                                                                                                            Value of metric
             Dispatch ID
                                                         One line per metric per kernel invocation
               April 21-24, 2026                         AMD Instinct   GPU Training @ HLRS/MPCDF
   10   |
[Public]


                                                                                                                    Trace from Fortran +
            Visualizing application traces with Perfetto                                                            OpenMP® offload code


            • $ rocprofv3 --sys-trace --output-format pftrace -- <app with arguments>
            • This outputs a pftrace file that can be visualized using Perfetto (https://ui.perfetto.dev/) in Chrome




                                                                                                                             HIP and
                                                                                                                             HSA activity



                                                                                                                              GPU activity


               April 21-24, 2026                    AMD Instinct   GPU Training @ HLRS/MPCDF
   11   |                                                                                      Copy activity (H2D and D2H)
[Public]




            Perfetto: Navigating through traces

            • Zoom in to see individual events
            • Navigate trace using WASD keys




                                   OpenMP® offload visualization shown here


               April 21-24, 2026                       AMD Instinct   GPU Training @ HLRS/MPCDF
   12   |
[Public]




            Perfetto: Kernel information and flow events

            • Zoom and select a kernel, you can see the link to the HIP call launching the kernel
            • Try to open the information for the kernel (button at bottom right)




               April 21-24, 2026                    AMD Instinct   GPU Training @ HLRS/MPCDF
   13   |
[Public]




            Perfetto: Viewing function metadata

            • Detailed information about selected kernel​
            • Can navigate to preceding or following flows, and obtain more info with contextual options

                                                Kernel name

                                                                                    Preceding event
                                                                                                                  Additional info



                                   Duration




                                                                                                      Workgroup size
                                                                                                      and grid size



               April 21-24, 2026                   AMD Instinct   GPU Training @ HLRS/MPCDF
   14   |
[Public]




            rocprofv3: Collecting application traces with roctx markers and regions

            • Annotate code with roctx regions:

              #include <rocprofiler-sdk-roctx/roctx.h>
              ...                                                                               roctx range
                  roctxRangePush("reduce_for_c");
                  // some code
                  roctxRangePop();
              ...

            • Annotate code with roctx markers:
              ...
                  roctxMark("start of some code");
                  // some_code                                Note: similar approach for Fortran codes,
                  roctxMark("end of some code");              check HPCTrainingExamples/HIPFort/roctx
              ...

            • Link with rocprofiler-sdk-roctx library:
                  -L${ROCM_PATH}/lib –lrocprofiler-sdk-roctx


            • Profile with --hip-trace --marker-trace or options that includes them (e.g., --sys-trace):
                   $ rocprofv3 --hip-trace --marker-trace -- <app with arguments>

              April 21-24, 2026                      AMD Instinct   GPU Training @ HLRS/MPCDF
   15   |
[Public]




            Merge traces from multiple MPI ranks

            •   $ cat *_results.pftrace > merged.pftrace
            •   Then visualize merged.pftrace in Perfetto


   Rank 0




   Rank 1




   Ranks
   2 and 3

                April 21-24, 2026                AMD Instinct   GPU Training @ HLRS/MPCDF
   17   |
[Public]




            Profiling overhead

            • rocprofv3 is designed for minimal profiling overhead


            • The percentage of overhead depends on:
              • The profiling options used (e.g., tracing is faster than hardware counter collection)
              • The number of counters you collect (multiple passes for multiple pmc lines)
              • Whether roctx regions/markers are collected (can result in large traces too)


            • The more data collected, the more the overhead of profiling


            • To minimize collected data, profile only the small (interesting) region of the execution
              • Use --collection-period (START_DELAY_TIME):(COLLECTION_TIME):(REPEAT) added in ROCm 6.4
              • Possibly combined with: --collection-period-unit {hour,min,sec,msec,usec,nsec} (default sec)
              • $ rocprofv3 --collection-period 3:3:1 --sys-trace -- <app with args>




               April 21-24, 2026                        AMD Instinct   GPU Training @ HLRS/MPCDF
   18   |
[Public]




            AMD has three main GPU profiling tools



                                                                                               rocprof-compute
                                                                                         GPU kernel performance analysis



                        rocprofv3                                     rocprof-sys
             GPU tracing and counter collection                    GPU and CPU tracing




                       librocprofiler-sdk library - tracing and profiling infrastructure for developing tools




              April 21-24, 2026                     AMD Instinct   GPU Training @ HLRS/MPCDF
   19   |
[Public]




            ROCm Systems Profiler (rocprof-sys)

            • Profiling and comprehensive tracing of applications on CPU and GPU
            • Several data collection modes: sampling, dynamic instrumentation, binary rewrite, causal profiling, etc.
            • Collect CPU and GPU metrics
            • Visualization format: protobuf files (.proto) viewed in Perfetto
            $ rocprof-sys-run --profile --trace -- <app with arguments>




               April 21-24, 2026                   AMD Instinct   GPU Training @ HLRS/MPCDF
   20   |
[Public]




            Typical rocprof-sys workflow


                                                                                                    Collect trace
                 Create run-time config                      Instrument binary                   rocprof-sys-run --
                (optional, one-time only)                        (optional)                          ./app.inst
                                                          rocprof-sys-instrument                        (or)
                  rocprof-sys-avail -G
                                                           -o app.inst -- <app>                mpirun -np 4 rocprof-
                                                                                               sys-run -- ./app.inst




            •    rocprof-sys documentation: https://rocm.docs.amd.com/projects/rocprofiler-systems/en/latest/index.html

            •    Run-time configuration parameters: https://rocm.docs.amd.com/projects/rocprofiler-systems/en/latest/how-
                 to/configuring-runtime-options.html




                 April 21-24, 2026                  AMD Instinct   GPU Training @ HLRS/MPCDF
   21   |
[Public]




            rocprof-sys: Configuration file (optional)

            Create a config file in $HOME:
              $ rocprof-sys-avail -G $HOME/.rocprofsys.cfg

            Modify the config file to tune runtime settings:

            <snip>




            <snip>
                                                                           Contents of the config file
            Declare which config file to use by setting the environment:

              $ export ROCPROFSYS_CONFIG_FILE=$HOME/.rocprofsys.cfg



            • Configuration can be performed in different ways (be careful as options may be specific to tool version):
              • ROCPROFSYS_USE_OMPT=true in config file | export ROCPROFSYS_USE_OMPT=true | --include ompt

               April 21-24, 2026                                AMD Instinct   GPU Training @ HLRS/MPCDF
   22   |
[Public]




            rocprof-sys: Binary rewrite (optional)

             Binary Rewrite
              $ rocprof-sys-instrument [options] -o <new-name-of-exec>
             -- <CMD> <ARGS>

             Generating a new executable/library with instrumentation built-in:
              $ rocprof-sys-instrument -o Jacobi_hip.inst --
             ./Jacobi_hip

              This new binary will have instrumented functions



            Subroutine Instrumentation
            Default instrumentation is main function and functions of 1024
            instructions and more (for CPU)

            To instrument routines with 500 or more cycles, add option "-i 500"
            (more overhead)                                                                                     Path to new instrumented binary



            • Not needed for every profiling (e.g., basic OpenMP®), but useful when more control is required
              • Select a subset of functions to be profiled using --function-include ‘kernel_A’ ‘kernel_B'

               April 21-24, 2026                                     AMD Instinct   GPU Training @ HLRS/MPCDF
   23   |
[Public]




            rocprof-sys: Run instrumented binary

             Binary Rewrite
              $ rocprof-sys-instrument [options] -o <new-name-of-exec>
             -- <CMD> <ARGS>

             Generating a new executable/library with instrumentation built-in:
              $ rocprof-sys-instrument -o Jacobi_hip.inst --
             ./Jacobi_hip
              Run the instrumented binary:​
              $ mpirun -np 1 rocprof-sys-run -- ./Jacobi_hip.inst -g 1
             1

                                                                                                                Generates traces for application run
            To instrument routines with 500 or more instructions, add option "-i
            500"

            Binary rewrite is recommended for runs with multiple ranks as
            rocprof-sys produces separate output files for each rank



            • Path to your output trace is printed by rocprof-sys-run at the end of the run:


                 April 21-24, 2026                                   AMD Instinct   GPU Training @ HLRS/MPCDF
   24   |
[Public]




            rocprof-sys: Kernel durations

            $ cat rocprofsys-Jacobi_hip.inst-output/2025-01-21_07.40/wall_clock-0.txt
            Enable ROCPROFSYS_PROFILE in your config file
            …
            ROCPROFSYS_PROFILE                                           = true
            …
            then re-run. Alternatively, prepend ROCPROFSYS_PROFILE=true to the mpirun command or use --profile
                                                                                                                 Durations




                                                      Call Stack




            • Function calls made in the code, their count, total duration in seconds and other stats




                April 21-24, 2026                               AMD Instinct   GPU Training @ HLRS/MPCDF
   25   |
[Public]




            rocprof-sys: Kernel durations – flat profile
            Edit your config file (or prepend to your mpirun command):
            ROCPROFSYS_PROFILE                                            = true        Use flat profile to see aggregate duration of kernels and
            ROCPROFSYS_FLAT_PROFILE                                       = true        functions




               April 21-24, 2026                                   AMD Instinct    GPU Training @ HLRS/MPCDF
   26   |
[Public]




            Visualizing trace (1/3)
            Use Perfetto
            Copy perfetto-trace-0.proto to your laptop, go to https://ui.perfetto.dev/, click "Open trace file", select perfetto-trace-0.proto




                                                                                                                       Traces of CPU functions




                                CPU metrics


               April 21-24, 2026                                   AMD Instinct   GPU Training @ HLRS/MPCDF
   27   |
[Public]




            Visualizing trace (2/3)
            Use Perfetto
            Zoom in to investigate regions of interest




                                                                                                    Zoomed in




                April 21-24, 2026                        AMD Instinct   GPU Training @ HLRS/MPCDF
   28   |
[Public]




            Visualizing trace (3/3)

            Use Perfetto
            Investigate interactions between CPU and GPU




                                                              Flow Events




                                    Select metrics of interest to view
                                    close together




                         GPU characteristics

   29   |
[Public]




            rocprof-sys: Study overlap between compute & communication




                                 Pin most important CPU and
                                 GPU row to the top




             April 21-24, 2026                         AMD Instinct   GPU Training @ HLRS/MPCDF
   30   |
[Public]




            rocprof-sys: Study concurrent kernels (Stream_Overlap)

            • Example of GPU kernels launched into multiple HIP streams




            • Good overlap between multiple streams saves multifold total compute time

                cd /path/to/HPCTrainingExamples/HIP/Stream_Overlap/0-Orig
                mkdir build; cd build; cmake ..; make –j

                ./compute_comm_overlap <nstreams> <block size (optional, default: 64)>
                rocprof-sys-instrument -o compute_comm_overlap.inst -- compute_comm_overlap
                rocprof-sys-run -- ./compute_comm_overlap.inst <nstreams>

               April 21-24, 2026                         AMD Instinct   GPU Training @ HLRS/MPCDF
   31   |
[Public]




            rocprof-sys: Sampling CPU call-stack

            • ROCPROFSYS_USE_SAMPLING = true; ROCPROFSYS_SAMPLING_FREQ = 100 (100 samples per second)
            • Alternatively run with rocprof-sys-sample




                                                                                                          Each sample shows the
                                                                                                          call stack at that time



                                                 Scroll down all the way in Perfetto to see the sampling output


               April 21-24, 2026                AMD Instinct   GPU Training @ HLRS/MPCDF
   32   |
[Public]




            rocprof-sys: Network performance profiling (from ROCm 6.4)

            •   First identify NIC information: rocprof-sys-avail -H -r net
                     |---------------------------------|---------|-----------|---------------------------------|
                     |        HARDWARE COUNTER         | DEVICE | AVAILABLE |              SUMMARY             |
                     |---------------------------------|---------|-----------|---------------------------------|

                     ...
                     | net:::hsn0:rx:byte             |   CPU    |    true     | hsn0 receive byte             |
                     | net:::hsn0:rx:packet           |   CPU    |    true     | hsn0 receive packet           |
                     | net:::hsn0:rx:error            |   CPU    |    true     | hsn0 receive error            |


            •   Set up parameters for profiling:
                                                                             Collecting PAPI counters requires
                                                                             /proc/sys/kernel/perf_event_paranoid to be <= 2
                     ROCPROFSYS_NETWORK_INTERFACE=hsn0
                     ROCPROFSYS_PAPI_EVENTS=net:::hsn0:rx:byte net:::hsn0:rx:packet net:::hsn0:tx:byte net:::hsn0:tx:packet
                     ROCPROFSYS_TIMEMORY_COMPONENTS=wall_clock network_stats


            •   Before ROCm 7.2, CPU sampling had to be enabled:
                     ROCPROFSYS_USE_SAMPLING=true


                April 21-24, 2026                          AMD Instinct   GPU Training @ HLRS/MPCDF
   34   |
[Public]




            rocprof-sys: Tips & tricks

            •   If rocprof-sys does nothing – check app or environment
                •     Did you forget to add “--” between rocprof-sys-* and <app>?
                •     In a Slurm environment, sometimes incorrect order of loading libraries at runtime causes unexpected behavior
                •     If application fails when running with sbatch, try profiling interactively


            •   Perfetto visualization has known limitations
                •     Max file size 4GB
                •     To visualize large .proto files (approx. >1GB), load into memory first using Perfetto’s trace_processor
                •     If the latest Perfetto UI does not work, try the older version https://ui.perfetto.dev/v46.0-35b3d9845/#!/
                •     Consider ROCm Optiq shown later in the slides


            •   Disable options not useful for your analysis (e.g., ROCPROFSYS_SAMPLING_CPUS=none in older ROCm)




                    April 21-24, 2026                       AMD Instinct   GPU Training @ HLRS/MPCDF
   36   |
[Public]




            rocprof-sys: Additional features

            •   Dynamic runtime instrumentation to instrument dependent libraries too
            •   ROCPROFSYS_USE_KOKKOSP=true supports Kokkos profiling
            •   rocprof-sys-causal for causal profiling (experimental)
            •   User API to control instrumentation


            •   Changelog and release notes for reference: https://github.com/ROCm/rocm-
                systems/blob/develop/projects/rocprofiler-systems/CHANGELOG.md




                April 21-24, 2026                     AMD Instinct   GPU Training @ HLRS/MPCDF
   37   |
[Public]




            News since last year

            •   Several major and numerous minor ROCm releases and pre-releases: 7.0, 7.1, 7.2


            •   New features in presented tools:
                •     rocprofv3
                •     rocprof-sys


            •   New tools:
                • rocpd
                • ROCm Optiq


            • Showing highlights from an HPC engineer perspective, for a full list see ROCm release notes




                    April 21-24, 2026              AMD Instinct   GPU Training @ HLRS/MPCDF
   38   |
[Public]




            rocprofv3/rocprofiler-sdk: New features

            • rocpd support: support introduced in ROCm 7.0, see rocpd slide later for more details


            • Thread traces: support introduced in ROCm 7.0, see Thread Trace slide in the next presentation
              • ROCprof Trace Decoder


            • PC (Program Counter) sampling: identifying GPU code hotspots, support introduced in ROCm 7.0
              • https://rocm.docs.amd.com/projects/rocprofiler-sdk/en/latest/how-to/using-pc-sampling.html


            • Dynamic process attachment: attach rocprofv3 to already running process
              • https://rocm.docs.amd.com/projects/rocprofiler-sdk/en/latest/how-to/using-rocprofv3-process-attachment.html


            • Scratch-memory trace information


            • Python       bindings for rocprofiler-sdk-roctx markers

               April 21-24, 2026                      AMD Instinct   GPU Training @ HLRS/MPCDF
   39   |
[Public]




            rocprof-sys: New features

            • rocpd support: introduced in ROCm 7.1, see rocpd slide later for more details


            • Improved support for profiling Fortran (MPI, OpenMP®), Python            (PyTorch AI) and communication (RCCL)


            • ROCPROFSYS_ROCM_GROUP_BY_QUEUE: allows grouping of events by hardware queue


            Available in ROCm pre-releases (a.k.a “TheRock”), coming soon to the official releases:
            • ROCPROFSYS_TRACE_REGION: selective region tracing


            • Pause and resume profiling: through the roctxProfilerPause and roctxProfilerResume


            • Built-in presets covering common profiling scenarios (e.g., --trace-hpc, --workload-trace)




               April 21-24, 2026                  AMD Instinct   GPU Training @ HLRS/MPCDF
   40   |
[Public]




            rocpd

            What is rocpd?
            • rocpd refers to both a format (SQLite3 database) and a command-line tool for analyzing profiling data
              from rocprofv3 and rocprof-sys


            Why rocpd?
            • Profile your application once, then use rocpd to generate many analysis views from the same database
            • Minimizes profiling stage dependencies


            What can rocpd do?
            • convert: transform databases to CSV, PFTrace, or OTF2​
            • summary: generate statistical reports and compare runs​ or MPI ranks
            • query: execute custom SQL queries
                                                                             NOTE: Until ROCm 7.2 Python dependency
                                                                             installation issues on some systems
            Where to find more details?
            • HPCTrainingExamples/Rocprofv3/rocpd/README.md / rocpd documentation
   41   |
[Public]




            ROCm Optiq

            What is ROCm Optiq?
            • New stand-alone visualizer for the ROCm profiler tools
            • Not part of ROCm (yet), need a separate installation


            Why ROCm Optiq?
            • Circumvent known Perfetto limitations
            • Allow more customized analysis of apps running on AMD GPUs


            What can ROCm Optiq do?
            • Visualize rocpd trace from rocprof* profilers
            • Works on Windows®, Ubuntu®, RHEL® (more OSs coming)


            Where to find more details?
            • ROCm Optiq documentation
               April 21-24, 2026                  AMD Instinct   GPU Training @ HLRS/MPCDF
   42   |
[Public]




            Summary

            • rocprofv3: CLI tool to quickly analyze GPU activity on AMD GPUs
              •     Hotspot analysis – identify performance bottlenecks
              •     Application tracing – visualize HIP, HSA and device activity in a GUI
              •     Performance counter collection – analyze kernel performance further


            • rocprof-sys: Powerful tool to understand GPU + CPU activity
              •     Ideal for an initial look at how an application runs
              •     Analyze overlaps between CPU/GPU compute and communication
              •     Obtain a comprehensive trace with system characteristics




                  April 21-24, 2026                      AMD Instinct   GPU Training @ HLRS/MPCDF
   43   |
[Public]




            Additional resources

            • Introduction to profiling tools for AMD hardware:
                •   https://rocm.blogs.amd.com/software-tools-optimization/profilers/README.html


            • Three-part profiling guide on ROCm blogs:
                •   Intro: https://rocm.blogs.amd.com/software-tools-optimization/profiling-guide/intro/README.html
                •   Novice: https://rocm.blogs.amd.com/software-tools-optimization/profiling-guide/novice/README.html
                •   Advanced: https://rocm.blogs.amd.com/software-tools-optimization/profiling-guide/advanced/README.html




               April 21-24, 2026                     AMD Instinct   GPU Training @ HLRS/MPCDF
   44   |
[Public]




            Hands-on exercises

            • Located in our HPC Training Examples repo: https://github.com/amd/HPCTrainingExamples


            • rocprofv3 exercises:
              • Rocprofv3/OpenMP/README.md
              • Rocprofv3/HIP/README.md


            • rocprof-sys exercises:
              • rocprofiler-systems/Jacobi/OpenMP/CXX
              • rocprofiler-systems/Jacobi/README.md


            • Exercises generic for a large range of AMD GPUs and ROCm versions


            • Recommended module on AAC6: module load rocm/7.2.0
              • Temporary issues with rocprof-sys-run for MPI apps due to recent software updates
            • Recommended module on AAC7: module swap rocm rocm-new/7.2.0

               April 21-24, 2026                    AMD Instinct   GPU Training @ HLRS/MPCDF
   45   |
[Public]




            DISCLAIMERS AND ATTRIBUTIONS
            The information contained herein is for informational purposes only and is subject to change without notice. While every precaution has been taken in the
            preparation of this document, it may contain technical inaccuracies, omissions and typographical errors, and AMD is under no obligation to update or otherwise
            correct this information. Advanced Micro Devices, Inc. makes no representations or warranties with respect to the accuracy or completeness of the contents of this
            document, and assumes no liability of any kind, including the implied warranties of noninfringement, merchantability or fitness for particular purposes, with respect
            to the operation or use of AMD hardware, software or other products described herein. No license, including implied or arising by estoppel, to any intellectual
            property rights is granted by this document. Terms and limitations applicable to the purchase or use of AMD’s products are as set forth in a signed agreement
            between the parties or in AMD's Standard Terms and Conditions of Sale. GD-18​
            THIS INFORMATION IS PROVIDED ‘AS IS.” AMD MAKES NO REPRESENTATIONS OR WARRANTIES WITH RESPECT TO THE CONTENTS
            HEREOF AND ASSUMES NO RESPONSIBILITY FOR ANY INACCURACIES, ERRORS, OR OMISSIONS THAT MAY APPEAR IN THIS
            INFORMATION. AMD SPECIFICALLY DISCLAIMS ANY IMPLIED WARRANTIES OF NON-INFRINGEMENT, MERCHANTABILITY, OR FITNESS FOR
            ANY PARTICULAR PURPOSE. IN NO EVENT WILL AMD BE LIABLE TO ANY PERSON FOR ANY RELIANCE, DIRECT, INDIRECT, SPECIAL, OR
            OTHER CONSEQUENTIAL DAMAGES ARISING FROM THE USE OF ANY INFORMATION CONTAINED HEREIN, EVEN IF AMD IS EXPRESSLY
            ADVISED OF THE POSSIBILITY OF SUCH DAMAGES.
            © 2026 Advanced Micro Devices, Inc. All rights reserved.
            AMD, the AMD Arrow logo, Radeon , Instinct , EPYC, Infinity Fabric, ROCm , and combinations thereof are trademarks of Advanced Micro
            Devices, Inc. Other product names used in this publication are for identification purposes only and may be trademarks of their respective companies.

            The OpenMP name and the OpenMP logo are registered trademarks of the OpenMP Architecture Review Board
            Windows is a registered trademark of Microsoft Corporation in the US and/or other countries.
            Ubuntu and the Ubuntu logo are registered trademarks of Canonical Ltd.
            Red Hat and the Shadowman logo are registered trademarks of Red Hat, Inc. www.redhat.com in the U.S. and other countries.​
            Linux is the registered trademark of Linus Torvalds in the U.S. and other countries.​
            Git and the Git logo are either registered trademarks or trademarks of Software Freedom Conservancy, Inc., corporate home of the Git Project, in the
            United States and/or other countries.


               April 21-24, 2026                                     AMD Instinct   GPU Training @ HLRS/MPCDF
   46   |
