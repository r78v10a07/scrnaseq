#!/usr/bin/env nextflow
/*
========================================================================================
                         nf-core/scrnaseq
========================================================================================
 nf-core/scrnaseq Analysis Pipeline.
 #### Homepage / Documentation
 https://github.com/nf-core/scrnaseq
----------------------------------------------------------------------------------------
*/


def helpMessage() {
    log.info nfcoreHeader()
    log.info"""

    Usage:

    The typical command for running the pipeline is as follows:

    nextflow run nf-core/scrnaseq --reads '*_R{1,2}.fastq.gz' -profile docker

    Mandatory arguments:
      --reads                       Path to input data (must be surrounded with quotes)
      -profile                      Configuration profile to use. Can use multiple (comma separated)
                                    Available: conda, docker, singularity, awsbatch, test and more.
      --type                        Name of droplet technology e.g. "--type 10x". Currently supported: 10x
      --chemistry                   Version of 10x chemistry, e.g. "--chemistry v2" or "--chemistry v3"
      --barcode_whitelist           Custom file of whitelisted barcodes
      --aligner                     Name of the tool to use for scRNA (pseudo-) alignment. Available are: "alevin", "star", "kallisto". Default 'alevin'.

    Alevin Options:
      --salmon_index                Path to Salmon index
      --txp2gene                    Path to transcript to gene mapping file

    STARSolo Options:
      --star_index                  Path to STARSolo index

    Kallisto/BUS Options:
      --kallisto_gene_map           A gene map used for bustools correction of BUS files created by Kallisto
      --bustools_correct            Perform BUS correction step in BUSTools
      --skip_bustools               Skip BUStools entirely in workflow
      --kallisto_index              Supply precomputed Kallisto index to pipeline

    References                      If not specified in the configuration file or you wish to overwrite any of the references.
      --genome                      Use iGenomes genome Fasta references
      --fasta                       Path to **genome** Fasta reference file
      --gtf                         Path to gtf file
      --transcriptome_fasta         Path to **transcriptome** Fasta reference file
      --save_reference              Save indexed reference genomes in results

    Other options:
      --outdir                      The output directory where the results will be saved
      --email                       Set this parameter to your e-mail address to get a summary e-mail with details of the run sent to you when the workflow exits
      --max_multiqc_email_size     Theshold size for MultiQC report to be attached in notification email. If file generated by pipeline exceeds the threshold, it will not be attached (Default: 25MB)
      -name                         Name for the pipeline run. If not specified, Nextflow will automatically generate a random mnemonic.
      --igenomes_ignore             Ignore iGenomes reference data

    AWSBatch options:
      --awsqueue                    The AWSBatch JobQueue that needs to be set when running on AWSBatch
      --awsregion                   The AWS Region for your AWS Batch job to run on
    """.stripIndent()
}

/*
 * SET UP CONFIGURATION VARIABLES
 */

// Show help emssage
if (params.help){
    helpMessage()
    exit 0
}

// Check if genome exists in the config file
if (params.genomes && params.genome && !params.genomes.containsKey(params.genome)) {
    exit 1, "The provided genome '${params.genome}' is not available in the iGenomes file. Currently the available genomes are ${params.genomes.keySet().join(", ")}"
}


//Check if one of the available aligners is used (alevin, kallisto, star)
if (params.aligner != 'star' && params.aligner != 'alevin' && params.aligner != 'kallisto'){
    exit 1, "Invalid aligner option: ${params.aligner}. Valid options: 'star', 'alevin', 'kallisto'"
}
//Check if STAR index is supplied properly
if( params.star_index && params.aligner == 'star' ){
    star_index = Channel
        .fromPath(params.star_index)
        .ifEmpty { exit 1, "STAR index not found: ${params.star_index}" }
}

//Check if GTF is supplied properly
if( params.gtf ){
    Channel
        .fromPath(params.gtf)
        .ifEmpty { exit 1, "GTF annotation file not found: ${params.gtf}" }
        .into { gtf_extract_transcriptome; gtf_alevin; gtf_makeSTARindex; gtf_star; gtf_gene_map }
} else if (params.aligner == 'star'){
  exit 1, "Must provide a GTF file ('--gtf') to align with STAR"
}

//Check if TXP2Gene is provided for Alevin
if (!params.gtf && !params.txp2gene){
  exit 1, "Must provide either a GTF file ('--gtf') or transcript to gene mapping ('--txp2gene') to align with Alevin"
}

//Check if a transcriptome FastA or at least a Genome FastA is provided!
if (!params.fasta && !params.transcript_fasta){
  exit 1, "Neither of --fasta or --transcriptome provided! At least one must be provided to quantify genes"
}

//Setup FastA channels
if( params.fasta ){
    Channel
        .fromPath(params.fasta)
        .ifEmpty { exit 1, "Fasta file not found: ${params.fasta}" }
        .into { genome_fasta_extract_transcriptome ; genome_fasta_makeSTARindex }
} else {
  genome_fasta_extract_transcriptome = Channel.empty()
  genome_fasta_makeSTARindex = Channel.empty()
}
//Setup Transcript FastA channels
if( params.transcript_fasta ){
  if( params.aligner == "star" && !params.fasta) {
    exit 1, "Transcriptome-only alignment is not valid with the aligner: ${params.aligner}. Transcriptome-only alignment is only valid with '--aligner alevin'"
  }
    Channel
        .fromPath(params.transcript_fasta)
        .ifEmpty { exit 1, "Fasta file not found: ${params.transcript_fasta}" }
        .into { transcriptome_fasta_alevin; transcriptome_fasta_kallisto }
} else {
  transcriptome_fasta_alevin = Channel.empty()
  transcriptome_fasta_kallisto = Channel.empty()
}

//Setup channel for salmon index if specified
if (params.aligner == 'alevin' && params.salmon_index) {
    Channel
        .fromPath(params.salmon_index)
        .ifEmpty { exit 1, "Salmon index not found: ${params.salmon_index}" }
        .set { salmon_index_alevin }
}

// Has the run name been specified by the user?
//  this has the bonus effect of catching both -name and --name
custom_runName = params.name
if( !(workflow.runName ==~ /[a-z]+_[a-z]+/) ){
  custom_runName = workflow.runName
}


if( workflow.profile == 'awsbatch') {
  // AWSBatch sanity checking
  if (!params.awsqueue || !params.awsregion) exit 1, "Specify correct --awsqueue and --awsregion parameters on AWSBatch!"
  // Check outdir paths to be S3 buckets if running on AWSBatch
  // related: https://github.com/nextflow-io/nextflow/issues/813
  if (!params.outdir.startsWith('s3:')) exit 1, "Outdir not on S3 - specify S3 Bucket to run on AWSBatch!"
  // Prevent trace files to be stored on S3 since S3 does not support rolling files.
  if (params.tracedir.startsWith('s3:')) exit 1, "Specify a local tracedir or run without trace! S3 cannot be used for tracefiles."
}

// Stage config files
ch_multiqc_config = Channel.fromPath(params.multiqc_config)
ch_output_docs = Channel.fromPath("$baseDir/docs/output.md")

/*
 * Create a channel for input read files
 */

 if(params.readPaths){
         Channel
             .from(params.readPaths)
             .map { row -> [ row[0], [file(row[1][0]), file(row[1][1])]] }
             .ifEmpty { exit 1, "params.readPaths was empty - no input files supplied" }
             .into { read_files_alevin; read_files_star; read_files_kallisto}
     } else {
         Channel
            .fromFilePairs( params.reads )
            .ifEmpty { exit 1, "Cannot find any reads matching: ${params.reads}\nNB: Path needs to be enclosed in quotes!\nNB: Path requires at least one * wildcard!\n" }
            .into { read_files_alevin; read_files_star; read_files_kallisto }
}

//Whitelist files for STARsolo and Kallisto
whitelist_folder = "$baseDir/assets/whitelist/"

//Automatically set up proper filepaths to the barcode whitelist files bundled with the pipeline
if (params.type == "10x" && !params.barcode_whitelist){
  barcode_filename = "$whitelist_folder/${params.type}_${params.chemistry}_barcode_whitelist.txt.gz"
  Channel.fromPath(barcode_filename)
         .ifEmpty{ exit 1, "Cannot find ${params.type} barcode whitelist: $barcode_filename" }
         .set{ barcode_whitelist_gzipped }
  Channel.empty().into{ barcode_whitelist_star; barcode_whitelist_kallisto; barcode_whitelist_alevinqc }
} else if (params.barcode_whitelist){
  Channel.fromPath(params.barcode_whitelist)
         .ifEmpty{ exit 1, "Cannot find ${params.type} barcode whitelist: $barcode_filename" }
         .into{ barcode_whitelist_star; barcode_whitelist_kallisto; barcode_whitelist_alevinqc }
  barcode_whitelist_gzipped = Channel.empty()
}


// Header log info
log.info nfcoreHeader()
def summary = [:]
if(workflow.revision) summary['Pipeline Release'] = workflow.revision
summary['Run Name']         = custom_runName ?: workflow.runName
summary['Reads']            = params.reads
if(params.fasta)         summary['Genome Reference']        = params.fasta
if(params.transcriptome_fasta)  summary['Transcriptome Reference']        = params.transcriptome_fasta
summary['GTF Reference']        = params.gtf
summary['Save Reference?'] = params.save_reference
summary['Aligner']        = params.aligner
if (params.salmon_index)        summary['Salmon Index']        = params.salmon_index
if (params.star_index) summary['STARsolo Index'] = params.star_index
if (params.kallisto_index) summary['Kallisto Index'] = params.kallisto_index
summary['Droplet Technology'] = params.type
summary['Chemistry Version'] = params.chemistry
if (params.aligner == 'alevin') summary['Alevin TXP2Gene']        = params.txp2gene
if (params.aligner == 'kallisto') summary['Kallisto Gene Map']        = params.kallisto_gene_map
if(params.aligner == 'kallisto') summary['BUSTools Correct'] = params.bustools_correct
summary['Max Resources']    = "$params.max_memory memory, $params.max_cpus cpus, $params.max_time time per job"
if(workflow.containerEngine) summary['Container'] = "$workflow.containerEngine - $workflow.container"
summary['Output dir']       = params.outdir
summary['Launch dir']       = workflow.launchDir
summary['Working dir']      = workflow.workDir
summary['Script dir']       = workflow.projectDir
summary['User']             = workflow.userName
if(workflow.profile == 'awsbatch'){
   summary['AWS Region']    = params.awsregion
   summary['AWS Queue']     = params.awsqueue
}
summary['Config Profile'] = workflow.profile
if(params.config_profile_description) summary['Config Description'] = params.config_profile_description
if(params.config_profile_contact)     summary['Config Contact']     = params.config_profile_contact
if(params.config_profile_url)         summary['Config URL']         = params.config_profile_url
if(params.email) {
  summary['E-mail Address']  = params.email
  summary['MultiQC maxsize'] = params.max_multiqc_email_size
}
log.info summary.collect { k,v -> "${k.padRight(18)}: $v" }.join("\n")
log.info "-\033[2m--------------------------------------------------\033[0m-"

// Check the hostnames against configured profiles
checkHostname()

def create_workflow_summary(summary) {
    def yaml_file = workDir.resolve('workflow_summary_mqc.yaml')
    yaml_file.text  = """
    id: 'nf-core-scrnaseq-summary'
    description: " - this information is collected when the pipeline is started."
    section_name: 'nf-core/scrnaseq Workflow Summary'
    section_href: 'https://github.com/nf-core/scrnaseq'
    plot_type: 'html'
    data: |
        <dl class=\"dl-horizontal\">
${summary.collect { k,v -> "            <dt>$k</dt><dd><samp>${v ?: '<span style=\"color:#999999;\">N/A</a>'}</samp></dd>" }.join("\n")}
        </dl>
    """.stripIndent()

   return yaml_file
}


/*
 * Parse software version numbers
 */
process get_software_versions {
    publishDir "${params.outdir}/pipeline_info", mode: 'copy',
    saveAs: {filename ->
        if (filename.indexOf(".csv") > 0) filename
        else null
    }

    output:
    file 'software_versions_mqc.yaml' into software_versions_yaml
    file "software_versions.csv"

    script:
    """
    echo $workflow.manifest.version &> v_pipeline.txt
    echo $workflow.nextflow.version &> v_nextflow.txt
    salmon --version &> v_salmon.txt 2>&1 || true
    STAR --version &> v_star.txt 2>&1 || true
    multiqc --version &> v_multiqc.txt 2>&1 || true
    kallisto version &> v_kallisto.txt 2>&1 || true
    bustools &> v_bustools.txt 2>&1 || true

    scrape_software_versions.py > software_versions_mqc.yaml
    """
}

/*
* Preprocessing - Unzip 10X barcodes if they are supplied compressed
*/ 
process unzip_10x_barcodes {
    tag "${params.chemistry}"
    publishDir "${params.outdir}/reference_data/barcodes", mode: 'copy'

    input:
    file gzipped from barcode_whitelist_gzipped

    output:
    file "${gzipped.simpleName}" into (barcode_whitelist_star_unzip, barcode_whitelist_kallisto_unzip, barcode_whitelist_alevinqc_unzip)

    when: params.type == '10x' && !params.barcode_whitelist

    script:
    """
    gunzip -c $gzipped > ${gzipped.simpleName}
    """
}


/*
 * Preprocessing - Extract transcriptome fasta from genome fasta
 */

process extract_transcriptome {
    tag "${genome_fasta}"
    publishDir "${params.outdir}/reference_data/extract_transcriptome", mode: 'copy'

    input:
    file genome_fasta from genome_fasta_extract_transcriptome
    file gtf from gtf_extract_transcriptome

    output:
    file "${genome_fasta}.transcriptome.fa" into (transcriptome_fasta_alevin_extracted, transcriptome_fasta_kallisto_extracted)

    when: !params.transcript_fasta && (params.aligner == 'alevin' || params.aligner == 'kallisto')
    script:
    // -F to preserve all GTF attributes in the fasta ID
    """
    gffread -F $gtf -w "${genome_fasta}.transcriptome.fa" -g $genome_fasta
    """
}

/*
 * STEP 1 - Make_index
 */

process build_salmon_index {
    tag "$fasta"
    label 'low_memory'
    publishDir path: { params.save_reference ? "${params.outdir}/reference_genome/salmon_index" : params.outdir },
                saveAs: { params.save_reference ? it : null }, mode: 'copy'

    when:
    params.aligner == 'alevin' && !params.salmon_index

    input:
    file fasta from transcriptome_fasta_alevin.mix(transcriptome_fasta_alevin_extracted)

    output:
    file "salmon_index" into salmon_index_alevin

    when: params.aligner == 'alevin' && !params.salmon_index

    script:
    """
    salmon index -i salmon_index --gencode -k 31 -p 4 -t $fasta
    """
}


//Create a STAR index if not supplied via --star_index
process makeSTARindex {
    label 'high_memory'
    tag "$fasta"
    publishDir path: { params.save_reference ? "${params.outdir}/reference_genome/star_index" : params.outdir },
                saveAs: { params.save_reference ? it : null }, mode: 'copy'

    when: 
    params.aligner == 'star' && !params.star_index
    
    input:
    file fasta from genome_fasta_makeSTARindex
    file gtf from gtf_makeSTARindex

    output:
    file "star" into star_index_created

    script:
    def avail_mem = task.memory ? "--limitGenomeGenerateRAM ${task.memory.toBytes() - 100000000}" : ''
    """
    mkdir star
    STAR \\
        --runMode genomeGenerate \\
        --runThreadN ${task.cpus} \\
        --sjdbGTFfile $gtf \\
        --genomeDir star/ \\
        --genomeFastaFiles $fasta \\
        $avail_mem
    """
}

/*
* Preprocessing - Generate Kallisto Index if not supplied via --kallisto_index
*/ 
process build_kallisto_index {
    tag "$fasta"
    label 'mid_memory'
    publishDir path: { params.save_reference ? "${params.outdir}/reference_genome/kallisto_index" : params.outdir },
                saveAs: { params.save_reference ? it : null }, mode: 'copy'
    input:
    file fasta from transcriptome_fasta_kallisto.mix(transcriptome_fasta_kallisto_extracted)

    output:
    file "${name}.idx" into kallisto_index

    when: params.aligner == 'kallisto' && !params.kallisto_index

    script:
    if("${fasta}".endsWith('.gz')){
      name = "${fasta.baseName}"
      unzip = "gunzip -f ${fasta}"
    } else {
      unzip = ""
      name = "${fasta}"
    }
    """
    $unzip
    kallisto index -i ${name}.idx -k 31 $name
    """
}

/*
* Preprocessing - Generate a Kallisto Gene Map if not supplied via --kallisto_gene_map
*/ 
process build_gene_map{
    tag "$gtf"
    publishDir "${params.outdir}/kallisto/kallisto_gene_map", mode: 'copy'

    input:
    file gtf from gtf_gene_map

    output:
    file "transcripts_to_genes.txt" into kallisto_gene_map

    when: params.aligner == 'kallisto' && !params.kallisto_gene_map

    script:
    if("${gtf}".endsWith('.gz')){
      name = "${gtf.baseName}"
      unzip = "gunzip -f ${gtf}"
    } else {
      unzip = ""
      name = "${gtf}"
    }
    """
    $unzip
    cat $name | t2g.py --use_version > transcripts_to_genes.txt
    """
}


/*
* Preprocessing - Generate TXP2Gene if not supplied via --txp2gene_alevin
*/
process build_txp2gene {
    tag "$gtf"
    publishDir "${params.outdir}/reference_data/alevin/", mode: 'copy'

    input:
    file gtf from gtf_alevin

    output:
    file "txp2gene.tsv" into txp2gene_alevin

    when:
    params.aligner == 'alevin' && !params.txp2gene_alevin

    script:

    """
    bioawk -c gff '\$feature=="transcript" {print \$group}' $gtf | awk -F ' ' '{print substr(\$4,2,length(\$4)-3) "\t" substr(\$2,2,length(\$2)-3)}' > txp2gene.tsv
    """
}

/*
* Run Salmon Alevin
*/
process alevin {
    tag "$name"
    label 'high_memory'
    publishDir "${params.outdir}/alevin/alevin", mode: 'copy'

    input:
    set val(name), file(reads) from read_files_alevin
    file index from salmon_index_alevin.collect()
    file txp2gene from txp2gene_alevin.collect()

    output:
    file "${name}_alevin_results" into alevin_results, alevin_logs

    when:
    params.aligner == "alevin"

    script:
    read1 = reads[0]
    read2 = reads[1]
    """
    salmon alevin -l ISR -1 ${read1} -2 ${read2} \
      --chromium -i $index -o ${name}_alevin_results -p ${task.cpus} --tgMap $txp2gene --dumpFeatures –-dumpMtx
    """
}

/*
* Run Alevin QC 
*/

process alevin_qc {
    tag "$prefix"
    publishDir "${params.outdir}/alevin/alevin_qc", mode: 'copy'
  
    when:
    params.aligner == "alevin"
  
    input:
    file result from alevin_results
    file whitelist from barcode_whitelist_alevinqc.mix(barcode_whitelist_alevinqc_unzip).collect()
  
    output:
    file "${result}" into alevinqc_results
  
    script:
    prefix = result.toString() - '_alevin_results'
    """
    mv $whitelist ${result}/alevin/whitelist.txt
    alevin_qc.r $result ${prefix} $result
    """
}

process star {
    label 'high_memory'

    tag "$prefix"
    publishDir "${params.outdir}/STAR", mode: 'copy'

    input:
    set val(samplename), file(reads) from read_files_star
    file index from star_index.collect()
    file gtf from gtf_star.collect()
    file whitelist from barcode_whitelist_star.mix(barcode_whitelist_star_unzip).collect()

    output:
    set file("*Log.final.out"), file ('*.bam') into star_aligned
    file "*.out" into alignment_logs
    file "*SJ.out.tab"
    file "*Log.out" into star_log
    file "${prefix}Aligned.sortedByCoord.out.bam.bai" into bam_index_rseqc, bam_index_genebody

    when: params.aligner == 'star'

    script:
    prefix = reads[0].toString() - ~/(_R1)?(_trimmed)?(_val_1)?(\.fq)?(\.fastq)?(\.gz)?$/
    def star_mem = task.memory ?: params.star_memory ?: false
    def avail_mem = star_mem ? "--limitBAMsortRAM ${star_mem.toBytes() - 100000000}" : ''

    seq_center = params.seq_center ? "--outSAMattrRGline ID:$prefix 'CN:$params.seq_center'" : ''
    cdna_read = reads[0]
    barcode_read = reads[1]
    """
    STAR --genomeDir $index \\
          --sjdbGTFfile $gtf \\
          --readFilesIn $barcode_read $cdna_read  \\
          --runThreadN ${task.cpus} \\
          --twopassMode Basic \\
          --outWigType bedGraph \\
          --outSAMtype BAM SortedByCoordinate $avail_mem \\
          --readFilesCommand zcat \\
          --runDirPerm All_RWX \\
          --outFileNamePrefix $prefix $seq_center \\
          --soloType Droplet \\
          --soloCBwhitelist $whitelist

    samtools index ${prefix}Aligned.sortedByCoord.out.bam
    """
}

// get output flattened for other downstream processes
star_aligned
    .flatMap {  logs, bams -> bams }
.into { bam_count; bam_rseqc; bam_preseq; bam_markduplicates; bam_htseqcount; bam_stringtieFPKM; bam_for_genebody; bam_dexseq; leafcutter_bam }

/*
* Run Kallisto Workflow
*/
process kallisto {
    tag "$name"
    label 'mid_memory'
    publishDir "${params.outdir}/kallisto/raw_bus", mode: 'copy'

    input:
    set val(name), file(reads) from read_files_kallisto
    file index from kallisto_index.collect()

    output:
    file "${name}_bus_output" into kallisto_bus_to_sort
    file "${name}_kallisto.log" into kallisto_log_for_multiqc

    when: params.aligner == 'kallisto'

    script:
    """
    kallisto bus \\
        -i $index \\
        -o ${name}_bus_output/ \\
        -x ${params.type}${params.chemistry} \\
        -t ${task.cpus} \\
        $reads | tee ${name}_kallisto.log
    """
}
/*
* Run BUSTools Correct / Sort on Kallisto Output
*/
process bustools_correct_sort{
    tag "$bus"
    label 'mid_memory'
    publishDir "${params.outdir}/kallisto/sort_bus", mode: 'copy'

    input:
    file bus from kallisto_bus_to_sort
    file whitelist from barcode_whitelist_kallisto.mix(barcode_whitelist_kallisto_unzip).collect()

    output:
    file bus into (kallisto_corrected_sort_to_count, kallisto_corrected_sort_to_metrics)

    when: !params.skip_bustools

    script:
    if(params.bustools_correct) {
      correct = "bustools correct -w $whitelist -o ${bus}/output.corrected.bus ${bus}/output.bus"
      sort_file = "${bus}/output.corrected.bus"
    } else {
      correct = ""
      sort_file = "${bus}/output.bus"
    }
    """
    $correct    
    mkdir -p tmp
    bustools sort -T tmp/ -t ${task.cpus} -m ${task.memory.toGiga()}G -o ${bus}/output.corrected.sort.bus $sort_file
    """
}

/*
* Run BUSTools count on sorted/corrected output from Kallisto|Bus 
*/
process bustools_count{
    tag "$bus"
    label 'mid_memory'
    publishDir "${params.outdir}/kallisto/bustools_counts", mode: "copy"

    input:
    file bus from kallisto_corrected_sort_to_count
    file t2g from kallisto_gene_map.collect()

    output:
    file "${bus}_eqcount"
    file "${bus}_genecount"

    script:
    """
    mkdir -p ${bus}_eqcount
    mkdir -p ${bus}_genecount
    bustools count -o ${bus}_eqcount/tcc -g $t2g -e ${bus}/matrix.ec -t ${bus}/transcripts.txt ${bus}/output.corrected.sort.bus
    bustools count -o ${bus}_genecount/gene -g $t2g -e ${bus}/matrix.ec -t ${bus}/transcripts.txt --genecounts ${bus}/output.corrected.sort.bus
    """
}

/*
* Run Bustools inspect
*/

process bustools_inspect{
    tag "$bus"
    publishDir "${params.outdir}/kallisto/bustools_metrics", mode: "copy"

    input:
    file bus from kallisto_corrected_sort_to_metrics

    output:
    file "${bus}.json"

    script:
    """
    bustools inspect -o ${bus}.json ${bus}/output.corrected.sort.bus
    """
}

/*
 * Run MultiQC on results / logfiles 
 */
process multiqc {
    publishDir "${params.outdir}/MultiQC", mode: 'copy'

    input:
    file multiqc_config from ch_multiqc_config
    file ('software_versions/*') from software_versions_yaml
    file workflow_summary from create_workflow_summary(summary)
    file ('STAR/*') from star_log.collect().ifEmpty([])
    file ('alevin/*') from alevin_logs.collect().ifEmpty([])
    file ('kallisto/*') from kallisto_log_for_multiqc.collect().ifEmpty([])

    output:
    file "*multiqc_report.html" into multiqc_report
    file "*_data"

    script:
    rtitle = custom_runName ? "--title \"$custom_runName\"" : ''
    rfilename = custom_runName ? "--filename " + custom_runName.replaceAll('\\W','_').replaceAll('_+','_') + "_multiqc_report" : ''
    """
    multiqc -f $rtitle $rfilename --config $multiqc_config \
      -m custom_content -m salmon -m star -m kallisto .
    """
}

/*
 * Output Description HTML
 */
process output_documentation {
    publishDir "${params.outdir}/pipeline_info", mode: 'copy'

    input:
    file output_docs from ch_output_docs

    output:
    file "results_description.html"

    script:
    """
    markdown_to_html.r $output_docs results_description.html
    """
}

/*
 * Completion e-mail notification
 */
workflow.onComplete {

    // Set up the e-mail variables
    def subject = "[nf-core/scrnaseq] Successful: $workflow.runName"
    if(!workflow.success){
      subject = "[nf-core/scrnaseq] FAILED: $workflow.runName"
    }
    def email_fields = [:]
    email_fields['version'] = workflow.manifest.version
    email_fields['runName'] = custom_runName ?: workflow.runName
    email_fields['success'] = workflow.success
    email_fields['dateComplete'] = workflow.complete
    email_fields['duration'] = workflow.duration
    email_fields['exitStatus'] = workflow.exitStatus
    email_fields['errorMessage'] = (workflow.errorMessage ?: 'None')
    email_fields['errorReport'] = (workflow.errorReport ?: 'None')
    email_fields['commandLine'] = workflow.commandLine
    email_fields['projectDir'] = workflow.projectDir
    email_fields['summary'] = summary
    email_fields['summary']['Date Started'] = workflow.start
    email_fields['summary']['Date Completed'] = workflow.complete
    email_fields['summary']['Pipeline script file path'] = workflow.scriptFile
    email_fields['summary']['Pipeline script hash ID'] = workflow.scriptId
    if(workflow.repository) email_fields['summary']['Pipeline repository Git URL'] = workflow.repository
    if(workflow.commitId) email_fields['summary']['Pipeline repository Git Commit'] = workflow.commitId
    if(workflow.revision) email_fields['summary']['Pipeline Git branch/tag'] = workflow.revision
    if(workflow.container) email_fields['summary']['Docker image'] = workflow.container
    email_fields['summary']['Nextflow Version'] = workflow.nextflow.version
    email_fields['summary']['Nextflow Build'] = workflow.nextflow.build
    email_fields['summary']['Nextflow Compile Timestamp'] = workflow.nextflow.timestamp

    // On success try attach the multiqc report
    def mqc_report = null
    try {
        if (workflow.success) {
            mqc_report = multiqc_report.getVal()
            if (mqc_report.getClass() == ArrayList){
                log.warn "[nf-core/scrnaseq] Found multiple reports from process 'multiqc', will use only one"
                mqc_report = mqc_report[0]
            }
        }
    } catch (all) {
        log.warn "[nf-core/scrnaseq] Could not attach MultiQC report to summary email"
    }

    // Render the TXT template
    def engine = new groovy.text.GStringTemplateEngine()
    def tf = new File("$baseDir/assets/email_template.txt")
    def txt_template = engine.createTemplate(tf).make(email_fields)
    def email_txt = txt_template.toString()

    // Render the HTML template
    def hf = new File("$baseDir/assets/email_template.html")
    def html_template = engine.createTemplate(hf).make(email_fields)
    def email_html = html_template.toString()

    // Render the sendmail template
    def smail_fields = [ email: params.email, subject: subject, email_txt: email_txt, email_html: email_html, baseDir: "$baseDir", mqcFile: mqc_report, mqcMaxSize: params.max_multiqc_email_size.toBytes() ]
    def sf = new File("$baseDir/assets/sendmail_template.txt")
    def sendmail_template = engine.createTemplate(sf).make(smail_fields)
    def sendmail_html = sendmail_template.toString()

    // Send the HTML e-mail
    if (params.email) {
        try {
          if( params.plaintext_email ){ throw GroovyException('Send plaintext e-mail, not HTML') }
          // Try to send HTML e-mail using sendmail
          [ 'sendmail', '-t' ].execute() << sendmail_html
          log.info "[nf-core/scrnaseq] Sent summary e-mail to $params.email (sendmail)"
        } catch (all) {
          // Catch failures and try with plaintext
          [ 'mail', '-s', subject, params.email ].execute() << email_txt
          log.info "[nf-core/scrnaseq] Sent summary e-mail to $params.email (mail)"
        }
    }

    // Write summary e-mail HTML to a file
    def output_d = new File( "${params.outdir}/pipeline_info/" )
    if( !output_d.exists() ) {
      output_d.mkdirs()
    }
    def output_hf = new File( output_d, "pipeline_report.html" )
    output_hf.withWriter { w -> w << email_html }
    def output_tf = new File( output_d, "pipeline_report.txt" )
    output_tf.withWriter { w -> w << email_txt }

    c_reset = params.monochrome_logs ? '' : "\033[0m";
    c_purple = params.monochrome_logs ? '' : "\033[0;35m";
    c_green = params.monochrome_logs ? '' : "\033[0;32m";
    c_red = params.monochrome_logs ? '' : "\033[0;31m";

    if (workflow.stats.ignoredCount > 0 && workflow.success) {
      log.info "${c_purple}Warning, pipeline completed, but with errored process(es) ${c_reset}"
      log.info "${c_red}Number of ignored errored process(es) : ${workflow.stats.ignoredCount} ${c_reset}"
      log.info "${c_green}Number of successfully ran process(es) : ${workflow.stats.succeedCountFmt} ${c_reset}"
    }

    if(workflow.success){
        log.info "${c_purple}[nf-core/scrnaseq]${c_green} Pipeline completed successfully${c_reset}"
    } else {
        checkHostname()
        log.info "${c_purple}[nf-core/scrnaseq]${c_red} Pipeline completed with errors${c_reset}"
    }

}


def nfcoreHeader(){
    // Log colors ANSI codes
    c_reset = params.monochrome_logs ? '' : "\033[0m";
    c_dim = params.monochrome_logs ? '' : "\033[2m";
    c_black = params.monochrome_logs ? '' : "\033[0;30m";
    c_green = params.monochrome_logs ? '' : "\033[0;32m";
    c_yellow = params.monochrome_logs ? '' : "\033[0;33m";
    c_blue = params.monochrome_logs ? '' : "\033[0;34m";
    c_purple = params.monochrome_logs ? '' : "\033[0;35m";
    c_cyan = params.monochrome_logs ? '' : "\033[0;36m";
    c_white = params.monochrome_logs ? '' : "\033[0;37m";

    return """    ${c_dim}----------------------------------------------------${c_reset}
                                            ${c_green},--.${c_black}/${c_green},-.${c_reset}
    ${c_blue}        ___     __   __   __   ___     ${c_green}/,-._.--~\'${c_reset}
    ${c_blue}  |\\ | |__  __ /  ` /  \\ |__) |__         ${c_yellow}}  {${c_reset}
    ${c_blue}  | \\| |       \\__, \\__/ |  \\ |___     ${c_green}\\`-._,-`-,${c_reset}
                                            ${c_green}`._,._,\'${c_reset}
    ${c_purple}  nf-core/scrnaseq v${workflow.manifest.version}${c_reset}
    ${c_dim}----------------------------------------------------${c_reset}
    """.stripIndent()
}

def checkHostname(){
    def c_reset = params.monochrome_logs ? '' : "\033[0m"
    def c_white = params.monochrome_logs ? '' : "\033[0;37m"
    def c_red = params.monochrome_logs ? '' : "\033[1;91m"
    def c_yellow_bold = params.monochrome_logs ? '' : "\033[1;93m"
    if(params.hostnames){
        def hostname = "hostname".execute().text.trim()
        params.hostnames.each { prof, hnames ->
            hnames.each { hname ->
                if(hostname.contains(hname) && !workflow.profile.contains(prof)){
                    log.error "====================================================\n" +
                            "  ${c_red}WARNING!${c_reset} You are running with `-profile $workflow.profile`\n" +
                            "  but your machine hostname is ${c_white}'$hostname'${c_reset}\n" +
                            "  ${c_yellow_bold}It's highly recommended that you use `-profile $prof${c_reset}`\n" +
                            "============================================================"
                }
            }
        }
    }
}
