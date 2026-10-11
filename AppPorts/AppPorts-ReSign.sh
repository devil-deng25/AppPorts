#!/bin/bash
# AppPorts retired login-time signature mutation on every macOS version.
# Old LaunchAgents may still invoke this file during upgrade. Never read a
# preference or backup record as authorization to rewrite an application.
exit 0
