"""values.yaml に新しい Jenkins ジョブ定義を追加する。"""
import sys

job_name = sys.argv[1]
description = sys.argv[2]
values_file = sys.argv[3]

# cleanup 行の直前に挿入するジョブ定義ブロック
new_entry = (
    "\n"
    "              managedJobs << '{name}'\n"
    "              pipelineJob('{name}') {{\n"
    "                description('{desc}')\n"
    "                definition {{\n"
    "                  cpsScm {{\n"
    "                    scm {{\n"
    "                      git {{\n"
    "                        remote {{\n"
    "                          url('https://github.com/fukui-yuto/proxmox-lab.git')\n"
    "                        }}\n"
    "                        branches('*/main')\n"
    "                      }}\n"
    "                    }}\n"
    "                    scriptPath('k8s/jenkins/jobs/{name}/Jenkinsfile')\n"
    "                  }}\n"
    "                }}\n"
    "              }}\n"
).format(name=job_name, desc=description)

CLEANUP_MARKER = "              Jenkins.instance.items.findAll"

with open(values_file, "r", encoding="utf-8") as f:
    content = f.read()

if job_name in content:
    print(f"Error: job '{job_name}' already exists in {values_file}")
    sys.exit(1)

content = content.replace(CLEANUP_MARKER, new_entry + CLEANUP_MARKER)

with open(values_file, "w", encoding="utf-8") as f:
    f.write(content)

print(f"Registered job '{job_name}' in {values_file}")
