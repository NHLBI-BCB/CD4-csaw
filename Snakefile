import os
import os.path
import rpy2.rinterface
import re
import shutil
import subprocess
import sys

import numpy as np
import pandas as pd

from atomicwrites import atomic_write, AtomicWriter
from subprocess import check_call, Popen, PIPE, CalledProcessError, list2cmdline
from rpy2 import robjects
from rpy2.robjects import r, pandas2ri
from rpy2.robjects import globalenv as r_env
from warnings import warn

from snakemake.io import expand
from snakemake.utils import min_version
min_version('3.7.1')

from snakemake.remote.HTTP import RemoteProvider as HTTPRemoteProvider
from snakemake.remote.FTP import RemoteProvider as FTPRemoteProvider

HTTP = HTTPRemoteProvider()
FTP = FTPRemoteProvider()

exec(open("tool_versions.py").read())

pandas2ri.activate()
rpy2.rinterface.set_writeconsole_warnerror(lambda x: sys.stderr.write(x))

fastq_compression_cmds = {
    'fq.gz': {
        'compress': ['gzip', '-c'],
        'decompress': ['gzip', '-d', '-c'],
    },
    'fq.bz2': {
        'compress': ['bzip2', '-z', '-c'],
        'decompress': ['bzip2', '-d', '-c'],
    },
    'fq.qp': {
        'compress': ['quip', '-i', 'fastq', '-o', 'quip', '-c' ],
        'decompress': ['quip', '-i', 'quip', '-o', 'fastq', '-c' ],
    },
    # i.e. no compression
    'fq': {
        'compress': ['cat'],
        'decompress': ['cat'],
    },
}

def ensure_dir(path):
    os.makedirs(path, exist_ok=True)
def ensure_empty_dir(path):
    if os.path.exists(path):
        shutil.rmtree(path)
    ensure_dir(path)

def Popen_pipeline(cmds, stdin=None, stdout=None, *args, **kwargs):
    '''Popen a pipeline of several commands.

    Returns a list with all the process objects returned by Popen.

    Each command's stdout becomes the next command's stdin. The stdin
    argument becomes the stdin of the first command, while the stdout
    argument becomes the stdout of the last command. All other
    arguments are passed to every invocation of Popen, so ensure that
    they make sense in that context.

    '''
    cmds = list(cmds)
    if len(cmds) == 0:
        raise ValueError('Cannot run a pipeline with zero commands')
    if len(cmds) == 1:
        return [Popen(cmds[0], stdin=stdin, stdout=stdout, *args, **kwargs)]
    else:
        first_cmd = cmds[0]
        last_cmd = cmds[-1]
        middle_cmds = cmds[1:-1]
        proclist = [Popen(first_cmd, stdin=stdin, stdout=PIPE, *args, **kwargs)]
        for cmd in middle_cmds:
            prev_cmd_stdout = proclist[-1].stdout
            proclist.append(Popen(cmd, stdin=prev_cmd_stdout, stdout=PIPE, *args, **kwargs))
        prev_cmd_stdout = proclist[-1].stdout
        proclist.append(Popen(last_cmd, stdin=prev_cmd_stdout, stdout=stdout, *args, **kwargs))
        return proclist

def wait_for_subprocs(proclist, expected_exitcodes=0, wait_for_all=True):
    '''Wait for a list of subprocesses to exit.

    If any subprocess returns an exit code that is not in
    expected_exitcodes (default: only 0), a CalledProcessError is
    raised (as if subprocess.check_call was run). Even if an exception
    is raised, this function will still wait for all remaining
    processes to finish unless wait_for_all is False.

    '''
    # Allow supplying a single number or a list of numbers
    try:
        0 in expected_exitcodes
    except TypeError:
        expected_exitcodes = [ expected_exitcodes ]
    if wait_for_all:
        for proc in proclist:
            proc.wait()
    for proc in proclist:
        exitcode = proc.wait()
        if exitcode not in expected_exitcodes:
            raise CalledProcessError(exitcode, proc.args)

def read_R_dataframe(rdsfile):
    '''Read an R data frame stored in an RDS file.

    Returns the result as a Pandas DataFrame.

    '''
    readRDS = robjects.r('readRDS')
    df = readRDS((robjects.StrVector([rdsfile])))
    return(pandas2ri.ri2py(df))

# TODO: Does a function like this already exist in pandas?
def dfselect(dframe, what=None, where=None, **where_kwargs):
    '''Filter DataFrame and select columns.

    First, the DataFrame is filtered according to the 'where'
    arguments. Each key (or keyword argument) in 'where' should be a
    column name, and its value should be the allowed value or values
    for that column. Rows will be selected if they match all the
    requirements in 'where'. Each filter can also be a callable, which
    should take a single value and return True for including that
    value and False for excluding it.

    Second, if 'what' is not None, it will be used to select one or
    more columns. As normal, using a single string returns a Series
    object, while using a list of strings returns a DataFrame with a
    subset of columns selected.

    '''
    if where is None:
        where = dict()
    where.update(where_kwargs)
    if where:
        selected = pd.Series(True, index=dframe.index)
        for (colname, allowed_vals) in where.items():
            if callable(allowed_vals):
                allow_func = allowed_vals
                allowed_rows = [allow_func(x) for x in dframe[colname]]
            else:
                try:
                    allowed_vals = pd.Series(allowed_vals)
                except TypeError:
                    allowed_vals = pd.Series(list(allowed_vals))
                allowed_rows = dframe[colname].isin(allowed_vals)
            selected &= allowed_rows
        dframe = dframe[selected]
    if what is None:
        return dframe
    else:
        return dframe[what]

def recycled(it, length=None):
    '''Recycle iterable to specified length.

    Items are returned in round-robin order until the specified length
    is reached. If length is None, the iterable is recycled
    indefinitely.

    Cannot handle infinite-length iterators as inputs, since it needs
    to enumerate all the elements of an iterable in order to recycle
    them.

    '''
    if length is None:
        x = list(it)
        while True:
            yield from iter(x)
    else:
        need_recycling = True
        try:
            if len(it) >= length:
                need_recycling = False
        except TypeError:
            pass
        if need_recycling:
            it = recycled(it)
            i = 0
            while i < length:
                i += 1
                yield next(it)
        else:
            yield from iter(it[:length])
    raise StopIteration

def zip_recycled(*args, length=None):
    '''Like zip(), but recycles all iterables to the specified length.

    If length is None,

    Cannot handle infinite-length iterators as inputs, since it needs
    to enumerate all the elements of an iterable in order to recycle
    them.

    '''
    return zip(*(recycled(arg, length) for arg in args))

def zip_longest_recycled(*args, warn_on_uneven=True):
    '''Like itertools.zip_longest(), but recycles shorter iterables.

    Unless kwarg warn_on_mismatch is set to False, a warning will be
    raised if all the iterable lengths do not divide evenly into the
    length of the longest iterable.

    '''
    args = [list(arg) for arg in args]
    maxlen = max(map(len, args))
    if warn_on_uneven:
        if max(maxlen % len(arg) for arg in args) > 0:
            warn("Longest iterable's length is not a multiple of shorter.")
    return zip_recycled(*args, length=maxlen)

def list_salmon_output_files(outdir, alignment=False):
    file_list = [
        'aux_info/bootstrap/bootstraps.gz',
        'aux_info/bootstrap/names.tsv.gz',
        'aux_info/exp3_seq.gz',
        'aux_info/exp5_seq.gz',
        'aux_info/expected_bias.gz',
        'aux_info/fld.gz',
        'aux_info/meta_info.json',
        'aux_info/obs3_seq.gz',
        'aux_info/obs5_seq.gz',
        'aux_info/observed_bias.gz',
        'aux_info/observed_bias_3p.gz',
        'cmd_info.json',
        'quant.genes.sf',
        'quant.sf',
    ]
    if alignment:
        file_list += ['logs/salmon.log',]
    else:
        file_list += ['libParams/flenDist.txt', 'logs/salmon_quant.log',]
    return [ os.path.join(outdir, f) for f in file_list ]

def list_kallisto_output_files(outdir):
    file_list = [
        'abundance.h5', 'abundance.tsv', 'run_info.json',
    ]
    return [ os.path.join(outdir, f) for f in file_list ]

def list_macs_callpeak_output_files(basename):
    ext_list = [
        '_peaks.narrowPeak',
        '_peaks.xls',
        '_summits.bed',
        # '_control_lambda.bdg',
        # '_treat_pileup.bdg',
    ]
    return [ basename + ext for ext in ext_list ]

# Run a separate Snakemake workflow (if needed) to fetch the sample
# metadata, which must be avilable before evaluating the rules below.
# Without this two-step workflow, the below rules would involve quite
# complex use of multiple dynamic() inputs and outputs.
try:
    rnaseq_samplemeta = read_R_dataframe('saved_data/samplemeta-RNASeq.RDS')
    chipseq_samplemeta = read_R_dataframe('saved_data/samplemeta-ChIPSeq.RDS')
except Exception:
    from processify import processify
    from snakemake import snakemake
    snakemake = processify(snakemake)
    result = snakemake(
        'pre.Snakefile',
        targets=['saved_data/samplemeta-RNASeq.RDS', 'saved_data/samplemeta-ChIPSeq.RDS'],
        lock=False,
        quiet=True)
    if not result:
        raise Exception('Could not retrieve experiment metadata from GEO')
    rnaseq_samplemeta = read_R_dataframe('saved_data/samplemeta-RNASeq.RDS')
    chipseq_samplemeta = read_R_dataframe('saved_data/samplemeta-ChIPSeq.RDS')

rnaseq_sample_libtypes = dict(zip(rnaseq_samplemeta['SRA_run'], rnaseq_samplemeta['libType']))

rnaseq_star_outdirs = [
    'rnaseq_star_hg38.analysisSet_knownGene',
    'rnaseq_star_hg38.analysisSet_ensembl.85',
]
rnaseq_hisat_outdir = 'rnaseq_hisat2_grch38_snp_tran'

aligned_rnaseq_star_bam_files = expand(
    'aligned/{dirname}/{samp}/Aligned.sortedByCoord.out.bam',
    dirname=rnaseq_star_outdirs, samp=rnaseq_samplemeta['SRA_run'])

aligned_rnaseq_hisat_bam_files = expand(
    'aligned/{dirname}/{samp}/Aligned.bam',
    dirname=rnaseq_hisat_outdir, samp=rnaseq_samplemeta['SRA_run'])

aligned_rnaseq_bam_files = aligned_rnaseq_star_bam_files + aligned_rnaseq_hisat_bam_files
aligned_rnaseq_bai_files = [ bam + '.bai' for bam in aligned_rnaseq_bam_files ]

chipseq_samplemeta_noinput = dfselect(chipseq_samplemeta, chip_antibody=lambda x: x != 'input')
aligned_chipseq_input_bam_files = expand(
    'aligned/chipseq_bowtie2_hg38.analysisSet/{SRA_run}/Aligned.bam',
    SRA_run=list(chipseq_samplemeta['SRA_run'][chipseq_samplemeta['chip_antibody'] == 'input']))
aligned_chipseq_bam_files = expand(
    'aligned/chipseq_bowtie2_hg38.analysisSet/{SRA_run}/Aligned.bam',
    SRA_run=list(chipseq_samplemeta['SRA_run'][chipseq_samplemeta['chip_antibody'] != 'input']))

subworkflow hg38_ref:
    workdir: os.path.expanduser('~/references/hg38')

include: 'rulegraph.Snakefile'

rule all:
    input:
        rnaseq_counts=[
            'saved_data/SummarizedExperiment_rnaseq_star_hg38.analysisSet_ensembl.85.RDS',
            'saved_data/SummarizedExperiment_rnaseq_star_hg38.analysisSet_knownGene.RDS',
            'saved_data/SummarizedExperiment_rnaseq_hisat2_grch38_snp_tran_ensembl.85.RDS',
            'saved_data/SummarizedExperiment_rnaseq_hisat2_grch38_snp_tran_knownGene.RDS',
        ],
        salmon_quant=expand(
            'salmon_quant/{genome_build}_{transcriptome}/{SRA_run}/{filename}',
            genome_build='hg38.analysisSet',
            transcriptome=['knownGene', 'ensembl.85'],
            SRA_run=rnaseq_samplemeta['SRA_run'],
            filename=['cmd_info.json', 'abundance.h5']),
        kallisto_quant=expand(
            'kallisto_quant/{genome_build}_{transcriptome}/{SRA_run}/run_info.json',
            genome_build='hg38.analysisSet',
            transcriptome=['knownGene', 'ensembl.85'],
            SRA_run=rnaseq_samplemeta['SRA_run']),
        chipseq_bam=expand(
            'aligned/chipseq_bowtie2_{genome_build}/{SRA_run}/Aligned.bam',
            genome_build='hg38.analysisSet',
            SRA_run=chipseq_samplemeta['SRA_run'],
        ),
        chipseq_bai=expand(
            'aligned/chipseq_bowtie2_{genome_build}/{SRA_run}/Aligned.bam.bai',
            genome_build='hg38.analysisSet',
            SRA_run=chipseq_samplemeta['SRA_run'],
        ),
        macs_predictd='saved_data/macs_predictd/output.log',
        macs_ac_ad=set(expand(
            'peak_calls/macs_{genome_build}/{chip_antibody}_condition.ALL_donor.ALL/peakcall_peaks.narrowPeak', zip_longest_recycled,
            genome_build='hg38.analysisSet',
            chip_antibody=chipseq_samplemeta_noinput['chip_antibody'])),
        macs_ac_sd=set(expand(
            'peak_calls/macs_{genome_build}/{chip_antibody}_condition.ALL_donor.{donor}/peakcall_peaks.narrowPeak', zip_longest_recycled,
            genome_build='hg38.analysisSet',
            chip_antibody=chipseq_samplemeta_noinput['chip_antibody'],
            donor=chipseq_samplemeta_noinput['donor_id'])),
        macs_sc_ad=set(expand(
            'peak_calls/macs_{genome_build}/{chip_antibody}_condition.{cell_type}.Day{time_point}_donor.ALL/peakcall_peaks.narrowPeak', zip_longest_recycled,
            genome_build='hg38.analysisSet',
            chip_antibody=chipseq_samplemeta_noinput['chip_antibody'],
            cell_type=chipseq_samplemeta_noinput['cell_type'],
            time_point=map(int, chipseq_samplemeta_noinput['days_after_activation']))),
        macs_sc_sd=set(expand(
            'peak_calls/macs_{genome_build}/{chip_antibody}_condition.{cell_type}.Day{time_point}_donor.{donor}/peakcall_peaks.narrowPeak', zip_longest_recycled,
            genome_build='hg38.analysisSet',
            chip_antibody=chipseq_samplemeta_noinput['chip_antibody'],
            cell_type=chipseq_samplemeta_noinput['cell_type'],
            time_point=map(int, chipseq_samplemeta_noinput['days_after_activation']),
            donor=chipseq_samplemeta_noinput['donor_id'])),
        epic_ac_ad=set(expand(
            'peak_calls/epic_{genome_build}/{chip_antibody}_condition.ALL_donor.ALL/peaks.tsv', zip_longest_recycled,
            genome_build='hg38.analysisSet',
            chip_antibody=chipseq_samplemeta_noinput['chip_antibody'])),
        epic_ac_sd=set(expand(
            'peak_calls/epic_{genome_build}/{chip_antibody}_condition.ALL_donor.{donor}/peaks.tsv', zip_longest_recycled,
            genome_build='hg38.analysisSet',
            chip_antibody=chipseq_samplemeta_noinput['chip_antibody'],
            donor=chipseq_samplemeta_noinput['donor_id'])),
        epic_sc_ad=set(expand(
            'peak_calls/epic_{genome_build}/{chip_antibody}_condition.{cell_type}.Day{time_point}_donor.ALL/peaks.tsv', zip_longest_recycled,
            genome_build='hg38.analysisSet',
            chip_antibody=chipseq_samplemeta_noinput['chip_antibody'],
            cell_type=chipseq_samplemeta_noinput['cell_type'],
            time_point=map(int, chipseq_samplemeta_noinput['days_after_activation']))),
        epic_sc_sd=set(expand(
            'peak_calls/epic_{genome_build}/{chip_antibody}_condition.{cell_type}.Day{time_point}_donor.{donor}/peaks.tsv', zip_longest_recycled,
            genome_build='hg38.analysisSet',
            chip_antibody=chipseq_samplemeta_noinput['chip_antibody'],
            cell_type=chipseq_samplemeta_noinput['cell_type'],
            time_point=map(int, chipseq_samplemeta_noinput['days_after_activation']),
            donor=chipseq_samplemeta_noinput['donor_id'])),
        ccf_data_files=['saved_data/csaw-ccf.RDS', 'saved_data/csaw-ccf-noBL.RDS'],

rule all_rnaseq_counts:
    input:
        rnaseq_counts=[
            'saved_data/SummarizedExperiment_rnaseq_star_hg38.analysisSet_ensembl.85.RDS',
            'saved_data/SummarizedExperiment_rnaseq_star_hg38.analysisSet_knownGene.RDS',
            'saved_data/SummarizedExperiment_rnaseq_hisat2_grch38_snp_tran_ensembl.85.RDS',
            'saved_data/SummarizedExperiment_rnaseq_hisat2_grch38_snp_tran_knownGene.RDS',
        ],

# Temp rule
rule all_salmon:
    input:
        salmon_quant=expand(
            'salmon_quant/{genome_build}_{transcriptome}/{SRA_run}/{filename}',
            genome_build='hg38.analysisSet',
            transcriptome=['knownGene', 'ensembl.85'],
            SRA_run=rnaseq_samplemeta['SRA_run'],
            filename=[
                'cmd_info.json', 'abundance.h5',
                # Don't need the bootstraps in text format, we can
                # already get them through the HDF5 file.
                # 'aux_info/bootstrap/quant_bootstraps.tsv',
            ]),

rule all_kallisto:
    input:
        kallisto_quant=expand(
            'kallisto_quant/{genome_build}_{transcriptome}/{SRA_run}/run_info.json',
            genome_build='hg38.analysisSet',
            transcriptome=['knownGene', 'ensembl.85'],
            SRA_run=rnaseq_samplemeta['SRA_run']),

# Temp rule
rule all_chipseq_bai:
    input:
        chipseq_bai=expand(
            'aligned/chipseq_bowtie2_{genome_build}/{SRA_run}/Aligned.bam.bai',
            genome_build='hg38.analysisSet',
            SRA_run=chipseq_samplemeta['SRA_run'],
        ),

rule all_macs_callpeak:
    input:
        ac_ad=set(expand(
            'peak_calls/macs_{genome_build}/{chip_antibody}_condition.ALL_donor.ALL/peakcall_peaks.narrowPeak', zip_longest_recycled,
            genome_build='hg38.analysisSet',
            chip_antibody=chipseq_samplemeta_noinput['chip_antibody'])),
        ac_sd=set(expand(
            'peak_calls/macs_{genome_build}/{chip_antibody}_condition.ALL_donor.{donor}/peakcall_peaks.narrowPeak', zip_longest_recycled,
            genome_build='hg38.analysisSet',
            chip_antibody=chipseq_samplemeta_noinput['chip_antibody'],
            donor=chipseq_samplemeta_noinput['donor_id'])),
        sc_ad=set(expand(
            'peak_calls/macs_{genome_build}/{chip_antibody}_condition.{cell_type}.Day{time_point}_donor.ALL/peakcall_peaks.narrowPeak', zip_longest_recycled,
            genome_build='hg38.analysisSet',
            chip_antibody=chipseq_samplemeta_noinput['chip_antibody'],
            cell_type=chipseq_samplemeta_noinput['cell_type'],
            time_point=map(int, chipseq_samplemeta_noinput['days_after_activation']))),
        sc_sd=set(expand(
            'peak_calls/macs_{genome_build}/{chip_antibody}_condition.{cell_type}.Day{time_point}_donor.{donor}/peakcall_peaks.narrowPeak', zip_longest_recycled,
            genome_build='hg38.analysisSet',
            chip_antibody=chipseq_samplemeta_noinput['chip_antibody'],
            cell_type=chipseq_samplemeta_noinput['cell_type'],
            time_point=map(int, chipseq_samplemeta_noinput['days_after_activation']),
            donor=chipseq_samplemeta_noinput['donor_id'])),

rule all_epic_callpeak:
    input:
        ac_ad=set(expand(
            'peak_calls/epic_{genome_build}/{chip_antibody}_condition.ALL_donor.ALL/peaks.tsv', zip_longest_recycled,
            genome_build='hg38.analysisSet',
            chip_antibody=chipseq_samplemeta_noinput['chip_antibody'])),
        ac_sd=set(expand(
            'peak_calls/epic_{genome_build}/{chip_antibody}_condition.ALL_donor.{donor}/peaks.tsv', zip_longest_recycled,
            genome_build='hg38.analysisSet',
            chip_antibody=chipseq_samplemeta_noinput['chip_antibody'],
            donor=chipseq_samplemeta_noinput['donor_id'])),
        sc_ad=set(expand(
            'peak_calls/epic_{genome_build}/{chip_antibody}_condition.{cell_type}.Day{time_point}_donor.ALL/peaks.tsv', zip_longest_recycled,
            genome_build='hg38.analysisSet',
            chip_antibody=chipseq_samplemeta_noinput['chip_antibody'],
            cell_type=chipseq_samplemeta_noinput['cell_type'],
            time_point=map(int, chipseq_samplemeta_noinput['days_after_activation']))),
        sc_sd=set(expand(
            'peak_calls/epic_{genome_build}/{chip_antibody}_condition.{cell_type}.Day{time_point}_donor.{donor}/peaks.tsv', zip_longest_recycled,
            genome_build='hg38.analysisSet',
            chip_antibody=chipseq_samplemeta_noinput['chip_antibody'],
            cell_type=chipseq_samplemeta_noinput['cell_type'],
            time_point=map(int, chipseq_samplemeta_noinput['days_after_activation']),
            donor=chipseq_samplemeta_noinput['donor_id'])),

rule fetch_sra_run:
    '''Script to fetch the .sra file for an SRA run

    (An SRA run identifier starts with SRR.)

    '''
    output: 'sra_files/{sra_run,SRR.*}.sra'
    version: ASCP_VERSION
    resources: concurrent_downloads=1
    shell: 'scripts/get-sra-run-files.R {wildcards.sra_run:q}'

rule extract_fastq:
    '''Extract FASTQ from SRA files.

    During extraction, the reads are also shuffled deterministically
    (i.e. using a fixed seed). This ensures that downstream tools
    expecting the reads in random order with respect to their mapping
    position (e.g. Salmon) will be satisfied.

    '''
    input: 'sra_files/{sra_run}.sra'
    output: 'fastq_files/{sra_run}.{fqext,fq(|\\.gz|\\.bz2|\\.qp)}'
    params: temp_unshuffled='fastq_files/{sra_run}_unshuffled.fq_temp',
            temp_shuffled='fastq_files/{sra_run}_shuffled.fq_temp'
    version: (SRATOOLKIT_VERSION, FASTQ_TOOLS_VERSION)
    resources: diskio=1
    run:
        compression_cmd = fastq_compression_cmds[wildcards.fqext]['compress']
        shell('''
        echo "Dumping fastq for {wildcards.sra_run:q}..."
        fastq-dump --stdout {input:q} | \
          scripts/fill-in-empty-fastq-qual.py \
          > {params.temp_unshuffled:q}
        echo "Shuffling fastq for {wildcards.sra_run:q}..."
        fastq-sort --random --seed=1986 {params.temp_unshuffled:q} > {params.temp_shuffled:q}
        echo "Compressing fastq for {wildcards.sra_run:q}..."
        {compression_cmd} < {params.temp_shuffled:q} > {output:q}
        rm -f {params.temp_unshuffled:q} {params.temp_shuffled:q}
        ''')

rule align_rnaseq_with_star_single_end:
    '''Align fastq file with star'''
    input: fastq='fastq_files/{samplename}.fq.gz',
           index_sa=hg38_ref('STAR_index_{genome_build}_{transcriptome}/SA'),
           transcriptome_gff=hg38_ref('{transcriptome}.gff3'),
    output: bam='aligned/rnaseq_star_{genome_build}_{transcriptome}/{samplename}/Aligned.sortedByCoord.out.bam',
            sj='aligned/rnaseq_star_{genome_build}_{transcriptome}/{samplename}/SJ.out.tab',
            logs=[ os.path.join('aligned/rnaseq_star_{genome_build}_{transcriptome}/{samplename}', fname)
                   for fname in ['Log.final.out', 'Log.out', 'Log.progress.out'] ],
    params: temp_sam='aligned/rnaseq_star_{genome_build}_{transcriptome}/{samplename}/Aligned.out.sam',
    version: STAR_VERSION
    threads: 8
    run:
        index_genomedir = os.path.dirname(input.index_sa)
        outdir = os.path.dirname(output.bam) + os.path.sep
        read_cmd = list2cmdline(fastq_compression_cmds['fq.gz']['decompress'])
        star_cmd = [
            'STAR',
            '--runThreadN', threads,
            '--runMode', 'alignReads',
            '--genomeDir', index_genomedir,
            '--sjdbGTFfile', input.transcriptome_gff,
            '--sjdbGTFfeatureExon', 'CDS',
            '--sjdbGTFtagExonParentTranscript', 'Parent',
            '--sjdbGTFtagExonParentGene', 'gene_id',
            '--sjdbOverhang', '100',
            '--readFilesIn', input.fastq,
            '--readFilesCommand', read_cmd,
            '--outSAMattributes', 'Standard',
            '--outSAMunmapped', 'Within',
            '--outFileNamePrefix', outdir,
            '--outSAMtype', 'SAM',
        ]
        # Run STAR
        shell(list2cmdline(map(str, star_cmd)))
        # Sort SAM into BAM
        picard_sort_cmd = 'picard-tools SortSam I={params.temp_sam:q} O={output.bam:q} SORT_ORDER=coordinate VALIDATION_STRINGENCY=LENIENT'
        shell(picard_sort_cmd)
        # Delete sam file
        os.remove(params.temp_sam)

rule align_rnaseq_with_hisat2_single_end:
    '''Align fastq file with HISAT2'''
    input: fastq='fastq_files/{samplename}.fq.gz',
           index_f1=hg38_ref('HISAT2_index_grch38_snp_tran/index.1.ht2'),
           transcriptome_gff=hg38_ref('knownGene.gff3'),
           chrom_mapping=hg38_ref('chrom_mapping_GRCh38_ensembl2UCSC.txt'),
    output: bam='aligned/rnaseq_hisat2_grch38_snp_tran/{samplename}/Aligned.bam',
            log='aligned/rnaseq_hisat2_grch38_snp_tran/{samplename}/hisat2.log'
    version: HISAT2_VERSION
    threads: 8
    run:
        index_basename = re.sub('\\.1\\.ht2', '', input.index_f1)
        outdir = os.path.dirname(output.bam)
        cmds = [
            [
                'hisat2',
                '--threads', str(threads),
                '-q', '--phred33',
                '--very-sensitive',
                '--dta-cufflinks',
                '-x', index_basename,
                '-U', input.fastq,
                '-k', '20',
                '--time',
            ],
            [
                # Convert to UCSC chromosome names
                'scripts/bam-rename-chroms.py', input.chrom_mapping,
            ],
            [
                'picard-tools', 'SortSam', 'I=/dev/stdin', 'O=/dev/stdout',
                'SORT_ORDER=coordinate', 'VALIDATION_STRINGENCY=LENIENT',
            ]
        ]
        with atomic_write(output.bam, mode='wb', overwrite=True) as outfile, \
             open(output.log, mode='wb') as logfile:
            pipeline = Popen_pipeline(cmds, stdout=outfile, stderr=logfile)
            wait_for_subprocs(pipeline)

rule index_bam:
    '''Create .bai file for a bam file.'''
    input: '{basename}.bam'
    output: '{basename}.bam.bai'
    shell: '''
    picard-tools BuildBamIndex I={input:q} O={output:q} \
        VALIDATION_STRINGENCY=LENIENT
    '''

rule bam2bed:
    '''Create .bai file for a bam file.'''
    input: '{basename}.bam'
    output: '{basename}_reads.bed'
    shell: '''
    picard-tools BuildBamIndex I={input:q} O={output:q} \
        VALIDATION_STRINGENCY=LENIENT
    '''

rule bam2bed_macs_filterdup:
    input: '{basename}.bam'
    output: bed='{basename}_reads_macs_filterdup.bed',
            log='{basename}_macs_filterdup.log'
    version: MACS_VERSION
    shell: '''
    macs2 filterdup --ifile {input:q} --format BAM \
      --gsize hs --keep-dup auto \
      --ofile {output.bed:q} \
      2>&1 | tee {output.log:q} 1>&2
    '''

# The hisat2 documentation doesn't specify which version of Ensembl
# they used to build the prebuilt index. Hopefully it doesn't matter
# too much.
rule count_rnaseq_hisat2_ensembl:
    input:
        samplemeta='saved_data/samplemeta-RNASeq.RDS',
        bam_files=expand(
            'aligned/rnaseq_hisat2_grch38_snp_tran/{SRA_run}/Aligned.bam',
            SRA_run=rnaseq_samplemeta['SRA_run']),
        bai_files=expand(
            'aligned/rnaseq_hisat2_grch38_snp_tran/{SRA_run}/Aligned.bam.bai',
            SRA_run=rnaseq_samplemeta['SRA_run']),
        txdb=hg38_ref('TxDb.Hsapiens.ensembl.hg38.v85.sqlite3'),
        genemeta=hg38_ref('genemeta.ensembl.85.RDS')
    output: sexp='saved_data/SummarizedExperiment_rnaseq_hisat2_grch38_snp_tran_ensembl.{release}.RDS'
    version: BIOC_VERSION
    threads: 4
    run:
        cmd = [
            'scripts/rnaseq-count.R',
            '--samplemeta-file', input.samplemeta,
            '--sample-id-column', 'SRA_run',
            '--bam-file-pattern', 'aligned/rnaseq_hisat2_grch38_snp_tran/%s/Aligned.bam',
            '--output-file', output.sexp,
            '--expected-bam-files', ','.join(input.bam_files),
            '--threads', str(threads),
            '--annotation-txdb', input.txdb,
            '--additional-gene-info', input.genemeta,
        ]
        check_call(cmd)

rule count_rnaseq_hisat2_knownGene:
    input:
        samplemeta='saved_data/samplemeta-RNASeq.RDS',
        bam_files=expand(
            'aligned/rnaseq_hisat2_grch38_snp_tran/{SRA_run}/Aligned.bam',
            SRA_run=rnaseq_samplemeta['SRA_run']),
        bai_files=expand(
            'aligned/rnaseq_hisat2_grch38_snp_tran/{SRA_run}/Aligned.bam.bai',
            SRA_run=rnaseq_samplemeta['SRA_run']),
        genemeta=hg38_ref('genemeta.org.Hs.eg.db.RDS')
    output: sexp='saved_data/SummarizedExperiment_rnaseq_hisat2_grch38_snp_tran_knownGene.RDS'
    version: R_package_version('RSubread')
    threads: 4
    run:
        cmd = [
            'scripts/rnaseq-count.R',
            '--samplemeta-file', input.samplemeta,
            '--sample-id-column', 'SRA_run',
            '--bam-file-pattern', 'aligned/rnaseq_hisat2_grch38_snp_tran/%s/Aligned.bam',
            '--output-file', output.sexp,
            '--expected-bam-files', ','.join(input.bam_files),
            '--threads', str(threads),
            '--annotation-txdb', 'TxDb.Hsapiens.UCSC.hg38.knownGene',
            '--additional-gene-info', input.genemeta,
        ]
        check_call(cmd)

rule count_rnaseq_star_ensembl:
    input:
        samplemeta='saved_data/samplemeta-RNASeq.RDS',
        bam_files=expand(
            'aligned/rnaseq_star_hg38.analysisSet_ensembl.{{release}}/{SRA_run}/Aligned.sortedByCoord.out.bam',
            SRA_run=rnaseq_samplemeta['SRA_run']),
        bai_files=expand(
            'aligned/rnaseq_star_hg38.analysisSet_ensembl.{{release}}/{SRA_run}/Aligned.sortedByCoord.out.bam.bai',
            SRA_run=rnaseq_samplemeta['SRA_run']),
        txdb=hg38_ref('TxDb.Hsapiens.ensembl.hg38.v{release}.sqlite3'),
        genemeta=hg38_ref('genemeta.ensembl.{release}.RDS')
    output: sexp='saved_data/SummarizedExperiment_rnaseq_star_hg38.analysisSet_ensembl.{release,\\d+}.RDS'
    version: R_package_version('RSubread')
    threads: 4
    run:
        cmd = [
            'scripts/rnaseq-count.R',
            '--samplemeta-file', input.samplemeta,
            '--sample-id-column', 'SRA_run',
            '--bam-file-pattern',
            'aligned/rnaseq_star_hg38.analysisSet_ensembl.{release}/%s/Aligned.sortedByCoord.out.bam'.format(
                   release=wildcards.release,
            ),
            '--output-file', output.sexp,
            '--expected-bam-files', ','.join(input.bam_files),
            '--threads', str(threads),
            '--annotation-txdb', input.txdb,
            '--additional-gene-info', input.genemeta,
        ]
        print(cmd)
        check_call(cmd)

rule count_rnaseq_star_knownGene:
    input:
        samplemeta='saved_data/samplemeta-RNASeq.RDS',
        bam_files=expand(
            'aligned/rnaseq_star_hg38.analysisSet_knownGene/{SRA_run}/Aligned.sortedByCoord.out.bam',
            SRA_run=rnaseq_samplemeta['SRA_run']),
        bai_files=expand(
            'aligned/rnaseq_star_hg38.analysisSet_knownGene/{SRA_run}/Aligned.sortedByCoord.out.bam.bai',
            SRA_run=rnaseq_samplemeta['SRA_run']),
        genemeta=hg38_ref('genemeta.org.Hs.eg.db.RDS')
    output: sexp='saved_data/SummarizedExperiment_rnaseq_star_hg38.analysisSet_knownGene.RDS'
    version: R_package_version('RSubread')
    threads: 4
    run:
        cmd = [
            'scripts/rnaseq-count.R',
            '--samplemeta-file', input.samplemeta,
            '--sample-id-column', 'SRA_run',
            '--bam-file-pattern', 'aligned/rnaseq_star_hg38.analysisSet_knownGene/%s/Aligned.sortedByCoord.out.bam',
            '--output-file', output.sexp,
            '--expected-bam-files', ','.join(input.bam_files),
            '--threads', str(threads),
            '--annotation-txdb', 'TxDb.Hsapiens.UCSC.hg38.knownGene',
            '--additional-gene-info', input.genemeta,
        ]
        check_call(cmd)

rule quant_rnaseq_with_salmon:
    input:
        salmon_index=hg38_ref('Salmon_index_{genome_build}_{transcriptome}/sa.bin'),
        genemap_file=hg38_ref('Salmon_index_{genome_build}_{transcriptome}/genemap.txt'),
        fastq='fastq_files/{SRA_run}.fq.gz',
    output:
        list_salmon_output_files('salmon_quant/{genome_build}_{transcriptome}/{SRA_run}')
    params:
        index_dir=hg38_ref('Salmon_index_{genome_build}_{transcriptome}'),
        outdir='salmon_quant/{genome_build}_{transcriptome}/{SRA_run}',
        libtype=lambda wildcards: rnaseq_sample_libtypes[wildcards.SRA_run]
    version: SALMON_VERSION
    threads: 16
    shell: '''
    salmon quant \
      --index {params.index_dir:q} \
      --unmatedReads {input.fastq:q} \
      --threads {threads:q} \
      --libType {params.libtype:q} \
      --seqBias --gcBias --useVBOpt \
      --geneMap {input.genemap_file:q} \
      --output {params.outdir:q} \
      --auxDir aux_info \
      --numGibbsSamples 100
    '''

rule convert_salmon_bootstraps_to_tsv:
    input: '{salmon_quant_dir}/aux_info/bootstrap/bootstraps.gz'
    output: '{salmon_quant_dir}/aux_info/bootstrap/quant_bootstraps.tsv'
    shell: '''
    scripts/ConvertBootstrapsToTSV.py \
      {wildcards.salmon_quant_dir:q} \
      {wildcards.salmon_quant_dir:q}/aux_info/bootstrap/
    '''

rule convert_salmon_to_hdf5:
    input: list_salmon_output_files('{salmon_quant_dir}')
    output: '{salmon_quant_dir}/abundance.h5'
    shell: ''' scripts/convert-salmon-to-hdf5.R {wildcards.salmon_quant_dir:q} '''

rule quant_rnaseq_with_kallisto:
    input:
        kallisto_index=hg38_ref('Kallisto_index_{genome_build}_{transcriptome}'),
        fastq='fastq_files/{SRA_run}.fq.gz',
    output:
        list_kallisto_output_files('kallisto_quant/{genome_build}_{transcriptome}/{SRA_run}')
    params:
        outdir='kallisto_quant/{genome_build}_{transcriptome}/{SRA_run}',
        libtype=lambda wildcards: rnaseq_sample_libtypes[wildcards.SRA_run]
    version: KALLISTO_VERSION
    threads: 16
    run:
        libType = list(rnaseq_samplemeta['libType'][rnaseq_samplemeta['SRA_run'] == wildcards.SRA_run])[0]
        if libType == 'ISF':
            lib_opt = '--fr-stranded'
        elif libType == 'ISR':
            lib_opt = '--rf-stranded'
        else:
            raise ValueError('Unknown kallisto libtype: {}'.format(libType))
        shell('''
        mkdir -p {params.outdir:q}
        kallisto quant \
          --index {input.kallisto_index:q} --output-dir {params.outdir:q} \
          {lib_opt:q} --single --threads {threads:q} --bootstrap-samples 100 \
          --bias --fragment-length 200 --sd 80 {input.fastq:q}
        ''')

# TODO: Write R script to convert bootstraps into SummarizedExperiment
# RDS file, and write a rule for it.

rule align_chipseq_with_bowtie2:
    input:
        fastq='fastq_files/{SRA_run}.fq.gz',
        index_file=hg38_ref('BT2_index_{genome_build}/index.1.bt2l')
    output:
        bam='aligned/chipseq_bowtie2_{genome_build}/{SRA_run}/Aligned.bam'
    params:
        index_basename=hg38_ref('BT2_index_{genome_build}/index')
    version: BOWTIE2_VERSION
    threads: 8
    shell: '''
    bowtie2 --threads {threads:q} --mm \
      -U {input.fastq:q} -x {params.index_basename:q} -q \
      --end-to-end --sensitive | \
    picard-tools SortSam I=/dev/stdin O={output.bam:q} \
      SORT_ORDER=coordinate VALIDATION_STRINGENCY=LENIENT
    '''

rule get_liftover_chain:
    input: FTP.remote('hgdownload.cse.ucsc.edu/goldenPath/{src_genome}/liftOver/{src_genome}ToHg38.over.chain.gz', static=True)
    output: 'saved_data/{src_genome}ToHg38.over.chain.gz'
    shell: 'mv {input:q} {output:q}'

# Temp rule
rule all_blacklists:
    input:
        ## Remember to cite: https://sites.google.com/site/anshulkundaje/projects/blacklists
        'saved_data/wgEncodeDacMapabilityConsensusExcludable.bed.gz',
        ## Cite: http://www.ncbi.nlm.nih.gov/pubmed/15499007
        'saved_data/wgEncodeDukeMapabilityRegionsExcludable.bed.gz',

# http://genome.ucsc.edu/cgi-bin/hgFileUi?db=hg19&g=wgEncodeMapability
rule get_blacklist_regions:
    input: FTP.remote('hgdownload.cse.ucsc.edu/goldenPath/hg19/encodeDCC/wgEncodeMapability/{track_name}.bed.gz', static=True)
    output: 'saved_data/{track_name}_hg19.bed.gz'
    shell: 'mv {input:q} {output:q}'

rule liftover_blacklist_regions:
    input: bed='saved_data/{track_name}_hg19.bed.gz',
           chain='saved_data/hg19ToHg38.over.chain.gz',
    output: bed='saved_data/{track_name,[^_]+}.bed.gz'
    shell: '''
    liftOver {input.bed:q} {input.chain:q} /dev/stdout /dev/null | \
      gzip -c - > {output.bed:q}
    '''

rule macs_predictd:
    input: bam_files=aligned_chipseq_bam_files,
    output: rfile='saved_data/macs_predictd/predictd',
            pdf='saved_data/macs_predictd/predictd_model.pdf',
            logfile='saved_data/macs_predictd/output.log'
    params: outdir='saved_data/macs_predictd'
    version: MACS_VERSION
    run:
        output_rfile_basename = os.path.basename(output.rfile)
        shell('''
        macs2 predictd -i {input.bam_files:q} -f BAM -g hs \
          --outdir {params.outdir:q} --rfile {output_rfile_basename:q} \
          &>{output.logfile:q}
        cd {params.outdir:q}
        Rscript {output_rfile_basename:q}
        ''')

rule callpeak_macs_all_conditions_all_donors:
    input:
        chip_input=lambda wildcards:
        expand('aligned/chipseq_bowtie2_{genome_build}/{SRA_run}/Aligned.bam',
               SRA_run=dfselect(chipseq_samplemeta, 'SRA_run',
                                chip_antibody="input"),
               genome_build=wildcards.genome_build),
        chip_pulldown=lambda wildcards:
        expand('aligned/chipseq_bowtie2_{genome_build}/{SRA_run}/Aligned.bam',
               SRA_run=dfselect(chipseq_samplemeta, 'SRA_run',
                                chip_antibody=wildcards.chip_antibody),
               genome_build=wildcards.genome_build)
    output:
        outfiles=list_macs_callpeak_output_files('peak_calls/macs_{genome_build}/{chip_antibody}_condition.ALL_donor.ALL/peakcall'),
        log='peak_calls/macs_{genome_build}/{chip_antibody}_condition.ALL_donor.ALL/peakcall.log'
    params:
        outdir='peak_calls/macs_{genome_build}/{chip_antibody}_condition.ALL_donor.ALL',
    version: MACS_VERSION
    shell: '''
    macs2 callpeak \
      --treatment {input.chip_pulldown:q} \
      --control {input.chip_input:q} \
      --format BAM \
      --gsize hs \
      --keep-dup auto \
      --outdir {params.outdir:q} \
      --name peakcall \
      --nomodel --extsize 147 \
      --pvalue=0.5 \
      2>&1 | tee {output.log:q}
    '''

rule callpeak_macs_all_conditions_single_donor:
    input:
        chip_input=lambda wildcards:
        expand('aligned/chipseq_bowtie2_{genome_build}/{SRA_run}/Aligned.bam',
               SRA_run=dfselect(chipseq_samplemeta, 'SRA_run',
                                chip_antibody="input"),
               genome_build=wildcards.genome_build),
        chip_pulldown=lambda wildcards:
        expand('aligned/chipseq_bowtie2_{genome_build}/{SRA_run}/Aligned.bam',
               SRA_run=dfselect(chipseq_samplemeta, 'SRA_run',
                                chip_antibody=wildcards.chip_antibody,
                                donor_id=wildcards.donor),
               genome_build=wildcards.genome_build)
    output:
        outfiles=list_macs_callpeak_output_files('peak_calls/macs_{genome_build}/{chip_antibody}_condition.ALL_donor.{donor,D[0-9]+}/peakcall'),
        log='peak_calls/macs_{genome_build}/{chip_antibody}_condition.ALL_donor.{donor,D[0-9]+}/peakcall.log'
    params:
        outdir='peak_calls/macs_{genome_build}/{chip_antibody}_condition.ALL_donor.{donor}',
    version: MACS_VERSION
    shell: '''
    macs2 callpeak \
      --treatment {input.chip_pulldown:q} \
      --control {input.chip_input:q} \
      --format BAM \
      --gsize hs \
      --keep-dup auto \
      --outdir {params.outdir:q} \
      --name peakcall \
      --bdg \
      --nomodel --extsize 147 \
      --pvalue=0.5 \
      2>&1 | tee {output.log:q}
    '''

rule callpeak_macs_single_condition_all_donors:
    input:
        chip_input=lambda wildcards:
        expand('aligned/chipseq_bowtie2_{genome_build}/{SRA_run}/Aligned.bam',
               SRA_run=dfselect(chipseq_samplemeta, 'SRA_run',
                                chip_antibody="input"),
               genome_build=wildcards.genome_build),
        chip_pulldown=lambda wildcards:
        expand('aligned/chipseq_bowtie2_{genome_build}/{SRA_run}/Aligned.bam',
               SRA_run=dfselect(chipseq_samplemeta, 'SRA_run',
                                chip_antibody=wildcards.chip_antibody,
                                cell_type=wildcards.cell_type,
                                days_after_activation=float(wildcards.time_point)),
               genome_build=wildcards.genome_build)
    output:
        outfiles=list_macs_callpeak_output_files('peak_calls/macs_{genome_build}/{chip_antibody}_condition.{cell_type}.Day{time_point}_donor.ALL/peakcall'),
        log='peak_calls/macs_{genome_build}/{chip_antibody}_condition.{cell_type}.Day{time_point}_donor.ALL/peakcall.log'
    params:
        outdir='peak_calls/macs_{genome_build}/{chip_antibody}_condition.{cell_type}.Day{time_point}_donor.ALL',
    version: MACS_VERSION
    shell: '''
    macs2 callpeak \
      --treatment {input.chip_pulldown:q} \
      --control {input.chip_input:q} \
      --format BAM \
      --gsize hs \
      --keep-dup auto \
      --outdir {params.outdir:q} \
      --name peakcall \
      --bdg \
      --nomodel --extsize 147 \
      --pvalue=0.5 \
      2>&1 | tee {output.log:q}
    '''

rule callpeak_macs_single_condition_single_donor:
    input:
        chip_input=lambda wildcards:
        expand('aligned/chipseq_bowtie2_{genome_build}/{SRA_run}/Aligned.bam',
               SRA_run=dfselect(chipseq_samplemeta, 'SRA_run',
                                chip_antibody="input"),
               genome_build=wildcards.genome_build),
        chip_pulldown=lambda wildcards:
        expand('aligned/chipseq_bowtie2_{genome_build}/{SRA_run}/Aligned.bam',
               SRA_run=dfselect(chipseq_samplemeta, 'SRA_run',
                                chip_antibody=wildcards.chip_antibody,
                                donor_id=wildcards.donor,
                                cell_type=wildcards.cell_type,
                                days_after_activation=float(wildcards.time_point)),
               genome_build=wildcards.genome_build)
    output:
        outfiles=list_macs_callpeak_output_files('peak_calls/macs_{genome_build}/{chip_antibody}_condition.{cell_type}.Day{time_point}_donor.{donor,D[0-9]+}/peakcall'),
        log='peak_calls/macs_{genome_build}/{chip_antibody}_condition.{cell_type}.Day{time_point}_donor.{donor,D[0-9]+}/peakcall.log'
    params:
        outdir='peak_calls/macs_{genome_build}/{chip_antibody}_condition.{cell_type}.Day{time_point}_donor.{donor}',
    version: MACS_VERSION
    shell: '''
    macs2 callpeak \
      --treatment {input.chip_pulldown:q} \
      --control {input.chip_input:q} \
      --format BAM \
      --gsize hs \
      --keep-dup auto \
      --outdir {params.outdir:q} \
      --name peakcall \
      --nomodel --extsize 147 \
      --pvalue=0.5 \
      2>&1 | tee {output.log:q}
    '''

rule callpeak_epic_all_conditions_all_donors:
    input:
        chip_input=lambda wildcards:
        expand('aligned/chipseq_bowtie2_{genome_build}/{SRA_run}/Aligned_reads_macs_filterdup.bed',
               SRA_run=dfselect(chipseq_samplemeta, 'SRA_run',
                                chip_antibody="input"),
               genome_build=wildcards.genome_build),
        chip_pulldown=lambda wildcards:
        expand('aligned/chipseq_bowtie2_{genome_build}/{SRA_run}/Aligned_reads_macs_filterdup.bed',
               SRA_run=dfselect(chipseq_samplemeta, 'SRA_run',
                                chip_antibody=wildcards.chip_antibody),
               genome_build=wildcards.genome_build)
    output:
        peaks='peak_calls/epic_{genome_build}/{chip_antibody}_condition.ALL_donor.ALL/peaks.tsv',
        chip_bw='peak_calls/epic_{genome_build}/{chip_antibody}_condition.ALL_donor.ALL/bigwig/sum_treatment.bw',
        control_bw='peak_calls/epic_{genome_build}/{chip_antibody}_condition.ALL_donor.ALL/bigwig/sum_input.bw',
        log='peak_calls/epic_{genome_build}/{chip_antibody}_condition.ALL_donor.ALL/peakcall.log',
    params:
        outdir='peak_calls/epic_{genome_build}/{chip_antibody}_condition.ALL_donor.ALL',
    threads: 4
    version: EPIC_VERSION
    shell: '''
    epic \
      --treatment {input.chip_pulldown:q} \
      --control {input.chip_input:q} \
      --number-cores {threads:q} \
      --genome hg38 \
      --fragment-size 147 \
      --keep-duplicates True \
      --bigwig {params.outdir:q}/bigwigs \
      >{output.peaks:q} \
      2>{output.log:q} &
    tail -f {output.log:q} 1>&2
    wait
    '''

rule callpeak_epic_all_conditions_single_donor:
    input:
        chip_input=lambda wildcards:
        expand('aligned/chipseq_bowtie2_{genome_build}/{SRA_run}/Aligned_reads_macs_filterdup.bed',
               SRA_run=dfselect(chipseq_samplemeta, 'SRA_run',
                                chip_antibody="input"),
               genome_build=wildcards.genome_build),
        chip_pulldown=lambda wildcards:
        expand('aligned/chipseq_bowtie2_{genome_build}/{SRA_run}/Aligned_reads_macs_filterdup.bed',
               SRA_run=dfselect(chipseq_samplemeta, 'SRA_run',
                                chip_antibody=wildcards.chip_antibody,
                                donor_id=wildcards.donor),
               genome_build=wildcards.genome_build)
    output:
        peaks='peak_calls/epic_{genome_build}/{chip_antibody}_condition.ALL_donor.{donor,D[0-9]+}/peaks.tsv',
        chip_bw='peak_calls/epic_{genome_build}/{chip_antibody}_condition.ALL_donor.{donor,D[0-9]+}/bigwig/sum_treatment.bw',
        control_bw='peak_calls/epic_{genome_build}/{chip_antibody}_condition.ALL_donor.{donor,D[0-9]+}/bigwig/sum_input.bw',
        log='peak_calls/epic_{genome_build}/{chip_antibody}_condition.ALL_donor.{donor,D[0-9]+}/peakcall.log',
    params:
        outdir='peak_calls/epic_{genome_build}/{chip_antibody}_condition.ALL_donor.{donor}',
    threads: 4
    version: EPIC_VERSION
    shell: '''
    epic \
      --treatment {input.chip_pulldown:q} \
      --control {input.chip_input:q} \
      --number-cores {threads:q} \
      --genome hg38 \
      --fragment-size 147 \
      --keep-duplicates True \
      --bigwig {params.outdir:q}/bigwigs \
      >{output.peaks:q} \
      2>{output.log:q} &
    tail -f {output.log:q} 1>&2
    wait
    '''

rule callpeak_epic_single_condition_all_donors:
    input:
        chip_input=lambda wildcards:
        expand('aligned/chipseq_bowtie2_{genome_build}/{SRA_run}/Aligned_reads_macs_filterdup.bed',
               SRA_run=dfselect(chipseq_samplemeta, 'SRA_run',
                                chip_antibody="input"),
               genome_build=wildcards.genome_build),
        chip_pulldown=lambda wildcards:
        expand('aligned/chipseq_bowtie2_{genome_build}/{SRA_run}/Aligned_reads_macs_filterdup.bed',
               SRA_run=dfselect(chipseq_samplemeta, 'SRA_run',
                                chip_antibody=wildcards.chip_antibody,
                                cell_type=wildcards.cell_type,
                                days_after_activation=float(wildcards.time_point)),
               genome_build=wildcards.genome_build)
    output:
        peaks='peak_calls/epic_{genome_build}/{chip_antibody}_condition.{cell_type}.Day{time_point}_donor.ALL/peaks.tsv',
        chip_bw='peak_calls/epic_{genome_build}/{chip_antibody}_condition.{cell_type}.Day{time_point}_donor.ALL/bigwig/sum_treatment.bw',
        control_bw='peak_calls/epic_{genome_build}/{chip_antibody}_condition.{cell_type}.Day{time_point}_donor.ALL/bigwig/sum_input.bw',
        log='peak_calls/epic_{genome_build}/{chip_antibody}_condition.{cell_type}.Day{time_point}_donor.ALL/peakcall.log',
    params:
        outdir='peak_calls/epic_{genome_build}/{chip_antibody}_condition.{cell_type}.Day{time_point}_donor.ALL',
    threads: 4
    version: EPIC_VERSION
    shell: '''
    epic \
      --treatment {input.chip_pulldown:q} \
      --control {input.chip_input:q} \
      --number-cores {threads:q} \
      --genome hg38 \
      --fragment-size 147 \
      --keep-duplicates True \
      --bigwig {params.outdir:q}/bigwig \
      >{output.peaks:q} \
      2>{output.log:q} &
    tail -f {output.log:q} 1>&2
    wait
    '''

rule callpeak_epic_single_condition_single_donor:
    input:
        chip_input=lambda wildcards:
        expand('aligned/chipseq_bowtie2_{genome_build}/{SRA_run}/Aligned_reads_macs_filterdup.bed',
               SRA_run=dfselect(chipseq_samplemeta, 'SRA_run',
                                chip_antibody="input"),
               genome_build=wildcards.genome_build),
        chip_pulldown=lambda wildcards:
        expand('aligned/chipseq_bowtie2_{genome_build}/{SRA_run}/Aligned_reads_macs_filterdup.bed',
               SRA_run=dfselect(chipseq_samplemeta, 'SRA_run',
                                chip_antibody=wildcards.chip_antibody,
                                donor_id=wildcards.donor,
                                cell_type=wildcards.cell_type,
                                days_after_activation=float(wildcards.time_point)),
               genome_build=wildcards.genome_build)
    output:
        peaks='peak_calls/epic_{genome_build}/{chip_antibody}_condition.{cell_type}.Day{time_point}_donor.{donor,D[0-9]+}/peaks.tsv',
        chip_bw='peak_calls/epic_{genome_build}/{chip_antibody}_condition.{cell_type}.Day{time_point}_donor.{donor,D[0-9]+}/bigwig/sum_treatment.bw',
        control_bw='peak_calls/epic_{genome_build}/{chip_antibody}_condition.{cell_type}.Day{time_point}_donor.{donor,D[0-9]+}/bigwig/sum_input.bw',
        log='peak_calls/epic_{genome_build}/{chip_antibody}_condition.{cell_type}.Day{time_point}_donor.{donor,D[0-9]+}/peakcall.log',
    params:
        outdir='peak_calls/epic_{genome_build}/{chip_antibody}_condition.{cell_type}.Day{time_point}_donor.{donor}',
    threads: 4
    version: EPIC_VERSION
    shell: '''
    epic \
      --treatment {input.chip_pulldown:q} \
      --control {input.chip_input:q} \
      --number-cores {threads:q} \
      --genome hg38 \
      --fragment-size 147 \
      --keep-duplicates True \
      --bigwig {params.outdir:q}/bigwig \
      >{output.peaks:q} \
      2>{output.log:q} &
    tail -f {output.log:q} 1>&2
    wait
    '''
rule run_idr_macs_all_conditions:
    input:
        all_donor_peaks='peak_calls/macs_{genome_build}/{chip_antibody}_condition.ALL_donor.ALL/peakcall_peaks.narrowPeak',
        donorA_peaks='peak_calls/macs_{genome_build}/{chip_antibody}_condition.ALL_donor.{donorA}/peakcall_peaks.narrowPeak',
        donorB_peaks='peak_calls/macs_{genome_build}/{chip_antibody}_condition.ALL_donor.{donorB}/peakcall_peaks.narrowPeak',
    output:
        outfile='idr_analysis/macs_{genome_build}/{chip_antibody}_condition.ALL_{donorA,D[0-9]+}vs{donorB,D[0-9]+}/idrValues.txt',
        logfile='idr_analysis/macs_{genome_build}/{chip_antibody}_condition.ALL_{donorA,D[0-9]+}vs{donorB,D[0-9]+}/idr.log',
        plotfile='idr_analysis/macs_{genome_build}/{chip_antibody}_condition.ALL_{donorA,D[0-9]+}vs{donorB,D[0-9]+}/idrValues.png',
    shell: '''
    idr --samples {input.donorA_peaks:q} {input.donorB_peaks:q} \
      --peak-list {input.all_donor_peaks:q} \
      --input-file-type narrowPeak \
      --output-file {output.outfile:q} \
      --output-file-type narrowPeak \
      --log-output-file {output.logfile:q} \
      --plot \
      --random-seed 1986
    mv {output.outfile:q}.png {output.plotfile:q}
    '''

rule run_idr_macs_single_condition:
    input:
        all_donor_peaks='peak_calls/macs_{genome_build}/{chip_antibody}_condition.{cell_type}.Day{time_point}_donor.ALL/peakcall_peaks.narrowPeak',
        donorA_peaks='peak_calls/macs_{genome_build}/{chip_antibody}_condition.{cell_type}.Day{time_point}_donor.{donorA}/peakcall_peaks.narrowPeak',
        donorB_peaks='peak_calls/macs_{genome_build}/{chip_antibody}_condition.{cell_type}.Day{time_point}_donor.{donorB}/peakcall_peaks.narrowPeak',
    output:
        outfile='idr_analysis/macs_{genome_build}/{chip_antibody}_condition.{cell_type}.Day{time_point}_{donorA,D[0-9]+}vs{donorB,D[0-9]+}/idrValues.txt',
        logfile='idr_analysis/macs_{genome_build}/{chip_antibody}_condition.{cell_type}.Day{time_point}_{donorA,D[0-9]+}vs{donorB,D[0-9]+}/idr.log',
        plotfile='idr_analysis/macs_{genome_build}/{chip_antibody}_condition.{cell_type}.Day{time_point}_{donorA,D[0-9]+}vs{donorB,D[0-9]+}/idrValues.png',
    shell: '''
    idr --samples {input.donorA_peaks:q} {input.donorB_peaks:q} \
      --peak-list {input.all_donor_peaks:q} \
      --input-file-type narrowPeak \
      --output-file {output.outfile:q} \
      --output-file-type narrowPeak \
      --log-output-file {output.logfile:q} \
      --plot \
      --random-seed 1986
    mv {output.outfile:q}.png {output.plotfile:q}
    '''

# TODO: Figure out what format Epic's peaks.tsv file is
rule run_idr_epic_all_conditions:
    input:
        all_donor_peaks='peak_calls/epic_{genome_build}/{chip_antibody}_condition.ALL_donor.ALL/peaks.tsv',
        donorA_peaks='peak_calls/epic_{genome_build}/{chip_antibody}_condition.ALL_donor.{donorA}/peaks.tsv',
        donorB_peaks='peak_calls/epic_{genome_build}/{chip_antibody}_condition.ALL_donor.{donorB}/peaks.tsv',
    output:
        outfile='idr_analysis/epic_{genome_build}/{chip_antibody}_condition.ALL_{donorA,D[0-9]+}vs{donorB,D[0-9]+}/idrValues.txt',
        logfile='idr_analysis/epic_{genome_build}/{chip_antibody}_condition.ALL_{donorA,D[0-9]+}vs{donorB,D[0-9]+}/idr.log',
        plotfile='idr_analysis/epic_{genome_build}/{chip_antibody}_condition.ALL_{donorA,D[0-9]+}vs{donorB,D[0-9]+}/idrValues.png',
    shell: '''
    idr --samples {input.donorA_peaks:q} {input.donorB_peaks:q} \
      --peak-list {input.all_donor_peaks:q} \
      --input-file-type narrowPeak \
      --output-file {output.outfile:q} \
      --output-file-type narrowPeak \
      --log-output-file {output.logfile:q} \
      --plot \
      --random-seed 1986
    mv {output.outfile:q}.png {output.plotfile:q}
    '''

rule run_idr_epic_single_condition:
    input:
        all_donor_peaks='peak_calls/epic_{genome_build}/{chip_antibody}_condition.{cell_type}.Day{time_point}_donor.ALL/peaks.tsv',
        donorA_peaks='peak_calls/epic_{genome_build}/{chip_antibody}_condition.{cell_type}.Day{time_point}_donor.{donorA}/peaks.tsv',
        donorB_peaks='peak_calls/epic_{genome_build}/{chip_antibody}_condition.{cell_type}.Day{time_point}_donor.{donorB}/peaks.tsv',
    output:
        outfile='idr_analysis/epic_{genome_build}/{chip_antibody}_condition.{cell_type}.Day{time_point}_{donorA,D[0-9]+}vs{donorB,D[0-9]+}/idrValues.txt',
        logfile='idr_analysis/epic_{genome_build}/{chip_antibody}_condition.{cell_type}.Day{time_point}_{donorA,D[0-9]+}vs{donorB,D[0-9]+}/idr.log',
        plotfile='idr_analysis/epic_{genome_build}/{chip_antibody}_condition.{cell_type}.Day{time_point}_{donorA,D[0-9]+}vs{donorB,D[0-9]+}/idrValues.png',
    shell: '''
    idr --samples {input.donorA_peaks:q} {input.donorB_peaks:q} \
      --peak-list {input.all_donor_peaks:q} \
      --input-file-type narrowPeak \
      --output-file {output.outfile:q} \
      --output-file-type narrowPeak \
      --log-output-file {output.logfile:q} \
      --plot \
      --random-seed 1986
    mv {output.outfile:q}.png {output.plotfile:q}
    '''

rule csaw_compute_ccf:
    input:
        bam_files=expand("aligned/chipseq_bowtie2_hg38.analysisSet/{sra_run}/Aligned.{ext}",
                         sra_run=chipseq_samplemeta['SRA_run'],
                         ext=['bam', 'bam.bai'])
    output:
        'saved_data/csaw-ccf.RDS', 'saved_data/csaw-ccf-noBL.RDS'
    shell: 'Rscript scripts/csaw-compute-ccf.R'
