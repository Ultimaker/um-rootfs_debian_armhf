# Introduction
The *um-update_toolbox* is a *squashfs* minimal root filesystem that can be mounted in early boot stages, with the purpose of providing tools to be able to perform complex setup and update operations. 

This toolbox image is based on *Linux Alpine*, a security-oriented, lightweight Linux distribution based on *Musl Libc* and *Busybox*. 

On top of the standard *distro* we install the required tooling, such as; *e2fsprogs-extra f2fs-tools rsync*, resulting in an image with a compressed size of less then 2.6M at time of writing. 

## Repository structure
#### Repo root directory:
- License and readme files
- Docker files used by *CI* for generating an isolated build environment.
- Scripts for building the software
- Configuration files for *Gitlab CI*

#### Config directory:
This directory contains configuration files that are used by the
system configuration scripts in the 'scripts' directory. The config files
are installed in the '/etc/jedi_system_update'.

#### Scripts directory:
Contains update and setup scripts. The main entrypoint is 'start_update.sh' which is installed
 in the system binary directory '/sbin', note that this is a hardcoded dependency for the 
 *um-kernel* repository since the *initramfs* init script looks for this script. The other
 configuration scripts are normally installed in '/usr/libexec/jedi_system_update.d'.    

#### Tests directory:
- A test to check the build environment
- A test to validate the generated toolbox functionality
- Unit tests to validate the system configuration scripts. 

## How to build
This repository is setup to use an existing *Docker* image from this repositories Docker registry. 
The image contains all the tools to be able to build the software. When Docker is not installed 
the build script will try to build on the host machine and is likely to fail because the required 
tools are not installed. When it is necessary to run the build without Docker, execute the 
'tests/buildenv.sh' script and see if the environment is missing requirements. 

By default the build script runs an environment check, builds the image and then validates 
it by running tests. The first and the latter can be disabled. Run the help of the 
'build_for_ultimaker.sh' script for usage information:  
```sh
> ./build_for_ultimaker.sh -h
    Usage: ./build_for_ultimaker.sh [OPTIONS]
        -c   Skip run of build environment checks
        -h   Print usage
        -t   Skip run of rootfs tests
```

## Adding update or setup routines to the toolbox
During the Kernels initramfs stage this toolbox image is mounted and the entrypoint script '/sbin/start_update.sh' 
will be executed if available.
 
The system configuration scripts are installed in '/usr/libexec/jedi_system_update.d' directory and are prefixed 
with a two digit number so the 'start_update.sh' script can sort them.
 
The um-update_toolbox will serve as a *chroot* environment for the update. Generic execution of all 
scripts is required and therefore the scripts are prefixed with a number so they can be sorted and
additional scripts can be added later. As a consequence a execution environment for 
the scripts is prepared so that the script can be executed generically.     

#### Toolbox runtime environment variables 

* TARGET_STORAGE_DEVICE    - The device to perform the system configuration on
* PARTITION_TABLE_FILE     - The partition table file used in the prepare_disk script,
                             default is 'jedi_emmc_sfdisk.table', implicitly the 
                             script will look for a counterpart checksum file:
                             '<filename>.sha512'
* UPDATE_EXCLUDE_LIST_FILE - A file containing all files and directories to be excluded
                             used by the 'update_files.sh script, default is 'jedi_update_exclude_list.txt'
* UPDATE_ROOTFS_SOURCE     - This is the directory within the toolbox root that contains the update files.
                             It is used e.g. in the 'update_files.sh' script as the source directory for the
                             update files. 
* SYSTEM_UPDATE_CONF_DIR   - The system update directory is a directory within the toolbox root 
                             that contains the system update configuration. The configuration files 
                             can be found in '/etc/jedi_system_update', i.e. the partition table and exclude
                             list file.
* SYSTEM_UPDATE_SCRIPT_DIR - The system update scripts directory is a directory within the toolbox root 
                             that contains the system update scripts. The system update scripts can be found
                             in (/usr/libexec/jedi_system_update.d). 

## Updating the docker image in the docker registry
We only want to update the docker image when required and we only want to do this after quality 
checks and when merged to master. Therefore Docker container changes should be tested locally first. 
To build a container locally all is needed to pass the name of the request image to the build script, 
and it will try to pull the image (which will fail) and build and run with the local image instead.
```sh
> CI_REGISTRY_IMAGE="local_test_image_name" ./build_for_ultimaker.sh
```
To make the changes available in the Docker repository follow the instruction as described on the 
confluence [CI/CD](https://confluence.ultimaker.com:8443/pages/viewpage.action?pageId=12431561) page.
