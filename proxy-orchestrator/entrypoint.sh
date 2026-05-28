#!/bin/bash
set -e

echo "Starting orchestrator with:"
echo "  AWS Region: ${AWS_REGION}"
echo "  ECS Cluster: ${ECS_CLUSTER}"
echo "  Task Definition: ${ECS_TASK_DEFINITION}"
echo "  Subnet: ${TASK_SUBNET}"
echo "  Security Group: ${TASK_SECURITY_GROUP}"

# Validate required environment variables
if [ -z "${TASK_SUBNET}" ]; then
    echo "ERROR: TASK_SUBNET environment variable is required"
    exit 1
fi

if [ -z "${TASK_SECURITY_GROUP}" ]; then
    echo "ERROR: TASK_SECURITY_GROUP environment variable is required"
    exit 1
fi

# Run the orchestrator
exec python orchestrator.py