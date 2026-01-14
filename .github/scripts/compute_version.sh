#!/usr/bin/env bash
set -euo pipefail

build_name="${BUILD_NAME_INPUT:-}"
if [[ -z "${build_name:-}" ]]; then
  echo "Missing build_name input."
  exit 1
fi

build_number="${BUILD_NUMBER_INPUT:-}"
if [[ -z "${build_number:-}" ]]; then
  echo "Missing build_number input."
  exit 1
fi

if ! [[ "$build_number" =~ ^[0-9]+$ ]]; then
  echo "build_number must be an integer (got: $build_number)" >&2
  exit 1
fi

version_full="${build_name}+${build_number}"
app_version="${build_name}.${build_number}"

echo "Using version: ${version_full}"

{
  echo "BUILD_NAME=${build_name}"
  echo "BUILD_NUMBER=${build_number}"
  echo "VERSION_FULL=${version_full}"
  echo "APP_VERSION=${app_version}"
  echo "APP_VERSION_FULL=${version_full}"
} >> "${GITHUB_ENV}"
