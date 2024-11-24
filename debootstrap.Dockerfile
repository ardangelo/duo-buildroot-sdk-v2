FROM docker.io/library/debian:latest

RUN apt-get update \
	&& apt-get install -y \
		xz-utils parted debootstrap cu qemu-user-static binfmt-support less nano rsync
