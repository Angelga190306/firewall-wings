package docker

import (
	"context"
	"os/exec"

	"github.com/apex/log"
)

func ensureDockerIptablesChains(ctx context.Context) {
	// Docker can fail container creation/start when these chains are missing after
	// an iptables flush. Re-create only the chain skeletons Docker needs to append
	// its own port mapping rules.
	runIptables(ctx, "-t", "nat", "-N", "DOCKER")
	ensureIptablesRule(ctx, []string{"-t", "nat", "-C", "PREROUTING", "-m", "addrtype", "--dst-type", "LOCAL", "-j", "DOCKER"}, []string{"-t", "nat", "-A", "PREROUTING", "-m", "addrtype", "--dst-type", "LOCAL", "-j", "DOCKER"})

	runIptables(ctx, "-t", "filter", "-N", "DOCKER")
	runIptables(ctx, "-t", "filter", "-N", "DOCKER-USER")
	ensureIptablesRule(ctx, []string{"-C", "FORWARD", "-j", "DOCKER"}, []string{"-I", "FORWARD", "-j", "DOCKER"})
	ensureIptablesRule(ctx, []string{"-C", "FORWARD", "-j", "DOCKER-USER"}, []string{"-A", "FORWARD", "-j", "DOCKER-USER"})
}

func ensureIptablesRule(ctx context.Context, checkArgs []string, addArgs []string) {
	cmd := exec.CommandContext(ctx, "iptables", checkArgs...)
	if err := cmd.Run(); err == nil {
		return
	}
	runIptables(ctx, addArgs...)
}

func runIptables(ctx context.Context, args ...string) {
	cmd := exec.CommandContext(ctx, "iptables", args...)
	if output, err := cmd.CombinedOutput(); err != nil {
		// Chain creation exits non-zero if the chain already exists. That is safe.
		log.WithField("args", args).WithField("output", string(output)).Debug("iptables command skipped or failed")
	}
}
