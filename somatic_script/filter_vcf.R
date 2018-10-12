######  read vcfs  ##############

name_pkg <- c("statmod")
bool_nopkg <- !name_pkg %in% rownames(installed.packages())
if(sum(bool_nopkg) > 0){
  install.packages(name_pkg[bool_nopkg])
}
invisible(lapply(name_pkg, library, character.only = T)) # load multiple packages

options(scipen=999)
args=commandArgs(trailingOnly = TRUE)
wd=args[1]
normal=args[2]
setwd(wd)

######  define functions  ###########

extract_count<-function(fields,info,field)
{
  if (length(info)==0) {return(numeric(0))}
  split_info=strsplit(info,":")
  as.numeric(sapply(1:length(info),
    function(i) sub(",.*","",split_info[[i]][fields[[i]]==field])))
}

filter_vcf<-function(vcf,caller,type="somatic")
{
  if (dim(vcf)[1]==0) {return(vcf)}
  vcf$V8=caller
  vcf=vcf[vcf$V7=="PASS",]
  vcf$V3=vcf$V2+nchar(vcf$V4)-1
  vcf=vcf[!grepl(",",vcf$V5),] # compound alt alleles, not sure which is right
  
  vcf=vcf[vcf$V10!="." & vcf$V11!=".",]
  fields=strsplit(vcf$V9,":")
  
  # extract read count
  if (caller=="mutect")
  {
    if (dim(vcf)[1]==0)
    {
      vcf$normal_ref=vcf$normal_alt=vcf$tumor_ref=vcf$tumor_alt=numeric(0)
      return(vcf)
    }
    
    normal_ct=strsplit(sapply(strsplit(vcf$V10,":"),function(x) x[2]),",")
    vcf$normal_ref=as.numeric(sapply(normal_ct,function(x) x[1]))
    vcf$normal_alt=as.numeric(sapply(normal_ct,function(x) x[2]))
    
    tumor_ct=strsplit(sapply(strsplit(vcf$V11,":"),function(x) x[2]),",")
    vcf$tumor_ref=as.numeric(sapply(tumor_ct,function(x) x[1]))
    vcf$tumor_alt=as.numeric(sapply(tumor_ct,function(x) x[2]))
  }else if (caller %in% c("speedseq","shimmer","varscan","strelka"))
  {
    if (caller %in% c("speedseq","shimmer"))
    {
      RO="RO";AO="AO"
    }else if (caller %in% c("varscan"))
    {
      RO="RD";AO="AD"
    }else if (caller %in% c("strelka"))
    {
      RO="TAR";AO="TIR"
    }
    
    vcf$normal_ref=extract_count(fields,vcf$V10,RO)
    vcf$normal_alt=extract_count(fields,vcf$V10,AO)
    vcf$tumor_ref=extract_count(fields,vcf$V11,RO)
    vcf$tumor_alt=extract_count(fields,vcf$V11,AO)
  }else # lofreq
  {
    for (i in 1:dim(vcf)[1])
    {
      tmp=strsplit(fields[[i]],";")[[1]][1:2]
      total_count=as.numeric(sub("DP=","",tmp[1]))
      var_count=round(total_count*as.numeric(sub("AF=","",tmp[2])))
      vcf$normal_alt[i]=vcf$tumor_alt[i]=var_count
      vcf$normal_ref[i]=vcf$tumor_ref[i]=total_count-var_count
    }
  }
  
  # filter by read count and allele frequency
  vcf=vcf[vcf$normal_ref+vcf$normal_alt>=7,]
  vcf=vcf[vcf$tumor_alt>=3,]
  if (type=="somatic")
  {
    vcf=vcf[vcf$normal_alt/(vcf$normal_ref+vcf$normal_alt)<
      vcf$tumor_alt/(vcf$tumor_ref+vcf$tumor_alt)/2,]
    vcf=vcf[vcf$normal_alt/(vcf$normal_ref+vcf$normal_alt)<0.05,]
  }else
  {
    vcf=vcf[vcf$tumor_alt>5,]
  }
  vcf
}

read_vcf<-function(file)
{
  x=tryCatch({
    read.table(file,stringsAsFactors = F)
  }, error = function(e) { # give an empty VCF file
    cat(paste("Warning: failed to read",file,
              ". Maybe this caller didn't find any variants\n"))
    data.frame(V1=character(0),V2=numeric(0),V4=character(0),V5=character(0),V7=character(0),
      V8=character(0),normal_ref=numeric(0),normal_alt=numeric(0),
      tumor_ref=numeric(0),tumor_alt=numeric(0),stringsAsFactors = F)
  })
  unlink(file)
  x
}

#########  process tumor-only case first  ############

if (normal=="NA") # germline and somatic mutations are mixed together
{
  lofreq_germline=read_vcf("lofreq.vcf")
  lofreq_germline$V9=lofreq_germline$V10=lofreq_germline$V11=lofreq_germline$V8
  lofreq_germline=filter_vcf(lofreq_germline,"lofreq","germline")
  write.table(lofreq_germline[,c("V1","V2","V3","V4","V5","V8","normal_ref","normal_alt","tumor_ref",
    "tumor_alt")],file="germline_mutations.txt",col.names=F,row.names=F,sep="\t",quote=F)
  q()
}

#########  read and process germline vcfs  ###########

varscan_germline_indel=read_vcf("varscan.indel.Germline.vcf")
varscan_germline_snp=read_vcf("varscan.snp.Germline.vcf")
varscan_LOH_indel=read_vcf("varscan.indel.LOH.vcf")
varscan_LOH_snp=read_vcf("varscan.snp.LOH.vcf")

varscan_germline=rbind(varscan_germline_indel,varscan_germline_snp,varscan_LOH_indel,varscan_LOH_snp)
varscan_germline=filter_vcf(varscan_germline,"varscan","germline")
write.table(varscan_germline[,c("V1","V2","V3","V4","V5","V8","normal_ref","normal_alt","tumor_ref",
  "tumor_alt")],file="germline_mutations.txt",col.names=F,row.names=F,sep="\t",quote=F)

#########  read somatic vcfs  ##################

speedseq=read_vcf("left_speedseq2.vcf")
speedseq=filter_vcf(speedseq,"speedseq")

mutect=read_vcf("left_mutect.vcf")
mutect=filter_vcf(mutect,"mutect")

shimmer=read_vcf("left_somatic_diffs.readct.vcf")
if (dim(shimmer)[1]>0) {shimmer$V7="PASS"}
shimmer=filter_vcf(shimmer,"shimmer")

varscan_indel=read_vcf("left_varscan.indel.Somatic.hc.vcf")
varscan_indel=filter_vcf(varscan_indel,"varscan")
varscan_snp=read_vcf("left_varscan.snp.Somatic.hc.vcf")
varscan_snp=filter_vcf(varscan_snp,"varscan")
varscan=rbind(varscan_indel,varscan_snp)

unlink("left_passed.somatic.snvs.vcf")
strelka_indel=read_vcf("left_passed.somatic.indels.vcf")
if (dim(strelka_indel)[1]>0) {strelka_indel$V7="PASS"}
strelka=filter_vcf(strelka_indel,"strelka")

#########  combine somatic vcfs  #############

vcf=rbind(mutect,shimmer,speedseq,varscan,strelka)[,c("V1","V2","V4","V5","V8","normal_ref",
  "normal_alt","tumor_ref","tumor_alt")]
colnames(vcf)[1:5]=c("chr","pos","ref","alt","caller")
vcf$variant=paste(vcf$chr,vcf$pos,vcf$ref,vcf$alt)
if (dim(vcf)[1]==0) {stop("No valid mutations left in VCF file!\n")}

tmp1=aggregate(vcf$caller,by=list(vcf$variant),function(x) paste(x,collapse=","))
tmp2=aggregate(vcf[,c("normal_ref","normal_alt","tumor_ref","tumor_alt")],
               by=list(vcf$variant),mean)
vcf=cbind(tmp1,tmp2[,-1])
vcf$chr=sapply(strsplit(vcf$Group.1," "),function(x) x[1])
vcf$pos=as.numeric(sapply(strsplit(vcf$Group.1," "),function(x) x[2]))
vcf$ref=sapply(strsplit(vcf$Group.1," "),function(x) x[3])
vcf$alt=sapply(strsplit(vcf$Group.1," "),function(x) x[4])
vcf$pos2=vcf$pos+nchar(vcf$ref)-1

# important! A variant must have been found by >1 caller
vcf=vcf[grepl(",",vcf$x),] 

vcf=vcf[,c("chr","pos","pos2","ref","alt","x","normal_ref","normal_alt","tumor_ref","tumor_alt")]
write.table(vcf,file="somatic_mutations.txt",col.names = F,row.names = F,sep="\t",quote=F)