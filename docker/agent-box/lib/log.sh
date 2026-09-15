#!/usr/bin/env bash
# docker/agent-box/lib/log.sh
# Logging for the host-side wrapper. Source it; do not execute it.
#
# All output goes to stderr so a command's real stdout (e.g. a kubeconfig
# being piped) stays clean. Colors only when stderr is a terminal.
#
#   log_info  "building image"      -> "agent-box: building image"
#   log_warn  "no key yet"          -> yellow
#   log_error "docker is not up"    -> red
#   die "message" [exit code]       -> log_error + exit (default 1)
# shellcheck shell=bash

if [[ -t 2 ]]; then
  _c_dim=$'\e[2m'; _c_yel=$'\e[33m'; _c_red=$'\e[31m'; _c_off=$'\e[0m'
else
  _c_dim=''; _c_yel=''; _c_red=''; _c_off=''
fi

log_info()  { printf '%sagent-box:%s %s\n' "$_c_dim" "$_c_off" "$*" >&2; }
log_warn()  { printf '%sagent-box: warn:%s %s\n' "$_c_yel" "$_c_off" "$*" >&2; }
log_error() { printf '%sagent-box: error:%s %s\n' "$_c_red" "$_c_off" "$*" >&2; }
die()       { log_error "$1"; exit "${2:-1}"; }
