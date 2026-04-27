"""values.yaml に新しい Jenkins ジョブ定義を追加する。"""
import sys

job_name = sys.argv[1]
description = sys.argv[2]
values_file = sys.argv[3]

new_entry = (
    "          - script: >\n"
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

with open(values_file, "r", encoding="utf-8") as f:
    content = f.read()

content = content.replace("\nagent:\n", "\n" + new_entry + "\nagent:\n")

with open(values_file, "w", encoding="utf-8") as f:
    f.write(content)

print(f"Registered job '{job_name}' in {values_file}")
