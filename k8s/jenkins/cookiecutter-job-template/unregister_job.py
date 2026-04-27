"""values.yaml から Jenkins ジョブ定義を削除する。"""
import re
import sys

job_name = sys.argv[1]
values_file = sys.argv[2]

with open(values_file, "r", encoding="utf-8") as f:
    content = f.read()

if job_name not in content:
    print(f"Error: job '{job_name}' not found in {values_file}")
    sys.exit(1)

# managedJobs << 'job_name' + pipelineJob('job_name') { ... } ブロックを削除
pattern = (
    r"\n              managedJobs << '" + re.escape(job_name) + r"'\n"
    r"              pipelineJob\('" + re.escape(job_name) + r"'\) \{.*?\n              \}\n"
)
content = re.sub(pattern, "\n", content, flags=re.DOTALL)

with open(values_file, "w", encoding="utf-8") as f:
    f.write(content)

print(f"Unregistered job '{job_name}' from {values_file}")
