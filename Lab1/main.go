// api is the helper service for Lab 1 resource isolation experiments.
package main

import (
	"fmt"
	"log"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"sync"
	"sync/atomic"
	"time"
)

const (
	mib       = 1024 * 1024
	invalidMB = "mb must be a single positive decimal integer within the platform memory size range\n"
)

var (
	memoryMu    sync.Mutex
	retained    [][]byte
	retainedMiB uint64
	burnOnce    sync.Once
	// Publishing the computation makes its result observable to the compiler.
	burnResult uint64
)

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}
	portNumber, err := strconv.Atoi(port)
	if err != nil || portNumber < 1 || portNumber > 65535 {
		log.Fatal("PORT must be an integer from 1 to 65535")
	}

	server := &http.Server{
		Addr:              ":" + strconv.Itoa(portNumber),
		Handler:           http.HandlerFunc(handle),
		ReadHeaderTimeout: 5 * time.Second,
	}
	log.Printf("api listening on %s; PID=%d", server.Addr, os.Getpid())
	log.Fatal(server.ListenAndServe())
}

func handle(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	if r.URL.Path != "/health" && r.URL.Path != "/eat" && r.URL.Path != "/burn" {
		w.WriteHeader(http.StatusNotFound)
		fmt.Fprint(w, "not found\n")
		return
	}
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		w.WriteHeader(http.StatusMethodNotAllowed)
		fmt.Fprint(w, "method not allowed\n")
		return
	}

	switch r.URL.Path {
	case "/health":
		fmt.Fprint(w, "ok")
	case "/eat":
		eat(w, r)
	case "/burn":
		burnOnce.Do(func() { go burn() })
		fmt.Fprint(w, "burning\n")
	}
}

func eat(w http.ResponseWriter, r *http.Request) {
	// ParseQuery also rejects malformed URL escapes instead of ignoring them.
	values, err := url.ParseQuery(r.URL.RawQuery)
	query := values["mb"]
	if err != nil || len(query) != 1 || query[0] == "" {
		w.WriteHeader(http.StatusBadRequest)
		fmt.Fprint(w, invalidMB)
		return
	}
	for _, digit := range query[0] {
		if digit < '0' || digit > '9' {
			w.WriteHeader(http.StatusBadRequest)
			fmt.Fprint(w, invalidMB)
			return
		}
	}
	mb, err := strconv.ParseUint(query[0], 10, 64)
	maxMiB := uint64(^uint(0)>>1) / mib
	if err != nil || mb == 0 || mb > maxMiB {
		w.WriteHeader(http.StatusBadRequest)
		fmt.Fprint(w, invalidMB)
		return
	}

	// Serialize allocation requests; /health and /burn do not take this lock.
	memoryMu.Lock()
	if mb > maxMiB-retainedMiB {
		memoryMu.Unlock()
		w.WriteHeader(http.StatusBadRequest)
		fmt.Fprint(w, invalidMB)
		return
	}
	block := make([]byte, int(mb*mib))
	// Write every byte to fault in the pages, rather than only reserving address
	// space. Holding the slice globally prevents Go's GC from reclaiming it.
	for i := range block {
		block[i] = 1
	}
	retained = append(retained, block)
	retainedMiB += mb
	total := retainedMiB
	memoryMu.Unlock()
	fmt.Fprintf(w, "allocated %d MiB; retained %d MiB\n", mb, total)
}

func burn() {
	x := uint64(1)
	for {
		for i := 0; i < 100000; i++ {
			x ^= x << 13
			x ^= x >> 7
			x ^= x << 17
		}
		atomic.StoreUint64(&burnResult, x)
	}
}
