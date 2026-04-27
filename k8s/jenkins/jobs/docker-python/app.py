import sys
import platform
import datetime
import requests

print("=" * 50)
print("Hello from Docker Python Pipeline!")
print("=" * 50)
print(f"Python version: {sys.version}")
print(f"Platform: {platform.platform()}")
print(f"Timestamp: {datetime.datetime.now().isoformat()}")
print()

print("[Network Test] Fetching https://httpbin.org/get ...")
resp = requests.get("https://httpbin.org/get", timeout=10)
print(f"  Status: {resp.status_code}")
print(f"  Origin IP: {resp.json().get('origin', 'unknown')}")
print()

print("=" * 50)
print("Build successful!")
