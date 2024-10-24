#
# BASE artifact
#
FROM ubuntu:24.04 AS base

RUN apt-get update && apt-get install -y curl gnupg2 git

RUN curl -fsSL https://crystal-lang.org/install.sh | bash -s -- --channel=stable

#
# BUILDER artifact
#
FROM base AS builder

RUN mkdir -p /lib
WORKDIR /lib
COPY ./shard* /lib/

# RUN  crystal -v
RUN shards install

COPY ./ /lib

#
# SERVICE 
#
FROM builder AS service

ENV image_name=crystal-es

WORKDIR /lib
