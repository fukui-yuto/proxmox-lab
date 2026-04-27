"""言語に応じて不要なファイルを削除する。"""
import os

language = "{{ cookiecutter.language }}"

remove_map = {
    "python": ["main.go", "go.mod", "index.js", "package.json", "script.sh"],
    "go":     ["app.py", "index.js", "package.json", "script.sh"],
    "node":   ["app.py", "main.go", "go.mod", "script.sh"],
    "shell":  ["app.py", "main.go", "go.mod", "index.js", "package.json"],
}

for f in remove_map.get(language, []):
    path = os.path.join(os.getcwd(), f)
    if os.path.exists(path):
        os.remove(path)
