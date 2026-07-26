---
source: general__rocpd-knowledge-base__amd-public__20260428.pdf
source_mtime: "2026-04-28 16:31:42.510149000 -0500"
pages: 10
extracted_with: "pdftotext -layout (poppler 22.02.0)"
extracted_at: "2026-04-28T16:32:01-05:00"
---

Using rocpd for
performance analysis


      Luka Stanisic and Gina Sitaraman
      February 6, 2026
        Introduction
        What is rocpd?
        • rocpd refers to both a format (SQLite3 database) and a command-line tool for analyzing profiling data
          from rocprofv3 and rocprof-sys


        Why rocpd?
        • Profile your application once, then use rocpd to generate many analysis views from the same database
        • Minimizes profiling stage dependencies


        Where to find more details?
        • HPCTrainingExamples/Rocprofv3/rocpd/README.md
        • rocpd documentation




2   |
        Main commands
        rocpd provides three main options:
        1. convert: transform databases to CSV, PFTrace, or OTF2
        2. summary: generate statistical reports and compare runs
        3. query: execute custom SQL queries (advanced, not covered in this presentation)


        • Helper scripts rocpd2csv, rocpd2pftrace, and rocpd2summary provide shortcuts for common operations
        • For a full list of rocpd options, check rocpd --help




3   |
        Workflow
        Traditional approach:                                       rocpd approach (2-phase approach):

                                                                    # Profile once
                                                                    rocprofv3 --runtime-trace -- ./app


        # Profile to get CSV output                                 # Convert to CSV format
        rocprofv3 --kernel-trace --output-format csv -- ./app       rocpd2csv -i <path>.db
        # Profile to get Perfetto trace output                      # Convert to Perfetto trace format
        rocprofv3 --kernel-trace --output-format pftrace -- ./app   rocpd2pftrace -i <path>.db
        # Generate summary of top kernels                           # Generate summary of top kernels
        rocprofv3 --kernel-trace --stats -- ./app                   rocpd2summary --region-categories KERNEL –i <path>.db
        # Generate summary of top marker regions                    # Generate summary of top marker regions
        rocprofv3 --marker-trace --stats -- ./app                   rocpd2summary --region-categories MARKER -i <path>.db
        # Profile app only for a selected interval                  # Generate analysis only for a selected interval
        rocprofv3 --runtime-trace -P 5:1:0 -- ./app                 rocpd2summary --start 25% --end 75% -i <path>.db
        # Re-profiling 5 times!                                     # All analyses from the same profiling run!


4   |
        A simple profiling workflow
        Using Jacobi Fortran+OpenMP example


        • Collect a profile:
        rocprofv3 --kernel-trace --output-directory omp_dir --output-file f -- ./jacobi -m 1024


        • Collect hotspots list:
        rocpd summary -i omp_dir/f_results.db
                          KERNELS_SUMMARY:
                          Name                               Calls DURATION (nsec) AVERAGE (nsec) PERCENT (INC) MIN (nsec) MAX (nsec) STD_DEV
                          __omp_offloading_30_57b9f__QMnorm_modPnorm_l23
                                                               1001        92043050         91951            42     85520    105080       3300
                          __omp_offloading_30_57b8c__QMlaplacian_modPlaplacian_l22
                                                               1000        49900815         49901            23     26440      58200      2456
                          __omp_offloading_30_57ba0__QMupdate_modPupdate_l22
                                                               1000        48184981         48185            22     31920      57200      4370
                          __omp_offloading_30_57b7d__QMboundary_modPboundary_conditions_l24
                                                               1000        28575181         28575            13     14560      34921      2319




5   |
        Comparing multiple executions or MPI ranks
        rocpd summary -i test1_results.db test2_results.db --summary-by-rank

                 KERNELS_SUMMARY_BY_RANK:
                 ProcessID Hostname        Name                               Calls DURATION (nsec) AVERAGE (nsec) PERCENT (INC) MIN (nsec) MAX (nsec) STD_DEV
        Rank 0      714789 ppac-pl1-s24-26 __omp_offloading_30_57b9f__QMnorm_modPnorm_l23
                                                                                1001        92043050
                    714789 ppac-pl1-s24-26 __omp_offloading_30_57b8c__QMlaplacian_modPlaplacian_l22
                                                                                1000        49900815
                                                                                                             91951
                                                                                                             49901
                                                                                                                              42
                                                                                                                              23
                                                                                                                                     85520
                                                                                                                                     26440
                                                                                                                                              105080
                                                                                                                                                58200
                                                                                                                                                           3300
                                                                                                                                                           2456
                    714789 ppac-pl1-s24-26 __omp_offloading_30_57ba0__QMupdate_modPupdate_l22
                                                                                1000        48184981         48185            22     31920      57200      4370
                    714789 ppac-pl1-s24-26 __omp_offloading_30_57b7d__QMboundary_modPboundary_conditions_l24
                                                                                1000        28575181         28575            13     14560      34921      2319
        Rank 1      715613 ppac-pl1-s24-26 __omp_offloading_30_57ba0__QMupdate_modPupdate_l22
                                                                                1000       256307184
                    715613 ppac-pl1-s24-26 __omp_offloading_30_57b8c__QMlaplacian_modPlaplacian_l22
                                                                                1000       242230476
                                                                                                            256307
                                                                                                            242230
                                                                                                                              38
                                                                                                                              36
                                                                                                                                     40520 4364040 241111
                                                                                                                                     45440 25579602 873616
                    715613 ppac-pl1-s24-26 __omp_offloading_30_57b9f__QMnorm_modPnorm_l23
                                                                                1001       143103160        142960            21     84200 15000641 529300
                    715613 ppac-pl1-s24-26 __omp_offloading_30_57b7d__QMboundary_modPboundary_conditions_l24
                                                                                1000        28032439         28032             4     24720      33200      1788



        Many possible use cases
        • Compare two code versions or setups
        • MPI application performance analysis of different ranks
        • Scaling studies




6   |
        Common pitfalls and how to avoid them
        • Forgetting the -- separator for rocprofv3
          • Always use -- between rocprofv3 options and your application, e.g., rocprofv3 --kernel-trace -- ./app


        • Python version mismatch
          • Use rocpd with the default Python that was used for its installation
          • This strict dependency will be removed in the future ROCm releases


        • No kernel name truncation option
          • rocpd does not currently have an equivalent option to rocprofv3 --truncate-kernels
          • Functionality planned for a future ROCm release


        • Overwriting existing output files
          • Use --output-file with unique names when generating multiple analyses from the same database


        • Not specifying output directory
          • Always use --output-directory for predictable, organized output paths

7   |
        Additional resources
        • rocpd and rocprofv3:
          • rocpd documentation
          • rocprofv3 documentation
          • ROCprofiler-SDK GitHub repository


        • ROCm Systems Profiler
          • rocprof-sys documentation on rocpd output format


        • Related profiling examples
          • rocpd HIP and OpenMP examples
          • ROCprofv3 HIP examples
          • ROCprofv3 OpenMP (Fortran) examples
          • HPCTrainingExamples repository




8   |
        DISCLAIMERS AND ATTRIBUTIONS
        The information contained herein is for informational purposes only and is subject to change without notice. While every precaution has been taken
        in the preparation of this document, it may contain technical inaccuracies, omissions and typographical errors, and AMD is under no obligation to
        update or otherwise correct this information. Advanced Micro Devices, Inc. makes no representations or warranties with respect to the accuracy or
        completeness of the contents of this document, and assumes no liability of any kind, including the implied warranties of noninfringement,
        merchantability or fitness for particular purposes, with respect to the operation or use of AMD hardware, software or other products described
        herein. No license, including implied or arising by estoppel, to any intellectual property rights is granted by this document. Terms and limitations
        applicable to the purchase or use of AMD’s products are as set forth in a signed agreement between the parties or in AMD's Standard Terms and
        Conditions of Sale. GD-18​
        THIS INFORMATION IS PROVIDED ‘AS IS.” AMD MAKES NO REPRESENTATIONS OR WARRANTIES WITH RESPECT TO THE
        CONTENTS HEREOF AND ASSUMES NO RESPONSIBILITY FOR ANY INACCURACIES, ERRORS, OR OMISSIONS THAT MAY
        APPEAR IN THIS INFORMATION. AMD SPECIFICALLY DISCLAIMS ANY IMPLIED WARRANTIES OF NON-INFRINGEMENT,
        MERCHANTABILITY, OR FITNESS FOR ANY PARTICULAR PURPOSE. IN NO EVENT WILL AMD BE LIABLE TO ANY PERSON FOR
        ANY RELIANCE, DIRECT, INDIRECT, SPECIAL, OR OTHER CONSEQUENTIAL DAMAGES ARISING FROM THE USE OF ANY
        INFORMATION CONTAINED HEREIN, EVEN IF AMD IS EXPRESSLY ADVISED OF THE POSSIBILITY OF SUCH DAMAGES.
        © 2026 Advanced Micro Devices, Inc. All rights reserved.
        AMD, the AMD Arrow logo, Radeon , Instinct , EPYC, Infinity Fabric, ROCm , and combinations thereof are trademarks of Advanced
        Micro Devices, Inc. Other product names used in this publication are for identification purposes only and may be trademarks of their
        respective companies.
        The OpenMP name and the OpenMP logo are registered trademarks of the OpenMP Architecture Review Board
        Windows is a registered trademark of Microsoft Corporation in the US and/or other countries.
        Git and the Git logo are either registered trademarks or trademarks of Software Freedom Conservancy, Inc., corporate home of the Git
        Project, in the United States and/or other countries
        Intel is a trademark of Intel Corporation or its subsidiaries




9   |
