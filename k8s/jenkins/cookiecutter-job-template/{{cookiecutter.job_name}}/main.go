package main

import (
	"fmt"
	"runtime"
	"time"
)

// {{ cookiecutter.description }}
func main() {
	fmt.Println("==================================================")
	fmt.Println("Job: {{ cookiecutter.job_name }}")
	fmt.Println("{{ cookiecutter.description }}")
	fmt.Println("==================================================")
	fmt.Printf("Go version: %s\n", runtime.Version())
	fmt.Printf("Platform: %s/%s\n", runtime.GOOS, runtime.GOARCH)
	fmt.Printf("Timestamp: %s\n", time.Now().Format(time.RFC3339))
	fmt.Println("==================================================")
	fmt.Println("Build successful!")
}
