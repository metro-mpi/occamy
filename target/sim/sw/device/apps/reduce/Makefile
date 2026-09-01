# Minimal cross-cluster compute+reduce workload. No generated data needed.

MK_DIR  := $(dir $(realpath $(lastword $(MAKEFILE_LIST))))
SRC_DIR := $(realpath $(MK_DIR)/src)

APP  ?= reduce
SRCS ?= $(realpath $(SRC_DIR)/main.c)

include ../common.mk
