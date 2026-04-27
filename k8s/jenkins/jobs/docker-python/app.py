import sys
import platform
import datetime

print("=" * 50)
print("Hello from Docker Python Pipeline!")
print("=" * 50)
print(f"Python version: {sys.version}")
print(f"Platform: {platform.platform()}")
print(f"Timestamp: {datetime.datetime.now().isoformat()}")
print("=" * 50)
print("Build successful!")
