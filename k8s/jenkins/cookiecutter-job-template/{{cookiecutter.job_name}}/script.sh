#!/bin/sh
# {{ cookiecutter.description }}

echo "=================================================="
echo "Job: {{ cookiecutter.job_name }}"
echo "{{ cookiecutter.description }}"
echo "=================================================="
echo "OS: $(uname -a)"
echo "Timestamp: $(date -Iseconds)"
echo "=================================================="
echo "Build successful!"
