#!/bin/sh
emacs -Q --debug-init --fg-daemon -l scripts/publish.el --eval "(publish-and-serve)"
