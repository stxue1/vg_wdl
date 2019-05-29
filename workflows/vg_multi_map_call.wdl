version 1.0

#version draft-2
# Apparently cromwell 36.1 doesn't parse the version line in wdl files if the wdl version is a draft version.
# Cromwell 36.1 wdl parser defaults to draft-2 if a `version` line is not given.
# https://gatkforums.broadinstitute.org/wdl/discussion/15519/escape-characters-in-draft-2-v-1-0

# Working example pipeline which uses VG to map and HaplotypeCaller to call variants.   
# Tested on Googles Cloud Platorm "GCP" and works for VG container "quay.io/vgteam/vg:v1.11.0-215-ge5edc43e-t246-run".  
# WDL pipeline works with JSON input file "vg_pipeline.workingexample.inputs_tiny.json" 
# Steps in pipeline:    
# 1) Split reads into chunks.   
#    500 READS_PER_CHUNK value recommended for HG002 tiny chr 21 dataset    
#      "gs://cmarkell-vg-wdl-dev/HG002_chr21_1.tiny.fastq.gz" and "gs://cmarkell-vg-wdl-dev/HG002_chr21_2.tiny.fastq.gz".   
#    1000000 READS_PER_CHUNK value recommended for HG002 whole chr 21 dataset   
#      "gs://cmarkell-vg-wdl-dev/HG002_chr21_1.fastq.gz" and "gs://cmarkell-vg-wdl-dev/HG002_chr21_2.fastq.gz". 
# 2) Align input paired-end reads to a VG graph using either VG MAP or VG MPMAP algorithms.
#    Set vgPipeline.VGMPMAP_MODE to "true" to run the VG MPMAP algorithm on the read set.
#    Set vgPipeline.VGMPMAP_MODE to "false" to run the VG MAP algorithm on the read set.
# Either run GATK's HaplotypeCaller or use the graph-backed caller "VG Call".
#    Set vgPipeline.SURJECT_MODE to "true" to run HaplotypeCaller or the Dragen modules caller on alignments.
#       3) Surject VG alignments from GAM format to BAM format.
#       4) Merge chunked BAM alignments and preprocess them for GATK compatibility.
#       Either run HaplotypeCaller or use the Dragen module caller on the NIH Biowulf system.
#           Set vgPipeline.RUN_DRAGEN_CALLER to "false" to run GATKs HaplotypeCaller on alignments.
#               5) Run GATK HaplotypeCaller on processed BAM data.
#           Set vgPipeline.RUN_DRAGEN_CALLER to "true" to run the Dragen modules caller on alignments.
#           (Currently only works on NIH Biowulf system)
#               5) Run Dragen variant caller on processed BAM data.
#    Set vgPipeline.SURJECT_MODE to "false" to run VG Call on alignments.   
#       3) Merge graph alignments into a single GAM file
#       4) Chunk GAM file by path names as specified by the "vgPipeline.PATH_LIST_FILE"
#          vgPipeline.PATH_LIST_FILE is a text file that lists path names one per row.
#       5) Run VG Call on GAM files chunked by path name
#          Requires vgPipeline.PATH_LENGTH_FILE which is a text file that lists a tab-delimited set of path names and path lengths
#             one per row.
#       6) Merge VCFs then compress and index the merged VCF.

workflow vgMultiMapCall {
    input {
        Boolean? RUN_VGMPMAP_ALGORITHM
        Boolean VGMPMAP_MODE = select_first([RUN_VGMPMAP_ALGORITHM, true])
        Boolean? RUN_LINEAR_CALLER
        Boolean SURJECT_MODE = select_first([RUN_LINEAR_CALLER, true])
        Boolean? RUN_DRAGEN_CALLER
        Boolean DRAGEN_MODE = select_first([RUN_DRAGEN_CALLER, false])
        Boolean? RUN_GVCF_OUTPUT
        Boolean GVCF_MODE = select_first([RUN_GVCF_OUTPUT, false])
        Boolean? RUN_SNPEFF_ANNOTATION
        Boolean SNPEFF_ANNOTATION = select_first([RUN_SNPEFF_ANNOTATION, true])
        Boolean? RUN_SV_CALLER
        Boolean SV_CALLER_MODE = select_first([RUN_SV_CALLER, false])
        Boolean? GOOGLE_STORE_CLEANUP
        Boolean GOOGLE_CLEANUP_MODE = select_first([GOOGLE_STORE_CLEANUP, false])
        File INPUT_READ_FILE_1
        File INPUT_READ_FILE_2
        String SAMPLE_NAME
        String VG_CONTAINER
        Int READS_PER_CHUNK
        Int CHUNK_BASES
        Int OVERLAP
        File? PATH_LIST_FILE
        File XG_FILE
        File GCSA_FILE
        File GCSA_LCP_FILE
        File? GBWT_FILE
        File? SNARLS_FILE
        File REF_FILE
        File REF_INDEX_FILE
        File REF_DICT_FILE
        File SNPEFF_DATABASE
        Int SPLIT_READ_CORES
        Int SPLIT_READ_DISK
        Int MAP_CORES
        Int MAP_DISK
        Int MAP_MEM
        Int MERGE_GAM_CORES
        Int MERGE_GAM_DISK
        Int MERGE_GAM_MEM
        Int MERGE_GAM_TIME
        Int CHUNK_GAM_CORES
        Int CHUNK_GAM_DISK
        Int CHUNK_GAM_MEM
        Int VGCALL_CORES
        Int VGCALL_DISK
        Int VGCALL_MEM
        String DRAGEN_REF_INDEX_NAME
        String UDPBINFO_PATH
        String HELIX_USERNAME
    }
    
    # Split input reads into chunks for parallelized mapping
    call splitReads as firstReadPair {
        input:
            in_read_file=INPUT_READ_FILE_1,
            in_pair_id="1",
            in_vg_container=VG_CONTAINER,
            in_reads_per_chunk=READS_PER_CHUNK,
            in_split_read_cores=SPLIT_READ_CORES,
            in_split_read_disk=SPLIT_READ_DISK
    }
    call splitReads as secondReadPair {
        input:
            in_read_file=INPUT_READ_FILE_2,
            in_pair_id="2",
            in_vg_container=VG_CONTAINER,
            in_reads_per_chunk=READS_PER_CHUNK,
            in_split_read_cores=SPLIT_READ_CORES,
            in_split_read_disk=SPLIT_READ_DISK
    }
    
    # Extract path names and path lengths from xg file if PATH_LIST_FILE input not provided
    call extractPathNames {
        input:
            in_xg_file=XG_FILE,
            in_vg_container=VG_CONTAINER
    }
    File pipeline_path_list_file = select_first([PATH_LIST_FILE, extractPathNames.output_path_list])
    
    ################################################################
    # Distribute vg mapping opperation over each chunked read pair #
    ################################################################
    Array[Pair[File,File]] read_pair_chunk_files_list = zip(firstReadPair.output_read_chunks, secondReadPair.output_read_chunks)
    scatter (read_pair_chunk_files in read_pair_chunk_files_list) {
        if (VGMPMAP_MODE) {
            call runVGMPMAP {
                input:
                    in_left_read_pair_chunk_file=read_pair_chunk_files.left,
                    in_right_read_pair_chunk_file=read_pair_chunk_files.right,
                    in_vg_container=VG_CONTAINER,
                    in_xg_file=XG_FILE,
                    in_gcsa_file=GCSA_FILE,
                    in_gcsa_lcp_file=GCSA_LCP_FILE,
                    in_gbwt_file=GBWT_FILE,
                    in_snarls_file=SNARLS_FILE,
                    in_sample_name=SAMPLE_NAME,
                    in_map_cores=MAP_CORES,
                    in_map_disk=MAP_DISK,
                    in_map_mem=MAP_MEM
            }
        } 
        if (!VGMPMAP_MODE) {
            call runVGMAP {
                input:
                    in_left_read_pair_chunk_file=read_pair_chunk_files.left,
                    in_right_read_pair_chunk_file=read_pair_chunk_files.right,
                    in_vg_container=VG_CONTAINER,
                    in_xg_file=XG_FILE,
                    in_gcsa_file=GCSA_FILE,
                    in_gcsa_lcp_file=GCSA_LCP_FILE,
                    in_gbwt_file=GBWT_FILE,
                    in_sample_name=SAMPLE_NAME,
                    in_map_cores=MAP_CORES,
                    in_map_disk=MAP_DISK,
                    in_map_mem=MAP_MEM
            }
        }
        
        # Surject GAM alignment files to BAM if SURJECT_MODE set to true
        File vg_map_algorithm_chunk_gam_output = select_first([runVGMAP.chunk_gam_file, runVGMPMAP.chunk_gam_file])
        # Cleanup input reads after use
        if (GOOGLE_CLEANUP_MODE) {
            call cleanUpGoogleFilestore as cleanUpVGMapperInputsGoogle {
                input:
                    previous_task_outputs = [read_pair_chunk_files.left, read_pair_chunk_files.right],
                    current_task_output = vg_map_algorithm_chunk_gam_output
            }
        }
        if (!GOOGLE_CLEANUP_MODE) {
            call cleanUpUnixFilesystem as cleanUpVGMapperInputsUnix {
                input:
                    previous_task_outputs = [read_pair_chunk_files.left, read_pair_chunk_files.right],
                    current_task_output = vg_map_algorithm_chunk_gam_output
            }
        }
        if (SURJECT_MODE) {
            call runSurject {
                input:
                    in_gam_chunk_file=vg_map_algorithm_chunk_gam_output,
                    in_xg_file=XG_FILE,
                    in_vg_container=VG_CONTAINER,
                    in_sample_name=SAMPLE_NAME
            }
            call sortMDTagBAMFile {
                input:
                    in_sample_name=SAMPLE_NAME,
                    in_bam_chunk_file=runSurject.chunk_bam_file,
                    in_reference_file=REF_FILE,
                    in_reference_index_file=REF_INDEX_FILE,
                    in_reference_dict_file=REF_DICT_FILE
            }
            call runPICARD {
                input:
                    in_sample_name=SAMPLE_NAME,
                    in_bam_file=sortMDTagBAMFile.sorted_bam_file,
                    in_bam_file_index=sortMDTagBAMFile.sorted_bam_file_index,
                    in_reference_file=REF_FILE,
                    in_reference_index_file=REF_INDEX_FILE,
                    in_reference_dict_file=REF_DICT_FILE
            }
            # Cleanup intermediate surject files after use
            if (GOOGLE_CLEANUP_MODE) {
                call cleanUpGoogleFilestore as cleanUpVGSurjectInputsGoogle {
                    input:
                        previous_task_outputs = [vg_map_algorithm_chunk_gam_output, runSurject.chunk_bam_file, sortMDTagBAMFile.sorted_bam_file, sortMDTagBAMFile.sorted_bam_file_index],
                        current_task_output = runPICARD.mark_dupped_reordered_bam
                }
            }
            if (!GOOGLE_CLEANUP_MODE) {
                call cleanUpUnixFilesystem as cleanUpVGSurjectInputsUnix {
                    input:
                        previous_task_outputs = [vg_map_algorithm_chunk_gam_output, runSurject.chunk_bam_file, sortMDTagBAMFile.sorted_bam_file, sortMDTagBAMFile.sorted_bam_file_index],
                        current_task_output = runPICARD.mark_dupped_reordered_bam
                }
            }
        }
    }
    
    ##############################################
    # Run the linear alignment calling procedure #
    ##############################################
    if (SURJECT_MODE) {
        # Merge chunked alignments from surjected GAM files
        Array[File?] alignment_chunk_bam_files_maybes = runPICARD.mark_dupped_reordered_bam
        Array[File] alignment_chunk_bam_files_valid = select_all(alignment_chunk_bam_files_maybes)
        if (!VGMPMAP_MODE) {
            call mergeAlignmentBAMChunksVGMAP {
                input:
                    in_sample_name=SAMPLE_NAME,
                    in_alignment_bam_chunk_files=alignment_chunk_bam_files_valid
            }
        }
        if (VGMPMAP_MODE) {
            call mergeAlignmentBAMChunksVGMPMAP {
                input:
                    in_sample_name=SAMPLE_NAME,
                    in_alignment_bam_chunk_files=alignment_chunk_bam_files_valid
            }
        }
        File merged_bam_file_output = select_first([mergeAlignmentBAMChunksVGMAP.merged_bam_file, mergeAlignmentBAMChunksVGMPMAP.merged_bam_file])
        File merged_bam_file_index_output = select_first([mergeAlignmentBAMChunksVGMAP.merged_bam_file_index, mergeAlignmentBAMChunksVGMPMAP.merged_bam_file_index])
        
        # Split merged alignment by contigs list
        call splitBAMbyPath {
            input:
                in_sample_name=SAMPLE_NAME,
                in_merged_bam_file=merged_bam_file_output,
                in_merged_bam_file_index=merged_bam_file_index_output,
                in_path_list_file=pipeline_path_list_file
        }
        # Run distributed GATK linear variant calling
        scatter (gatk_caller_input_files in splitBAMbyPath.bams_and_indexes_by_contig) { 
            call runGATKIndelRealigner {
                input:
                    in_sample_name=SAMPLE_NAME,
                    in_bam_file=gatk_caller_input_files,
                    in_reference_file=REF_FILE,
                    in_reference_index_file=REF_INDEX_FILE,
                    in_reference_dict_file=REF_DICT_FILE
            }
            # Run regular VCF genotypers
            if ((!GVCF_MODE) && (!DRAGEN_MODE)) {
                call runGATKHaplotypeCaller {
                    input:
                        in_sample_name=SAMPLE_NAME,
                        in_bam_file=runGATKIndelRealigner.indel_realigned_bam,
                        in_bam_file_index=runGATKIndelRealigner.indel_realigned_bam_index,
                        in_reference_file=REF_FILE,
                        in_reference_index_file=REF_INDEX_FILE,
                        in_reference_dict_file=REF_DICT_FILE
                }
            }
            # Cleanup intermediate variant calling files after use
            if (GOOGLE_CLEANUP_MODE) {
                call cleanUpGoogleFilestore as cleanUpLinearCallerInputsGoogle {
                    input:
                        previous_task_outputs = [gatk_caller_input_files.left, gatk_caller_input_files.right],
                        current_task_output = runGATKIndelRealigner.indel_realigned_bam
                }
            }
            if (!GOOGLE_CLEANUP_MODE) {
                call cleanUpUnixFilesystem as cleanUpLinearCallerInputsUnix {
                    input:
                        previous_task_outputs = [gatk_caller_input_files.left, gatk_caller_input_files.right],
                        current_task_output = runGATKIndelRealigner.indel_realigned_bam
                }
            }
        }
        
        # Merge linear-based called VCFs
        if ((!GVCF_MODE) && (!DRAGEN_MODE)) {
            Array[File?] final_contig_vcf_output = runGATKHaplotypeCaller.genotyped_vcf
            Array[File] final_contig_vcf_output_list = select_all(final_contig_vcf_output)
            call concatClippedVCFChunks as concatLinearVCFChunks {
                input:
                    in_sample_name=SAMPLE_NAME,
                    in_clipped_vcf_chunk_files=final_contig_vcf_output_list
            }
            call bgzipMergedVCF as bgzipGATKCalledVCF { 
                input: 
                    in_sample_name=SAMPLE_NAME, 
                    in_merged_vcf_file=concatLinearVCFChunks.output_merged_vcf,
                    in_vg_container=VG_CONTAINER 
            }
        }
        # Merge Indel Realigned BAM
        Array[File?] indel_realigned_bam_files_maybes = runGATKIndelRealigner.indel_realigned_bam
        Array[File] indel_realigned_bam_files = select_all(indel_realigned_bam_files_maybes)
        call mergeIndelRealignedBAMs {
            input:
                in_sample_name=SAMPLE_NAME,
                in_alignment_bam_chunk_files=indel_realigned_bam_files
        }
        # Run VCF variant calling using the Dragen module
        if ((!GVCF_MODE) && (DRAGEN_MODE)) {
            call runDragenCaller {
                input:
                    in_sample_name=SAMPLE_NAME,
                    in_bam_file=mergeIndelRealignedBAMs.merged_indel_realigned_bam_file,
                    in_dragen_ref_index_name=DRAGEN_REF_INDEX_NAME,
                    in_udp_data_dir=UDPBINFO_PATH,
                    in_helix_username=HELIX_USERNAME
            }
        }
        # Run GVCF variant calling procedure
        if (GVCF_MODE) {
            # Run GVCF genotypers
            if (!DRAGEN_MODE) {
                call runGATKHaplotypeCallerGVCF {
                    input:
                        in_sample_name=SAMPLE_NAME,
                        in_bam_file=mergeIndelRealignedBAMs.merged_indel_realigned_bam_file,
                        in_bam_file_index=mergeIndelRealignedBAMs.merged_indel_realigned_bam_file_index,
                        in_reference_file=REF_FILE,
                        in_reference_index_file=REF_INDEX_FILE,
                        in_reference_dict_file=REF_DICT_FILE
                }
            }
            # Run GVCF varaint calling using the Dragen module
            if (DRAGEN_MODE) {
                call runDragenCallerGVCF {
                    input:
                        in_sample_name=SAMPLE_NAME,
                        in_bam_file=mergeIndelRealignedBAMs.merged_indel_realigned_bam_file,
                        in_dragen_ref_index_name=DRAGEN_REF_INDEX_NAME,
                        in_udp_data_dir=UDPBINFO_PATH,
                        in_helix_username=HELIX_USERNAME
                }
            }
            
            File final_gvcf_output = select_first([runGATKHaplotypeCallerGVCF.rawLikelihoods_gvcf, runDragenCallerGVCF.dragen_genotyped_gvcf])
        }
        # Cleanup indel realigned bam files after use
        if (GOOGLE_CLEANUP_MODE) {
            call cleanUpGoogleFilestore as cleanUpIndelRealignedBamsGoogle {
                input:
                    previous_task_outputs = indel_realigned_bam_files,
                    current_task_output = mergeIndelRealignedBAMs.merged_indel_realigned_bam_file
            }
        }
        if (!GOOGLE_CLEANUP_MODE) {
            call cleanUpUnixFilesystem as cleanUpIndelRealignedBamsUnix {
                input:
                    previous_task_outputs = indel_realigned_bam_files,
                    current_task_output = mergeIndelRealignedBAMs.merged_indel_realigned_bam_file
            }
        }
    }
    
    ################################
    # Run the VG calling procedure #
    ################################
    if (!SURJECT_MODE) {
        # Merge chunked graph alignments
        call mergeAlignmentGAMChunks {
            input:
                in_sample_name=SAMPLE_NAME,
                in_vg_container=VG_CONTAINER,
                in_alignment_gam_chunk_files=vg_map_algorithm_chunk_gam_output,
                in_merge_gam_cores=MERGE_GAM_CORES,
                in_merge_gam_disk=MERGE_GAM_DISK,
                in_merge_gam_mem=MERGE_GAM_MEM,
                in_merge_gam_time=MERGE_GAM_TIME
        }
        # Cleanup gam chunk files after use
        if (GOOGLE_CLEANUP_MODE) {
            call cleanUpGoogleFilestore as cleanUpGAMChunksGoogle {
                input:
                    previous_task_outputs = vg_map_algorithm_chunk_gam_output,
                    current_task_output = mergeAlignmentGAMChunks.merged_sorted_gam_file
            }
        }
        if (!GOOGLE_CLEANUP_MODE) {
            call cleanUpUnixFilesystem as cleanUpGAMChunksUnix {
                input:
                    previous_task_outputs = vg_map_algorithm_chunk_gam_output,
                    current_task_output = mergeAlignmentGAMChunks.merged_sorted_gam_file
            }
        }
        # Set chunk context amount depending on structural variant or default variant calling mode
        Int default_or_sv_chunk_context = if SV_CALLER_MODE then 200 else 50
        # Chunk GAM alignments by contigs list
        call chunkAlignmentsByPathNames {
            input:
            in_sample_name=SAMPLE_NAME,
            in_merged_sorted_gam=mergeAlignmentGAMChunks.merged_sorted_gam_file,
            in_merged_sorted_gam_gai=mergeAlignmentGAMChunks.merged_sorted_gam_gai_file,
            in_xg_file=XG_FILE,
            in_path_list_file=pipeline_path_list_file,
            in_chunk_context=default_or_sv_chunk_context,
            in_chunk_bases=CHUNK_BASES,
            in_overlap=OVERLAP,
            in_vg_container=VG_CONTAINER,
            in_chunk_gam_cores=CHUNK_GAM_CORES,
            in_chunk_gam_disk=CHUNK_GAM_DISK,
            in_chunk_gam_mem=CHUNK_GAM_MEM
        }
        Array[Pair[File,File]] vg_caller_input_files_list = zip(chunkAlignmentsByPathNames.output_vg_chunks, chunkAlignmentsByPathNames.output_gam_chunks) 
        # Run distributed graph-based variant calling
        scatter (vg_caller_input_files in vg_caller_input_files_list) { 
            call runVGCaller { 
                input: 
                    in_sample_name=SAMPLE_NAME, 
                    in_chunk_bed_file=chunkAlignmentsByPathNames.output_bed_chunk_file, 
                    in_vg_file=vg_caller_input_files.left, 
                    in_gam_file=vg_caller_input_files.right, 
                    in_chunk_bases=CHUNK_BASES, 
                    in_overlap=OVERLAP, 
                    in_vg_container=VG_CONTAINER,
                    in_vgcall_cores=VGCALL_CORES,
                    in_vgcall_disk=VGCALL_DISK,
                    in_vgcall_mem=VGCALL_MEM,
                    in_sv_mode=SV_CALLER_MODE
            } 
            call runVCFClipper { 
                input: 
                    in_chunk_vcf=runVGCaller.output_vcf, 
                    in_chunk_vcf_index=runVGCaller.output_vcf_index, 
                    in_chunk_clip_string=runVGCaller.clip_string 
            } 
            # Cleanup vg call input files after use
            if (GOOGLE_CLEANUP_MODE) {
                call cleanUpGoogleFilestore as cleanUpVGCallInputsGoogle {
                    input:
                        previous_task_outputs = [vg_caller_input_files.left, vg_caller_input_files.right, runVGCaller.output_vcf],
                        current_task_output = runVCFClipper.output_clipped_vcf
                }
            }
            if (!GOOGLE_CLEANUP_MODE) {
                call cleanUpUnixFilesystem as cleanUpVGCallInputsUnix {
                    input:
                        previous_task_outputs = [vg_caller_input_files.left, vg_caller_input_files.right, runVGCaller.output_vcf],
                        current_task_output = runVCFClipper.output_clipped_vcf
                }
            }
        } 
        # Merge distributed variant called VCFs
        call concatClippedVCFChunks as concatVCFChunksVGCall { 
            input: 
                in_sample_name=SAMPLE_NAME, 
                in_clipped_vcf_chunk_files=runVCFClipper.output_clipped_vcf 
        } 
        # Extract either the normal or structural variant based VCFs and compress them
        call bgzipMergedVCF as bgzipVGCalledVCF {
            input:
                in_sample_name=SAMPLE_NAME,
                in_merged_vcf_file=concatVCFChunksVGCall.output_merged_vcf,
                in_vg_container=VG_CONTAINER
        }
    }
    
    # Extract either the linear-based or graph-based VCF
    File variantcaller_vcf_output = select_first([bgzipVGCalledVCF.output_merged_vcf, bgzipGATKCalledVCF.output_merged_vcf, final_gvcf_output])
    # Run snpEff annotation on final VCF as desired
    if (SNPEFF_ANNOTATION) {
        call normalizeVCF {
            input:
                in_sample_name=SAMPLE_NAME,
                in_bgzip_vcf_file=variantcaller_vcf_output,
        }
        call snpEffAnnotateVCF {
            input:
                in_sample_name=SAMPLE_NAME,
                in_normalized_vcf_file=normalizeVCF.output_normalized_vcf,
                in_snpeff_database=SNPEFF_DATABASE,
        }
    }
    if (!SNPEFF_ANNOTATION) {
        File final_vcf_output = variantcaller_vcf_output
    }
    output {
        File output_vcf = select_first([snpEffAnnotateVCF.output_snpeff_annotated_vcf, final_vcf_output])
        File? output_bam = mergeIndelRealignedBAMs.merged_indel_realigned_bam_file
        File? output_bam_index = mergeIndelRealignedBAMs.merged_indel_realigned_bam_file_index
        File? output_gam = mergeAlignmentGAMChunks.merged_sorted_gam_file
        File? output_gam_index = mergeAlignmentGAMChunks.merged_sorted_gam_gai_file
    }
}

########################
### TASK DEFINITIONS ###
########################

# Tasks for intermediate file cleanup
task cleanUpUnixFilesystem {
    input {
        Array[String] previous_task_outputs
        String current_task_output
    }
    command <<<
        set -eux -o pipefail
        cat ~{write_lines(previous_task_outputs)} | sed 's/.*\(\/cromwell-executions\)/\1/g' | xargs -I {} ls -li {} | cut -f 1 -d ' ' | xargs -I {} find ../../../ -xdev -inum {} | xargs -I {} rm -v {}
    >>>
    runtime {
        docker: "null"
    }
}

task cleanUpGoogleFilestore {
    input {
        Array[String] previous_task_outputs
        String current_task_output
    }
    command {
        set -eux -o pipefail
        gsutil rm -I < ${write_lines(previous_task_outputs)}
    }
    runtime {
        docker: "google/cloud-sdk"
    }
}

task splitReads {
    input {
        File in_read_file
        String in_pair_id
        String in_vg_container
        Int in_reads_per_chunk
        Int in_split_read_cores
        Int in_split_read_disk
    }
    
    command <<< 
        # Set the exit code of a pipeline to that of the rightmost command
        # to exit with a non-zero status, or zero if all commands of the pipeline exit
        set -o pipefail
        # cause a bash script to exit immediately when a command fails
        set -e
        # cause the bash shell to treat unset variables as an error and exit immediately
        set -u
        # echo each line of the script to stdout so we can see what is happening
        set -o xtrace
        #to turn off echo do 'set +o xtrace'

        CHUNK_LINES=$(( ~{in_reads_per_chunk} * 4 ))
        gzip -cd ~{in_read_file} | split -l $CHUNK_LINES --filter='pigz -p ~{in_split_read_cores} > ${FILE}.fq.gz' - "fq_chunk_~{in_pair_id}.part."
    >>>
    output {
        Array[File] output_read_chunks = glob("fq_chunk_~{in_pair_id}.part.*")
    }
    runtime {
        cpu: in_split_read_cores
        memory: "40 GB"
        disks: "local-disk " + in_split_read_disk + " SSD"
        docker: in_vg_container
    }
}

task extractPathNames {
    input {
        File in_xg_file
        String in_vg_container
    }

    command {
        set -eux -o pipefail

        vg paths \
            --list \
            --xg ${in_xg_file} > path_list.txt
    }
    output {
        File output_path_list = "path_list.txt"
    }
    runtime {
        memory: "20 GB"
        disks: "local-disk 50 SSD"
        docker: in_vg_container
    }
}

task runVGMAP {
    input {
        File in_left_read_pair_chunk_file
        File in_right_read_pair_chunk_file
        File in_xg_file
        File in_gcsa_file
        File in_gcsa_lcp_file
        File? in_gbwt_file
        String in_vg_container
        String in_sample_name
        Int in_map_cores
        Int in_map_disk
        String in_map_mem
    }
    
    Boolean gbwt_options = defined(in_gbwt_file)
    
    command <<< 
        # Set the exit code of a pipeline to that of the rightmost command
        # to exit with a non-zero status, or zero if all commands of the pipeline exit
        set -o pipefail
        # cause a bash script to exit immediately when a command fails
        set -e
        # cause the bash shell to treat unset variables as an error and exit immediately
        set -u
        # echo each line of the script to stdout so we can see what is happening
        set -o xtrace
        #to turn off echo do 'set +o xtrace'

        READ_CHUNK_ID=($(ls ~{in_left_read_pair_chunk_file} | awk -F'.' '{print $(NF-2)}'))
        GBWT_OPTION_STRING=""
        if [ ~{gbwt_options} == true ]; then
          GBWT_OPTION_STRING="--gbwt-name ~{in_gbwt_file}"
        fi
        vg map \
          -x ~{in_xg_file} \
          -g ~{in_gcsa_file} \
          ${GBWT_OPTION_STRING} \
          -f ~{in_left_read_pair_chunk_file} -f ~{in_right_read_pair_chunk_file} \
          -t ~{in_map_cores} > ~{in_sample_name}.${READ_CHUNK_ID}.gam
    >>>
    output {
        File chunk_gam_file = glob("*.gam")[0]
    }
    runtime {
        memory: in_map_mem + " GB"
        cpu: in_map_cores
        disks: "local-disk " + in_map_disk + " SSD"
        docker: in_vg_container
    }
}

task runVGMPMAP {
    input {
        File in_left_read_pair_chunk_file
        File in_right_read_pair_chunk_file
        File in_xg_file
        File in_gcsa_file
        File in_gcsa_lcp_file
        File? in_gbwt_file
        File? in_snarls_file
        String in_vg_container
        String in_sample_name
        Int in_map_cores
        Int in_map_disk
        String in_map_mem
    }
    
    Boolean gbwt_options = defined(in_gbwt_file)
    Boolean snarl_options = defined(in_snarls_file)
    
    command <<< 
        # Set the exit code of a pipeline to that of the rightmost command
        # to exit with a non-zero status, or zero if all commands of the pipeline exit
        set -o pipefail
        # cause a bash script to exit immediately when a command fails
        set -e
        # cause the bash shell to treat unset variables as an error and exit immediately
        set -u
        # echo each line of the script to stdout so we can see what is happening
        set -o xtrace
        #to turn off echo do 'set +o xtrace'
        
        READ_CHUNK_ID=($(ls ~{in_left_read_pair_chunk_file} | awk -F'.' '{print $(NF-2)}'))
        GBWT_OPTION_STRING=""
        if [ ~{gbwt_options} == true ] && [ ~{snarl_options} == false ]; then
          GBWT_OPTION_STRING="--gbwt-name ~{in_gbwt_file}"
        elif [ ~{gbwt_options} == true ] && [ ~{snarl_options} == true ]; then
          GBWT_OPTION_STRING="--gbwt-name ~{in_gbwt_file} -s ~{in_snarls_file}"
        fi
        vg mpmap \
          -S \
          -f ~{in_left_read_pair_chunk_file} -f ~{in_right_read_pair_chunk_file} \
          -x ~{in_xg_file} \
          -g ~{in_gcsa_file} \
          ${GBWT_OPTION_STRING} \
          --read-group "ID:1 LB:lib1 SM:~{in_sample_name} PL:illumina PU:unit1" \
          --sample "~{in_sample_name}" \
          --recombination-penalty 5.0 -t ~{in_map_cores} > ~{in_sample_name}.${READ_CHUNK_ID}.gam
    >>>
    output {
        File chunk_gam_file = glob("*.gam")[0]
    }
    runtime {
        memory: in_map_mem + " GB"
        cpu: in_map_cores
        disks: "local-disk " + in_map_disk + " SSD"
        docker: in_vg_container
    }
}

task runSurject {
    input {
        File in_gam_chunk_file
        File in_xg_file
        String in_vg_container
        String in_sample_name
    }
    
    command <<<
        # Set the exit code of a pipeline to that of the rightmost command
        # to exit with a non-zero status, or zero if all commands of the pipeline exit
        set -o pipefail
        # cause a bash script to exit immediately when a command fails
        set -e
        # cause the bash shell to treat unset variables as an error and exit immediately
        set -u
        # echo each line of the script to stdout so we can see what is happening
        set -o xtrace
        #to turn off echo do 'set +o xtrace'

        READ_CHUNK_ID=($(ls ~{in_gam_chunk_file} | awk -F'.' '{print $(NF-1)}'))
        vg surject \
          -i \
          -x ~{in_xg_file} \
          -t 32 \
          -b ~{in_gam_chunk_file} > ~{in_sample_name}.${READ_CHUNK_ID}.bam
    >>>
    output {
        File chunk_bam_file = glob("*.bam")[0]
    }
    runtime {
        memory: 100 + " GB"
        cpu: 32
        disks: "local-disk 100 SSD"
        docker: in_vg_container
    }
}

task sortMDTagBAMFile {
    input {
        String in_sample_name
        File in_bam_chunk_file
        File in_reference_file
        File in_reference_index_file
        File in_reference_dict_file
    }
    
    command {
        # Set the exit code of a pipeline to that of the rightmost command
        # to exit with a non-zero status, or zero if all commands of the pipeline exit
        set -o pipefail
        # cause a bash script to exit immediately when a command fails
        set -e
        # cause the bash shell to treat unset variables as an error and exit immediately
        set -u
        # echo each line of the script to stdout so we can see what is happening
        set -o xtrace
        #to turn off echo do 'set +o xtrace'
        samtools sort \
          --threads 32 \
          ${in_bam_chunk_file} \
          -O BAM \
        | samtools calmd \
          -b \
          - \
          ${in_reference_file} \
          > ${in_sample_name}_positionsorted.mdtag.bam \
        && samtools index \
          ${in_sample_name}_positionsorted.mdtag.bam
    }
    output {
        File sorted_bam_file = "${in_sample_name}_positionsorted.mdtag.bam"
        File sorted_bam_file_index = "${in_sample_name}_positionsorted.mdtag.bam.bai"
    }
    runtime {
        memory: 50 + " GB"
        cpu: 32
        disks: "local-disk 50 SSD"
        docker: "biocontainers/samtools:v1.3_cv3"
    }
}

task runPICARD {
    input {
        String in_sample_name
        File in_bam_file
        File in_bam_file_index
        File in_reference_file
        File in_reference_index_file
        File in_reference_dict_file
    }
    
    command {
        # Set the exit code of a pipeline to that of the rightmost command
        # to exit with a non-zero status, or zero if all commands of the pipeline exit
        set -o pipefail
        # cause a bash script to exit immediately when a command fails
        set -e
        # cause the bash shell to treat unset variables as an error and exit immediately
        set -u
        # echo each line of the script to stdout so we can see what is happening
        set -o xtrace
        #to turn off echo do 'set +o xtrace'

        java -Xmx80g -XX:ParallelGCThreads=32 -jar /usr/picard/picard.jar MarkDuplicates \
          VALIDATION_STRINGENCY=LENIENT \
          I=${in_bam_file} \
          O=${in_sample_name}.mdtag.dupmarked.bam \
          M=marked_dup_metrics.txt 2> mark_dup_stderr.txt \
        && java -Xmx80g -XX:ParallelGCThreads=32 -jar /usr/picard/picard.jar ReorderSam \
            VALIDATION_STRINGENCY=LENIENT \
            REFERENCE=${in_reference_file} \
            INPUT=${in_sample_name}.mdtag.dupmarked.bam \
            OUTPUT=${in_sample_name}.mdtag.dupmarked.reordered.bam \
        && java -Xmx80g -XX:ParallelGCThreads=32 -jar /usr/picard/picard.jar BuildBamIndex \
            VALIDATION_STRINGENCY=LENIENT \
            I=${in_sample_name}.mdtag.dupmarked.reordered.bam \
            O=${in_sample_name}.mdtag.dupmarked.reordered.bam.bai \
        && rm -f ${in_sample_name}.mdtag.dupmarked.bam
    }
    output {
        File mark_dupped_reordered_bam = "${in_sample_name}.mdtag.dupmarked.reordered.bam"
        File mark_dupped_reordered_bam_index = "${in_sample_name}.mdtag.dupmarked.reordered.bam.bai"
    }
    runtime {
        time: 600
        memory: 100 + " GB"
        cpu: 32
        docker: "broadinstitute/picard:latest"
    }
}

task mergeAlignmentBAMChunksVGMAP {
    input {
        String in_sample_name
        Array[File] in_alignment_bam_chunk_files
    }
    
    command {
        # Set the exit code of a pipeline to that of the rightmost command
        # to exit with a non-zero status, or zero if all commands of the pipeline exit
        set -o pipefail
        # cause a bash script to exit immediately when a command fails
        set -e
        # cause the bash shell to treat unset variables as an error and exit immediately
        set -u
        # echo each line of the script to stdout so we can see what is happening
        set -o xtrace
        #to turn off echo do 'set +o xtrace'
        samtools merge \
          -f -u --threads 32 \
          - \
          ${sep=" " in_alignment_bam_chunk_files} \
        | samtools fixmate \
          -O BAM \
          - \
          ${in_sample_name}_merged.namesorted.fixmate.bam \
        | samtools sort \
          --threads 32 \
          - \
          -O BAM \
        | samtools addreplacerg \
          -O BAM \
          -r ID:1 -r LB:lib1 -r SM:${in_sample_name} -r PL:illumina -r PU:unit1 \
          - \
        | samtools view \
          -@ 32 \
          -h -O SAM \
          - \
        | samtools view \
          -@ 32 \
          -h -O BAM \
          - \
          > ${in_sample_name}_merged.fixmate.positionsorted.rg.bam \
        && samtools index \
          ${in_sample_name}_merged.fixmate.positionsorted.rg.bam
    }
    output {
        File merged_bam_file = "${in_sample_name}_merged.fixmate.positionsorted.rg.bam"
        File merged_bam_file_index = "${in_sample_name}_merged.fixmate.positionsorted.rg.bam.bai"
    }
    runtime {
        memory: 100 + " GB"
        cpu: 32
        disks: "local-disk 100 SSD"
        docker: "biocontainers/samtools:v1.3_cv3"
    }
}

task mergeAlignmentBAMChunksVGMPMAP {
    input {
        String in_sample_name
        Array[File] in_alignment_bam_chunk_files
    }
    
    command {
        # Set the exit code of a pipeline to that of the rightmost command
        # to exit with a non-zero status, or zero if all commands of the pipeline exit
        set -o pipefail
        # cause a bash script to exit immediately when a command fails
        set -e
        # cause the bash shell to treat unset variables as an error and exit immediately
        set -u
        # echo each line of the script to stdout so we can see what is happening
        set -o xtrace
        #to turn off echo do 'set +o xtrace'
        samtools merge \
          -f --threads 32 \
          - \
          ${sep=" " in_alignment_bam_chunk_files} \
          > ${in_sample_name}_merged.positionsorted.bam \
        && samtools index \
          ${in_sample_name}_merged.positionsorted.bam
    }
    output {
        File merged_bam_file = "${in_sample_name}_merged.positionsorted.bam"
        File merged_bam_file_index = "${in_sample_name}_merged.positionsorted.bam.bai"
    }
    runtime {
        memory: 100 + " GB"
        cpu: 32
        disks: "local-disk 100 SSD"
        docker: "biocontainers/samtools:v1.3_cv3"
    }
}

task splitBAMbyPath {
    input {
        String in_sample_name
        File in_merged_bam_file
        File in_merged_bam_file_index
        File in_path_list_file
    }
    
    command <<<
        set -eux -o pipefail
        
        while IFS=$'\t' read -ra path_list_line; do
            path_name="${path_list_line[0]}"
            samtools view \
              -@ 32 \
              -h -O BAM \
              ~{in_merged_bam_file} ${path_name} > ~{in_sample_name}.${path_name}.bam \
            && samtools index \
              ~{in_sample_name}.${path_name}.bam
        done < ~{in_path_list_file}
    >>>
    output {
        Array[File] bam_contig_files = glob("~{in_sample_name}.*.bam")
        Array[File] bam_contig_files_index = glob("~{in_sample_name}.*.bam.bai") 
        Array[Pair[File, File]] bams_and_indexes_by_contig = zip(bam_contig_files, bam_contig_files_index)
    }
    runtime {
        memory: 100 + " GB"
        cpu: 32
        disks: "local-disk 100 SSD"
        docker: "biocontainers/samtools:v1.3_cv3"
    }
}

task runGATKIndelRealigner {
    input {
        String in_sample_name
        Pair[File, File] in_bam_file
        File in_reference_file
        File in_reference_index_file
        File in_reference_dict_file
    }
    
    command {
        # Set the exit code of a pipeline to that of the rightmost command
        # to exit with a non-zero status, or zero if all commands of the pipeline exit
        set -o pipefail
        # cause a bash script to exit immediately when a command fails
        set -e
        # cause the bash shell to treat unset variables as an error and exit immediately
        set -u
        # echo each line of the script to stdout so we can see what is happening
        set -o xtrace
        #to turn off echo do 'set +o xtrace'
        
        ln -s ${in_bam_file.left} input_bam_file.bam
        ln -s ${in_bam_file.right} input_bam_file.bam.bai
        java -jar /usr/GenomeAnalysisTK.jar -T RealignerTargetCreator \
          -nt 32 \
          -R ${in_reference_file} \
          -I input_bam_file.bam \
          --out forIndelRealigner.intervals \
        && java -jar /usr/GenomeAnalysisTK.jar -T IndelRealigner \
          -R ${in_reference_file} \
          --targetIntervals forIndelRealigner.intervals \
          -I input_bam_file.bam \
          --out ${in_sample_name}_merged.fixmate.positionsorted.rg.mdtag.dupmarked.reordered.indel_realigned.bam
    }
    output {
        File indel_realigned_bam = "${in_sample_name}_merged.fixmate.positionsorted.rg.mdtag.dupmarked.reordered.indel_realigned.bam"
        File indel_realigned_bam_index = "${in_sample_name}_merged.fixmate.positionsorted.rg.mdtag.dupmarked.reordered.indel_realigned.bai"
    }
    runtime {
        time: 1200
        memory: 100 + " GB"
        cpu: 32
        docker: "broadinstitute/gatk3:3.8-1"
    }
}

task mergeIndelRealignedBAMs {
    input {
        String in_sample_name
        Array[File] in_alignment_bam_chunk_files
    }
    
    command {
        # Set the exit code of a pipeline to that of the rightmost command
        # to exit with a non-zero status, or zero if all commands of the pipeline exit
        set -o pipefail
        # cause a bash script to exit immediately when a command fails
        set -e
        # cause the bash shell to treat unset variables as an error and exit immediately
        set -u
        # echo each line of the script to stdout so we can see what is happening
        set -o xtrace
        #to turn off echo do 'set +o xtrace'
        samtools merge \
          -f --threads 32 \
          ${in_sample_name}_merged.indel_realigned.bam \
          ${sep=" " in_alignment_bam_chunk_files} \
        && samtools index \
          ${in_sample_name}_merged.indel_realigned.bam
    }
    output {
        File merged_indel_realigned_bam_file = "${in_sample_name}_merged.indel_realigned.bam"
        File merged_indel_realigned_bam_file_index = "${in_sample_name}_merged.indel_realigned.bam.bai"
    }
    runtime {
        memory: 100 + " GB"
        cpu: 32
        disks: "local-disk 100 SSD"
        docker: "biocontainers/samtools:v1.3_cv3"
    }
}

task runGATKHaplotypeCaller {
    input {
        String in_sample_name
        File in_bam_file
        File in_bam_file_index
        File in_reference_file
        File in_reference_index_file
        File in_reference_dict_file
    }
    
    command {
        # Set the exit code of a pipeline to that of the rightmost command
        # to exit with a non-zero status, or zero if all commands of the pipeline exit
        set -o pipefail
        # cause a bash script to exit immediately when a command fails
        set -e
        # cause the bash shell to treat unset variables as an error and exit immediately
        set -u
        # echo each line of the script to stdout so we can see what is happening
        set -o xtrace
        #to turn off echo do 'set +o xtrace'

        gatk HaplotypeCaller \
          --native-pair-hmm-threads 32 \
          --reference ${in_reference_file} \
          --input ${in_bam_file} \
          --output ${in_sample_name}.vcf \
        && bgzip ${in_sample_name}.vcf
    }
    output {
        File genotyped_vcf = "${in_sample_name}.vcf.gz"
    }
    runtime {
        memory: 100 + " GB"
        cpu: 32
        docker: "broadinstitute/gatk:4.1.1.0"
    }
}

task runGATKHaplotypeCallerGVCF {
    input {
        String in_sample_name
        File in_bam_file
        File in_bam_file_index
        File in_reference_file
        File in_reference_index_file
        File in_reference_dict_file
    }
    
    command {
        # Set the exit code of a pipeline to that of the rightmost command
        # to exit with a non-zero status, or zero if all commands of the pipeline exit
        set -o pipefail
        # cause a bash script to exit immediately when a command fails
        set -e
        # cause the bash shell to treat unset variables as an error and exit immediately
        set -u
        # echo each line of the script to stdout so we can see what is happening
        set -o xtrace
        #to turn off echo do 'set +o xtrace'

        gatk HaplotypeCaller \
          --native-pair-hmm-threads 32 \
          -ERC GVCF \
          --reference ${in_reference_file} \
          --input ${in_bam_file} \
          --output ${in_sample_name}.rawLikelihoods.gvcf \
        && bgzip ${in_sample_name}.rawLikelihoods.gvcf
    }
    output {
        File rawLikelihoods_gvcf = "${in_sample_name}.rawLikelihoods.gvcf.gz"
    }
    runtime {
        memory: 100 + " GB"
        cpu: 32
        docker: "broadinstitute/gatk:4.1.1.0"
    }
}

task runDragenCaller {
    input {
        String in_sample_name
        File in_bam_file
        String in_dragen_ref_index_name
        String in_udp_data_dir
        String in_helix_username
    }
     
    String bam_file_name = basename(in_bam_file)
    
    command <<<
        # Set the exit code of a pipeline to that of the rightmost command
        # to exit with a non-zero status, or zero if all commands of the pipeline exit
        set -o pipefail
        # cause a bash script to exit immediately when a command fails
        set -e
        # cause the bash shell to treat unset variables as an error and exit immediately
        set -u
        # echo each line of the script to stdout so we can see what is happening
        set -o xtrace
        #to turn off echo do 'set +o xtrace' 
        
        UDP_DATA_DIR_PATH="~{in_udp_data_dir}/usr/~{in_helix_username}"
        mkdir -p /data/${UDP_DATA_DIR_PATH}/~{in_sample_name}_surjected_bams/ && \
        cp ~{in_bam_file} /data/${UDP_DATA_DIR_PATH}/~{in_sample_name}_surjected_bams/ && \
        DRAGEN_WORK_DIR_PATH="/staging/~{in_helix_username}/~{in_sample_name}" && \
        TMP_DIR="/staging/~{in_helix_username}/tmp" && \
        ssh -t ~{in_helix_username}@helix.nih.gov ssh 165.112.174.51 "mkdir -p ${DRAGEN_WORK_DIR_PATH}" && \
        ssh -t ~{in_helix_username}@helix.nih.gov ssh 165.112.174.51 "mkdir -p ${TMP_DIR}" && \
        ssh -t ~{in_helix_username}@helix.nih.gov ssh 165.112.174.51 "dragen -f -r /staging/~{in_dragen_ref_index_name} -b /staging/helix/${UDP_DATA_DIR_PATH}/~{in_sample_name}_surjected_bams/~{bam_file_name} --verbose --bin_memory=50000000000 --enable-map-align false --enable-variant-caller true --pair-by-name=true --vc-sample-name ~{in_sample_name} --intermediate-results-dir ${TMP_DIR} --output-directory ${DRAGEN_WORK_DIR_PATH} --output-file-prefix ~{in_sample_name}_dragen_genotyped" && \
        mkdir /data/${UDP_DATA_DIR_PATH}/~{in_sample_name}_dragen_genotyper && chmod ug+rw -R /data/${UDP_DATA_DIR_PATH}/~{in_sample_name}_dragen_genotyper && \
        ssh -t ~{in_helix_username}@helix.nih.gov ssh 165.112.174.51 "cp -R ${DRAGEN_WORK_DIR_PATH}/. /staging/helix/${UDP_DATA_DIR_PATH}/~{in_sample_name}_dragen_genotyper" && \
        ssh -t ~{in_helix_username}@helix.nih.gov ssh 165.112.174.51 "rm -fr ${DRAGEN_WORK_DIR_PATH}/" && \
        mv /data/${UDP_DATA_DIR_PATH}/~{in_sample_name}_dragen_genotyper ~{in_sample_name}_dragen_genotyper && \
        rm -fr /data/${UDP_DATA_DIR_PATH}/~{in_sample_name}_surjected_bams/
    >>>
    output {
        File dragen_genotyped_vcf = "~{in_sample_name}_dragen_genotyper/~{in_sample_name}_dragen_genotyped.vcf.gz"
    }
    runtime {
        docker: "ubuntu:latest"
        memory: 50 + " GB"
    }
}

task runDragenCallerGVCF {
    input {
        String in_sample_name
        File in_bam_file
        String in_dragen_ref_index_name
        String in_udp_data_dir
        String in_helix_username
    }
    
    String bam_file_name = basename(in_bam_file)
    
    command <<<
        # Set the exit code of a pipeline to that of the rightmost command
        # to exit with a non-zero status, or zero if all commands of the pipeline exit
        set -o pipefail
        # cause a bash script to exit immediately when a command fails
        set -e
        # cause the bash shell to treat unset variables as an error and exit immediately
        set -u
        # echo each line of the script to stdout so we can see what is happening
        set -o xtrace
        #to turn off echo do 'set +o xtrace' 
        
        UDP_DATA_DIR_PATH="~{in_udp_data_dir}/usr/~{in_helix_username}"
        mkdir -p /data/${UDP_DATA_DIR_PATH}/~{in_sample_name}_surjected_bams/ && \
        cp ~{in_bam_file} /data/${UDP_DATA_DIR_PATH}/~{in_sample_name}_surjected_bams/ && \
        DRAGEN_WORK_DIR_PATH="/staging/~{in_helix_username}/~{in_sample_name}" && \
        TMP_DIR="/staging/~{in_helix_username}/tmp" && \
        ssh -t ~{in_helix_username}@helix.nih.gov ssh 165.112.174.51 "mkdir -p ${DRAGEN_WORK_DIR_PATH}" && \
        ssh -t ~{in_helix_username}@helix.nih.gov ssh 165.112.174.51 "mkdir -p ${TMP_DIR}" && \
        ssh -t ~{in_helix_username}@helix.nih.gov ssh 165.112.174.51 "dragen -f -r /staging/~{in_dragen_ref_index_name} -b /staging/helix/${UDP_DATA_DIR_PATH}/~{in_sample_name}_surjected_bams/~{bam_file_name} --verbose --bin_memory=50000000000 --enable-map-align false --enable-variant-caller true --pair-by-name=true --vc-emit-ref-confidence GVCF --vc-sample-name ~{in_sample_name} --intermediate-results-dir ${TMP_DIR} --output-directory ${DRAGEN_WORK_DIR_PATH} --output-file-prefix ~{in_sample_name}_dragen_genotyped" && \
        mkdir /data/${UDP_DATA_DIR_PATH}/~{in_sample_name}_dragen_genotyper && chmod ug+rw -R /data/${UDP_DATA_DIR_PATH}/~{in_sample_name}_dragen_genotyper && \
        ssh -t ~{in_helix_username}@helix.nih.gov ssh 165.112.174.51 "cp -R ${DRAGEN_WORK_DIR_PATH}/. /staging/helix/${UDP_DATA_DIR_PATH}/~{in_sample_name}_dragen_genotyper" && \
        ssh -t ~{in_helix_username}@helix.nih.gov ssh 165.112.174.51 "rm -fr ${DRAGEN_WORK_DIR_PATH}/" && \
        mv /data/${UDP_DATA_DIR_PATH}/~{in_sample_name}_dragen_genotyper ~{in_sample_name}_dragen_genotyper && \
        rm -fr /data/${UDP_DATA_DIR_PATH}/~{in_sample_name}_surjected_bams/
    >>>
    output {
        File dragen_genotyped_gvcf = "~{in_sample_name}_dragen_genotyper/~{in_sample_name}_dragen_genotyped.gvcf.gz"
    }
    runtime {
        docker: "ubuntu:latest"
        memory: 50 + " GB"
    }
}

task mergeAlignmentGAMChunks {
    input {
        String in_sample_name
        String in_vg_container
        Array[File] in_alignment_gam_chunk_files
        Int in_merge_gam_cores
        Int in_merge_gam_disk
        Int in_merge_gam_mem
        Int in_merge_gam_time
    }
    
    command {
        # Set the exit code of a pipeline to that of the rightmost command
        # to exit with a non-zero status, or zero if all commands of the pipeline exit
        set -o pipefail
        # cause a bash script to exit immediately when a command fails
        set -e
        # cause the bash shell to treat unset variables as an error and exit immediately
        set -u
        # echo each line of the script to stdout so we can see what is happening
        set -o xtrace
        #to turn off echo do 'set +o xtrace'
        
        cat ${sep=" " in_alignment_gam_chunk_files} > ${in_sample_name}_merged.gam \
        && vg gamsort \
            ${in_sample_name}_merged.gam \
            -i ${in_sample_name}_merged.sorted.gam.gai \
            -t ${in_merge_gam_cores} > ${in_sample_name}_merged.sorted.gam
    }
    output {
        File merged_sorted_gam_file = "${in_sample_name}_merged.sorted.gam"
        File merged_sorted_gam_gai_file = "${in_sample_name}_merged.sorted.gam.gai"
    }
    runtime {
        memory: in_merge_gam_mem + " GB"
        cpu: in_merge_gam_cores
        disks: "local-disk " + in_merge_gam_disk  + " SSD"
        time: in_merge_gam_time
        docker: in_vg_container
    }
}

task chunkAlignmentsByPathNames {
    input {
        String in_sample_name
        File in_merged_sorted_gam
        File in_merged_sorted_gam_gai
        File in_xg_file
        Int in_chunk_context
        File in_path_list_file
        Int in_chunk_bases
        Int in_overlap
        String in_vg_container
        Int in_chunk_gam_cores
        Int in_chunk_gam_disk
        Int in_chunk_gam_mem
    }
    
    command { 
        # Set the exit code of a pipeline to that of the rightmost command
        # to exit with a non-zero status, or zero if all commands of the pipeline exit
        set -o pipefail
        # cause a bash script to exit immediately when a command fails
        set -e
        # cause the bash shell to treat unset variables as an error and exit immediately
        set -u
        # echo each line of the script to stdout so we can see what is happening
        set -o xtrace
        #to turn off echo do 'set +o xtrace'
    
        vg chunk \
            -x ${in_xg_file} \
            -a ${in_merged_sorted_gam} \
            -c ${in_chunk_context} \
            -P ${in_path_list_file} \
            -g \
            -s ${in_chunk_bases} -o ${in_overlap} \
            -b call_chunk \
            -t ${in_chunk_gam_cores} \
            -E output_bed_chunks.bed -f
    }
    output {
        Array[File] output_vg_chunks = glob("call_chunk*.vg")
        Array[File] output_gam_chunks = glob("call_chunk*.gam")
        File output_bed_chunk_file = "output_bed_chunks.bed"
    }   
    runtime {
        time: 900
        memory: in_chunk_gam_mem + " GB"
        cpu: in_chunk_gam_cores
        disks: "local-disk " + in_chunk_gam_disk + " SSD"
        docker: in_vg_container
    }   
}

task runVGCaller {
    input {
        String in_sample_name
        File in_chunk_bed_file
        File in_vg_file
        File in_gam_file
        Int in_chunk_bases
        Int in_overlap
        String in_vg_container
        Int in_vgcall_cores
        Int in_vgcall_disk
        Int in_vgcall_mem
        Boolean in_sv_mode
    }

    String chunk_tag = basename(in_vg_file, ".vg")
    command <<<
        set -eux -o pipefail

        VG_INDEX_XG_COMMAND=""
        VG_FILTER_COMMAND=""
        VG_AUGMENT_SV_OPTIONS=""
        VG_CALL_SV_OPTIONS=""
        if [ ~{in_sv_mode} == false ]; then
            VG_INDEX_XG_COMMAND="vg index ~{in_vg_file} -x ~{chunk_tag}.xg -t ~{in_vgcall_cores} && \\"
            VG_FILTER_COMMAND="vg filter ~{in_gam_file} -t 1 -r 0.9 -fu -s 1000 -m 1 -q 15 -D 999 -x ~{chunk_tag}.xg > ~{chunk_tag}.filtered.gam && \\"
            VG_AUGMENT_SV_OPTIONS="~{chunk_tag}.filtered_gam"
        else
            VG_AUGMENT_SV_OPTIONS="~{in_gam_file} --recall"
            VG_CALL_SV_OPTIONS="-u -n 0 -e 1000 -G 3"
        fi

        PATH_NAME="$(echo ~{chunk_tag} | cut -f 4 -d '_')"
        OFFSET=""
        BED_CHUNK_LINE_RECORD=""
        FIRST_Q=""
        LAST_Q=""
        CHUNK_INDEX_COUNTER="0"
        CHUNK_TAG_INDEX="0"
        CHR_LENGTH=""
        while IFS=$'\t' read -ra bed_chunk_line; do
            bed_line_chunk_tag="$(echo ${bed_chunk_line[3]} | cut -f 1 -d '.')"
            if [ "~{chunk_tag}" = "${bed_line_chunk_tag}" ]; then
                OFFSET="${bed_chunk_line[1]}"
                BED_CHUNK_LINE_RECORD="${bed_chunk_line[@]//$'\t'/ }"
                CHUNK_TAG_INDEX="${CHUNK_INDEX_COUNTER}"
            fi
            bed_line_path_name="$(echo ${bed_line_chunk_tag} | cut -f 4 -d '_')"
            if [ "${PATH_NAME}" = "${bed_line_path_name}" ]; then
                if [ "${FIRST_Q}" = "" ]; then
                    FIRST_Q="${bed_chunk_line[@]//$'\t'/ }"
                fi
                LAST_Q="${bed_chunk_line[@]//$'\t'/ }"
                CHUNK_INDEX_COUNTER="$(( ${CHUNK_INDEX_COUNTER} + 1 ))"
                CHR_LENGTH="${bed_chunk_line[2]}"
            fi
        done < ~{in_chunk_bed_file}
        
        ${VG_INDEX_XG_COMMAND}
        ${VG_FILTER_COMMAND}
        vg augment \
            ~{in_vg_file} \
            ${VG_AUGMENT_SV_OPTIONS} \
            -t ~{in_vgcall_cores} \
            -a pileup \
            -Z ~{chunk_tag}.trans \
            -S ~{chunk_tag}.support > ~{chunk_tag}.aug.vg && \
        vg call \
            ~{chunk_tag}.aug.vg \
            -t ~{in_vgcall_cores} \
            -S ~{in_sample_name} \
            -z ~{chunk_tag}.trans \
            -s ~{chunk_tag}.support \
            -b ~{in_vg_file} \
            -r ${PATH_NAME} \
            -c ${PATH_NAME} \
            -l ${CHR_LENGTH} \
            ${VG_CALL_SV_OPTIONS} \
            -o ${OFFSET} > ~{chunk_tag}.vcf && \
        head -10000 ~{chunk_tag}.vcf | grep "^#" >> ~{chunk_tag}.sorted.vcf && \
        if [ "$(cat ~{chunk_tag}.vcf | grep -v '^#')" ]; then
            cat ~{chunk_tag}.vcf | grep -v "^#" | sort -k1,1d -k2,2n >> ~{chunk_tag}.sorted.vcf
        fi
        bgzip ~{chunk_tag}.sorted.vcf && \
        tabix -f -p vcf ~{chunk_tag}.sorted.vcf.gz

        # Compile clipping string
        clipped_chunk_offset="$(( (${CHUNK_TAG_INDEX} * ~{in_chunk_bases}) - (${CHUNK_TAG_INDEX} * ~{in_overlap}) ))"
        if [ "${BED_CHUNK_LINE_RECORD}" = "${FIRST_Q}" ]; then
          START="$(( ${clipped_chunk_offset} + 1 ))"
        else
          START="$(( ${clipped_chunk_offset} + 1 + ~{in_overlap}/2 ))"
        fi
        if [ "${BED_CHUNK_LINE_RECORD}" = "${LAST_Q}" ]; then
          END="$(( ${clipped_chunk_offset} + ~{in_chunk_bases}))"
        else
          END="$(( ${clipped_chunk_offset} + ~{in_chunk_bases} - (~{in_overlap}/2) ))"
        fi
        echo "${PATH_NAME}:${START}-${END}" > ~{chunk_tag}_clip_string.txt
    >>>
    output {
        File output_vcf = "~{chunk_tag}.sorted.vcf.gz"
        File output_vcf_index = "~{chunk_tag}.sorted.vcf.gz.tbi"
        String clip_string = read_lines("~{chunk_tag}_clip_string.txt")[0]
    }
    runtime {
        memory: in_vgcall_mem + " GB"
        cpu: in_vgcall_cores
        disks: "local-disk " + in_vgcall_disk + " SSD"
        docker: in_vg_container
    }
}

task runVCFClipper {
    input {
        File in_chunk_vcf
        File in_chunk_vcf_index
        String in_chunk_clip_string
    }

    String chunk_tag = basename(in_chunk_vcf, ".sorted.vcf.gz")
    command {
        # Set the exit code of a pipeline to that of the rightmost command
        # to exit with a non-zero status, or zero if all commands of the pipeline exit
        set -o pipefail
        # cause a bash script to exit immediately when a command fails
        set -e
        # cause the bash shell to treat unset variables as an error and exit immediately
        set -u
        # echo each line of the script to stdout so we can see what is happening
        set -o xtrace
        #to turn off echo do 'set +o xtrace'

        bcftools view -O b ${in_chunk_vcf} -t ${in_chunk_clip_string} > ${chunk_tag}.clipped.vcf.gz
    }
    output {
        File output_clipped_vcf = "${chunk_tag}.clipped.vcf.gz"
    }
    runtime {
        memory: 50 + " GB"
        disks: "local-disk 100 SSD"
        docker: "quay.io/biocontainers/bcftools:1.9--h4da6232_0"
    }
}

task concatClippedVCFChunks {
    input {
        String in_sample_name
        Array[File] in_clipped_vcf_chunk_files
    }

    command {
        # Set the exit code of a pipeline to that of the rightmost command
        # to exit with a non-zero status, or zero if all commands of the pipeline exit
        set -o pipefail
        # cause a bash script to exit immediately when a command fails
        set -e
        # cause the bash shell to treat unset variables as an error and exit immediately
        set -u
        # echo each line of the script to stdout so we can see what is happening
        set -o xtrace
        #to turn off echo do 'set +o xtrace'

        for vcf_file in ${sep=" " in_clipped_vcf_chunk_files} ; do
            bcftools index "$vcf_file"
        done
        bcftools concat -a ${sep=" " in_clipped_vcf_chunk_files} | bcftools sort - > ${in_sample_name}_merged.vcf
    }
    output {
        File output_merged_vcf = "${in_sample_name}_merged.vcf"
    }
    runtime {
        memory: 50 + " GB"
        disks: "local-disk 100 SSD"
        docker: "quay.io/biocontainers/bcftools:1.9--h4da6232_0"
    }
}

task bgzipMergedVCF {
    input {
        String in_sample_name
        File in_merged_vcf_file
        String in_vg_container
    }

    # TODO:
    #   If GVCF in in_merged_vcf_file then output_vcf_extension="gvcf" else output_vcf_extension="vcf"
    command {
        # Set the exit code of a pipeline to that of the rightmost command
        # to exit with a non-zero status, or zero if all commands of the pipeline exit
        set -o pipefail
        # cause a bash script to exit immediately when a command fails
        set -e
        # cause the bash shell to treat unset variables as an error and exit immediately
        set -u
        # echo each line of the script to stdout so we can see what is happening
        set -o xtrace
        #to turn off echo do 'set +o xtrace'

        bgzip -c ${in_merged_vcf_file} > ${in_sample_name}_merged.vcf.gz && \
        tabix -f -p vcf ${in_sample_name}_merged.vcf.gz
    }
    output {
        File output_merged_vcf = "${in_sample_name}_merged.vcf.gz"
        File output_merged_vcf_index = "${in_sample_name}_merged.vcf.gz.tbi"
    }
    runtime {
        memory: 50 + " GB"
        disks: "local-disk 100 SSD"
        docker: in_vg_container
    }
}

task normalizeVCF {
    input {
        String in_sample_name
        File in_bgzip_vcf_file
    }
    
    command {
        # Set the exit code of a pipeline to that of the rightmost command
        # to exit with a non-zero status, or zero if all commands of the pipeline exit
        set -o pipefail
        # cause a bash script to exit immediately when a command fails
        set -e
        # cause the bash shell to treat unset variables as an error and exit immediately
        set -u
        # echo each line of the script to stdout so we can see what is happening
        set -o xtrace
        #to turn off echo do 'set +o xtrace'

        bcftools norm -m-both --threads 16 -o ${in_sample_name}.unrolled.vcf ${in_bgzip_vcf_file}
    }
    output {
        File output_normalized_vcf = "${in_sample_name}.unrolled.vcf"
    }
    runtime {
        cpu: 16
        memory: 50 + " GB"
        disks: "local-disk 100 SSD"
        docker: "quay.io/biocontainers/bcftools:1.9--h4da6232_0"
    }
}

task snpEffAnnotateVCF {
    input {
        String in_sample_name
        File in_normalized_vcf_file
        File in_snpeff_database
    }
    
    command <<<
        # Set the exit code of a pipeline to that of the rightmost command
        # to exit with a non-zero status, or zero if all commands of the pipeline exit
        set -o pipefail
        # cause a bash script to exit immediately when a command fails
        set -e
        # cause the bash shell to treat unset variables as an error and exit immediately
        set -u
        # echo each line of the script to stdout so we can see what is happening
        set -o xtrace
        #to turn off echo do 'set +o xtrace'
        
        unzip ~{in_snpeff_database}
        snpEff -Xmx40g -i VCF -o VCF -noLof -noHgvs -formatEff -classic -dataDir ${PWD}/data GRCh37.75 ~{in_normalized_vcf_file} > ~{in_sample_name}.snpeff.unrolled.vcf
    >>>
    output {
        File output_snpeff_annotated_vcf = "~{in_sample_name}.snpeff.unrolled.vcf"
    }
    runtime {
        cpu: 16
        memory: 50 + " GB"
        disks: "local-disk 100 SSD"
        docker: "quay.io/biocontainers/snpeff:4.3.1t--2"
    }
}

