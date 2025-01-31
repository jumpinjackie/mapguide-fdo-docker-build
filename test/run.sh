#!/bin/sh
# Run all mapagent test suites
npx httpyac *_api.http --all --bail --output headers
# Run post install sanity check
npx httpyac post_install_checks.http --all --bail --output headers
# Run teardown
npx httpyac _teardown.http --all --bail --output headers
