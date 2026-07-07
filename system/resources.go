package system

import (
	"bufio"
	"fmt"
	"os"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"time"
)

type ResourceUsage struct {
	Memory ResourceStat `json:"memory"`
	CPU    CPUStat      `json:"cpu"`
	Disk   ResourceStat `json:"disk"`
}

type ResourceStat struct {
	Total     int64   `json:"total"`
	Used      int64   `json:"used"`
	Available int64   `json:"available"`
	Percent   float64 `json:"percent"`
}

type CPUStat struct {
	Percent float64 `json:"percent"`
	Cores   int     `json:"cores"`
}

func GetResourceUsage() (*ResourceUsage, error) {
	mem, err := getMemoryUsage()
	if err != nil {
		return nil, fmt.Errorf("failed to get memory usage: %w", err)
	}

	cpu, err := getCPUUsage()
	if err != nil {
		return nil, fmt.Errorf("failed to get cpu usage: %w", err)
	}

	disk, err := getDiskUsage("/")
	if err != nil {
		return nil, fmt.Errorf("failed to get disk usage: %w", err)
	}

	return &ResourceUsage{
		Memory: *mem,
		CPU:    *cpu,
		Disk:   *disk,
	}, nil
}

func getMemoryUsage() (*ResourceStat, error) {
	f, err := os.Open("/proc/meminfo")
	if err != nil {
		return nil, err
	}
	defer f.Close()

	var total, available int64
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := scanner.Text()
		switch {
		case strings.HasPrefix(line, "MemTotal:"):
			total = parseMeminfoValue(line)
		case strings.HasPrefix(line, "MemAvailable:"):
			available = parseMeminfoValue(line)
		}
	}

	if total == 0 {
		return nil, fmt.Errorf("could not parse MemTotal from /proc/meminfo")
	}

	used := total - available
	percent := float64(used) / float64(total) * 100.0

	return &ResourceStat{
		Total:     total * 1024,
		Used:      used * 1024,
		Available: available * 1024,
		Percent:   roundToOne(percent),
	}, nil
}

func parseMeminfoValue(line string) int64 {
	parts := strings.Fields(line)
	if len(parts) < 2 {
		return 0
	}
	v, _ := strconv.ParseInt(parts[1], 10, 64)
	return v
}

func getCPUUsage() (*CPUStat, error) {
	prevIdle, prevTotal := readCPU()
	if prevTotal == 0 {
		return nil, fmt.Errorf("could not read /proc/stat")
	}

	time.Sleep(500 * time.Millisecond)

	idle, total := readCPU()
	if total == 0 {
		return nil, fmt.Errorf("could not read /proc/stat")
	}

	deltaIdle := idle - prevIdle
	deltaTotal := total - prevTotal

	var percent float64
	if deltaTotal > 0 {
		percent = float64(deltaTotal-deltaIdle) / float64(deltaTotal) * 100.0
	}

	return &CPUStat{
		Percent: roundToOne(percent),
		Cores:   runtime.NumCPU(),
	}, nil
}

func readCPU() (idle, total uint64) {
	f, err := os.Open("/proc/stat")
	if err != nil {
		return 0, 0
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := scanner.Text()
		if !strings.HasPrefix(line, "cpu ") {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 5 {
			return 0, 0
		}
		for i := 1; i < len(fields); i++ {
			v, _ := strconv.ParseUint(fields[i], 10, 64)
			total += v
		}
		idle, _ = strconv.ParseUint(fields[4], 10, 64)
		break
	}
	return
}

func getDiskUsage(path string) (*ResourceStat, error) {
	var stat syscall.Statfs_t
	if err := syscall.Statfs(path, &stat); err != nil {
		return nil, err
	}

	total := int64(stat.Blocks) * stat.Bsize
	available := int64(stat.Bavail) * stat.Bsize
	used := total - available

	var percent float64
	if total > 0 {
		percent = float64(used) / float64(total) * 100.0
	}

	return &ResourceStat{
		Total:     total,
		Used:      used,
		Available: available,
		Percent:   roundToOne(percent),
	}, nil
}

func roundToOne(v float64) float64 {
	return float64(int64(v*10)) / 10
}
