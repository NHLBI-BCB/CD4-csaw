#!/usr/bin/env Rscript

tsmsg <- function(...) {
    message(date(), ": ", ...)
}

getScriptPath <- function() {
    argv <-commandArgs()
    dir <- na.omit(stringr::str_match(argv, "^--file=(.*)$")[,2])[1]
    if (!is.na(dir) && !is.null(dir))
        return(dir)
}
tryCatch(setwd(file.path(dirname(getScriptPath()), "..")),
         error=function(...) tsmsg("WARNING: Could not determine script path. Ensure that you are already in the correct directory."))

library(Rsamtools)
library(stringr)
library(magrittr)
library(GenomicRanges)
library(Rsubread)
library(openxlsx)
library(annotate)
library(BSgenome.Hsapiens.UCSC.hg38)
library(org.Hs.eg.db)
library(doParallel)
options(mc.cores=parallel::detectCores())
registerDoParallel(cores=parallel::detectCores())
library(BiocParallel)
register(MulticoreParam(parallel::detectCores()))
library(GenomicRanges)
library(rtracklayer)
library(SummarizedExperiment)
library(dplyr)
library(reshape2)
library(purrr)
library(csaw)
library(Matrix)

tsmsg("Loading sample data")

sample.table <- readRDS("saved_data/samplemeta-ChIPSeq.RDS") %>%
    ## Compute full path to BAM file
    mutate(bam_file=sprintf("aligned/chipseq_bowtie2_hg38.analysisSet/%s/Aligned.bam", SRA_run)) %>%
    ## Ensure that days_after_activation is a factor and can't be
    ## interpreted as a numeric
    mutate(days_after_activation=days_after_activation %>%
               factor %>% `levels<-`(str_c("Day", levels(.)))) %>%
    rename(time_point=days_after_activation)

stopifnot(all(file.exists(sample.table$bam_file)))

tsmsg("Loading blacklist regions")
blacklist <- import("saved_data/wgEncodeDacMapabilityConsensusExcludable.bed.gz", format="bed")

## Standard nuclear chromosomes only. (chrM is excluded because it is
## not located in the nucleus and is thus not subject to histone
## modification. The unplaced scaffolds are mostly not large enough to
## contain even a single typically-sized peak, so little is lost by
## excluding them for this analysis.)
std.chr <- extractSeqlevels("Homo sapiens", "UCSC") %>% setdiff("chrM")
param <- readParam(restrict=std.chr, discard=blacklist)
param.dedup.on <- reform(param, dedup=TRUE)
param.dedup.on.no.blacklist <- reform(param.dedup.on, discard=GRanges())

## Determine fragment length using cross-correlation function, see
## csaw UG 2.4.1
sample.ccf.noBL <-
    lapply(sample.table$bam_file,
           . %T>% tsmsg("Computing no-blacklist CCF for ", .) %>%
           correlateReads(max.dist=1000, cross=TRUE,
                          param=param.dedup.on.no.blacklist))
sample.ccf <-
    lapply(sample.table$bam_file,
           . %T>% tsmsg("Computing CCF for ", .) %>%
           correlateReads(max.dist=1000, cross=TRUE,
                          param=param.dedup.on))
names(sample.ccf.noBL) <- names(sample.ccf) <- sample.table$SampleName
saveRDS(sample.ccf, "saved_data/csaw-ccf.RDS")
saveRDS(sample.ccf.noBL, "saved_data/csaw-ccf-noBL.RDS")