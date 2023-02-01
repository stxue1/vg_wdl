vg\_wdl
---------------
Eric T Dawson, Mike Lin and Charles Markello, Jean Monlong, Adam Novak
MIT License, 2022

Workflow Description Language (WDL) scripts for common vg workflows

## Workflows

### Workflow for processing single sample datasets

- [workflow file](https://github.com/vgteam/vg_wdl/raw/master/workflows/vg_multi_map_call.wdl)
- [parameter file](https://github.com/vgteam/vg_wdl/raw/master/params/vg_multi_map_call.inputs_tiny.http_url.json)
- [Dockstore page](https://dockstore.org/workflows/github.com/vgteam/vg_wdl/vg-pipeline-workingexample:master?tab=info)

### Workflow for processing pedigree datasets

- [workflow file](https://github.com/vgteam/vg_wdl/raw/master/workflows/vg_trio_multi_map_call.wdl)
- [parameter file](https://github.com/vgteam/vg_wdl/raw/master/params/vg_trio_multi_map_call.inputs_tiny.http_url.json)

### Workflow for mapping and calling structural variants in a single sample

- [workflow file](https://github.com/vgteam/vg_wdl/raw/svpack/workflows/vg_map_call_sv.wdl)
- [parameter file](https://github.com/vgteam/vg_wdl/raw/svpack/params/vg_map_call_sv_test.inputs.json)
- [Dockstore page](https://dockstore.org/workflows/github.com/vgteam/vg_wdl/vg_map_call_sv:svpack?tab=info)

### Workflow for mapping short reads with vg Giraffe and calling short variants with DeepVariant

- [workflow file](workflows/giraffe_and_deepvariant.wdl)
- [parameter file](params/giraffe_and_deepvariant.json)
- [Dockstore page](https://dockstore.org/workflows/github.com/vgteam/vg_wdl/GiraffeDeepVariant:master?tab=info)
- Two other flavors of this workflow are also available:
    1. [GiraffeDeepVariantLite](https://dockstore.org/workflows/github.com/vgteam/vg_wdl/GiraffeDeepVariantLite:master?tab=info) defined by [giraffe_and_deepvariant_lite.wdl](workflows/giraffe_and_deepvariant_lite.wdl) is the slightly more optimized workflow that we used to analyze the 1000 Genomes Project dataset with the HPRC pangenome.
    1. [GiraffeDeepVariantFromGAM](https://dockstore.org/workflows/github.com/vgteam/vg_wdl/GiraffeDeepVariantFromGAM:master?tab=info) defined by [giraffe_and_deepvariant_fromGAM.wdl](workflows/giraffe_and_deepvariant_fromGAM.wdl) starts from already aligned reads in the GAM format
    1. [Giraffe](https://dockstore.org/workflows/github.com/vgteam/vg_wdl/Giraffe:master?tab=info) defined by [giraffe.wdl](workflows/giraffe.wdl) produces aligned reads in GAF, GAM and/or BAM format.
    


## Usage

### Dockstore

The workflows that were deposited on [Dockstore](https://dockstore.org/) can be launched using [its command line](https://docs.dockstore.org/en/stable/launch-with/launch.html) or on platform like [Terra](https://app.terra.bio/).

### Using miniwdl

Install miniwdl in a python 3 virtual environment
```
git clone https://github.com/chanzuckerberg/miniwdl.git
virtualenv miniwdl_venv
source miniwdl_venv/bin/activate
pip3 install ./miniwdl
deactivate
```
Download `.wdl` workflow file and `.json` input file
```
wget https://github.com/vgteam/vg_wdl/raw/master/workflows/vg_multi_map_call.wdl
wget https://github.com/vgteam/vg_wdl/raw/master/params/vg_multi_map_call.inputs_tiny.http_url.json
```
Activate the miniwdl virtual environment and run the example workflow
```
source miniwdl_venv/bin/activate
miniwdl cromwell vg_multi_map_call.wdl -i vg_multi_map_call.inputs_tiny.http_url.json
```
To modify the input parameters, edit the input `.json` with the necessary changes.

## Docker Containers

WDL needs the runtime Docker image to be present on Dockerhub.  
VG images are available in [quay](https://quay.io/repository/vgteam/vg?tab=tags)
and selected images are available in [ the variantgraphs Dockerhub](https://cloud.docker.com/u/variantgraphs/repository/docker/variantgraphs/vg),  
and can be pulled with:  
```
docker pull variantgraphs/vg  
```

Specific tags can be specified like so:  
```
# Get the vg 1.3.1 release  
docker pull variantgraphs/vg:1.3.1
```

## Contributing, Help, Bugs and Requests

Please open an Issue on [github](https://github.com/vgteam/vg_wdl) for help, bug reports, or feature requests.
When doing so, please remember that vg\_wdl is open-source software made by a community of developers. 
Please be considerate and support a positive environment.

## Testing locally

To test the workflow locally, e.g. on the [small simulated dataset](tests/small_sim_graph), you can run it with Cromwell. First fetch a current Cromwell JAR file from [the latest Cromwell release](https://github.com/broadinstitute/cromwell/releases/latest/). Then set `CROMWELL_JAR=/path/to/cromwell-<whatever>.jar` in your shell. Then you can run:

```
## Giraffe-DV starting from two FASTQ files or a CRAM file
java -jar $CROMWELL_JAR run workflows/giraffe_and_deepvariant.wdl -i params/giraffe_and_deepvariant.json
java -jar $CROMWELL_JAR run workflows/giraffe_and_deepvariant.wdl -i params/giraffe_and_deepvariant_cram.json
java -jar $CROMWELL_JAR run workflows/giraffe_and_deepvariant_lite.wdl -i params/giraffe_and_deepvariant_lite.json

## Giraffe-DV starting from a GAM/GAF file
java -jar $CROMWELL_JAR run workflows/giraffe_and_deepvariant_fromGAM.wdl -i params/giraffe_and_deepvariant_gam.json
java -jar $CROMWELL_JAR run workflows/giraffe_and_deepvariant_fromGAM.wdl -i params/giraffe_and_deepvariant_gam_single_end.json
java -jar $CROMWELL_JAR run workflows/giraffe_and_deepvariant_fromGAM.wdl -i params/giraffe_and_deepvariant_gaf.json

## GAM/GAF sorting
java -jar $CROMWELL_JAR run workflows/sort_graph_aligned_reads.wdl -i params/sort_graph_aligned_reads.gam.json
java -jar $CROMWELL_JAR run workflows/sort_graph_aligned_reads.wdl -i params/sort_graph_aligned_reads.gaf.json

## Hap.py evaluation
java -jar $CROMWELL_JAR run workflows/happy_evaluation.wdl -i params/happy_evaluation.json

# Giraffe only
java -jar $CROMWELL_JAR run workflows/giraffe.wdl -i params/giraffe.json
java -jar $CROMWELL_JAR run workflows/giraffe.wdl -i params/giraffe.singleended.json
```
