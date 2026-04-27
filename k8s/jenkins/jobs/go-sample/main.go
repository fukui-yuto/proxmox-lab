package main

import (
	"fmt"
	"runtime"
	"time"
)

// Go 動作確認ジョブ
func main() {
	fmt.Println("==================================================")
	fmt.Println("Job: go-sample")
	fmt.Println("Go 動作確認ジョブ")
	fmt.Println("==================================================")
	fmt.Printf("Go version: %s\n", runtime.Version())
	fmt.Printf("Platform: %s/%s\n", runtime.GOOS, runtime.GOARCH)
	fmt.Printf("Timestamp: %s\n", time.Now().Format(time.RFC3339))
	fmt.Println("==================================================")
	fmt.Println("Build successful!")
}
