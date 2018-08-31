# Introduction
The 'um-update_toolbox_armhf' is a 'squashfs' minimal root filesystem that can be mounted in early boot stages, with the purpose of providing tools to be able to perform complex setup and update operations. 

This toolbox image is based on Linux Alpine, a security-oriented, lightweight Linux distribution based on musl libc and busybox. 

On top of the standard distro we install the required tooling, such as; e2fsprogs-extra f2fs-tools rsync, resulting in an image with a compressed size of less then 2.6M at time of writing. 

## Repository structure
#### Repo root directory:
- License and readme files
- Docker files used by CI for generating an isolated build environment see...
- Scripts for building the software
- Configuration files for Gitlab CI

#### Scripts directory:

Update or setup scripts, where the main entrypoint is startup.sh. These 
scripts will be placed in the toolbox '/sbin' folder  

#### Tests directory:
- A test to check the build environment
- A test to validate the generated toolbox functionality

## How to build
This repository is setup to use an existing docker image from our docker registry at gitlab. The image contains all the tools to be able to build the software. When docker is not installed the build script will try to build on the host machine and will probably fail because the required tools are not installed. When it is necessary to run the build without docker, execute the tests/buildenv.sh script and see if the environment is missing requirements. 

By default the build script runs an environment check, builds the image and then validates it by running tests. The first and the latter can be disabled. Run the help of the build_for_ultimaker.sh script for usage information:  
```sh
> ./build_for_ultimaker.sh -h
    Usage: ./build_for_ultimaker.sh [OPTIONS]
        -c   Skip run of build environment checks
        -h   Print usage
        -t   Skip run of rootfs tests
```

## Adding update or setup routines to the toolbox
During the initramfs routine (executed between 2st stage U-boot and 3th stage Linux debian load) this toolbox image mounted and the executable entryscript '/sbin/startup.sh' will be executed. This script shall be used to execute any required routine. Very important here is to make sure all required resources are nicely cleaned up and errors are properly handled, not to bring the system in an unrecoverable state. 

## Updating the docker image in the docker registry
We only want to update the docker image when required and we only want to do this after quality checks and when merged to master. Therefore Docker container changes should be tested locally first. To build a container locally all is needed to pass the name of the request image to the build script, and it will try to pull the image (which will fail) and build and run with the local image instead.
```sh
> CI_REGISTRY_IMAGE="local_test_image_name" ./build_for_ultimaker.sh
```
To make the changes available in the Docker repository follow the instruction as described on the confluence [CI/CD](https://confluence.ultimaker.com:8443/pages/viewpage.action?pageId=12431561) page.
