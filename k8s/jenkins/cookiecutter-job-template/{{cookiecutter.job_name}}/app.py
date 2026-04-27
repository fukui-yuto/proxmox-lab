"""{{ cookiecutter.description }}"""
import sys
import platform
import datetime

print("=" * 50)
print("Job: {{ cookiecutter.job_name }}")
print("{{ cookiecutter.description }}")
print("=" * 50)
print(f"Python version: {sys.version}")
print(f"Platform: {platform.platform()}")
print(f"Timestamp: {datetime.datetime.now().isoformat()}")
print("=" * 50)
print("Build successful!")
