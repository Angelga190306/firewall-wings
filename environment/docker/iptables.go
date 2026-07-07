package docker

import (
	"context"
	"os"
	"os/exec"

	"github.com/apex/log"
)

func ensureDockerIptablesChains(ctx context.Context) {
	if info, err := os.Stat("/usr/local/bin/fix-docker-iptables.sh"); err == nil && !info.IsDir() && info.Mode()&0111 != 0 {
		cmd := exec.CommandContext(ctx, "/usr/local/bin/fix-docker-iptables.sh")
		if output, err := cmd.CombinedOutput(); err == nil {
			return
		} else {
			log.WithField("output", string(output)).WithError(err).Warn("docker iptables repair script failed, using embedded fallback")
		}
	}

	// Docker can fail container creation/start when these chains are missing after
	// an iptables flush. Re-create only the chain skeletons Docker needs to append
	// its own port mapping rules.
	runIptables(ctx, "-t", "nat", "-N", "DOCKER")
	ensureIptablesRule(ctx, []string{"-t", "nat", "-C", "PREROUTING", "-m", "addrtype", "--dst-type", "LOCAL", "-j", "DOCKER"}, []string{"-t", "nat", "-A", "PREROUTING", "-m", "addrtype", "--dst-type", "LOCAL", "-j", "DOCKER"})
	ensureIptablesRule(ctx, []string{"-t", "nat", "-C", "OUTPUT", "!", "-d", "127.0.0.0/8", "-m", "addrtype", "--dst-type", "LOCAL", "-j", "DOCKER"}, []string{"-t", "nat", "-A", "OUTPUT", "!", "-d", "127.0.0.0/8", "-m", "addrtype", "--dst-type", "LOCAL", "-j", "DOCKER"})

	runIptables(ctx, "-t", "filter", "-N", "DOCKER")
	runIptables(ctx, "-t", "filter", "-N", "DOCKER-USER")
	runIptables(ctx, "-t", "filter", "-N", "DOCKER-FORWARD")
	runIptables(ctx, "-t", "filter", "-N", "DOCKER-BRIDGE")
	runIptables(ctx, "-t", "filter", "-N", "DOCKER-CT")
	runIptables(ctx, "-t", "filter", "-N", "DOCKER-INTERNAL")
	removeIptablesRule(ctx, "FORWARD", "-j", "DOCKER")
	ensureIptablesRule(ctx, []string{"-C", "FORWARD", "-j", "DOCKER-USER"}, []string{"-I", "FORWARD", "-j", "DOCKER-USER"})
	ensureIptablesRule(ctx, []string{"-C", "FORWARD", "-j", "DOCKER-FORWARD"}, []string{"-A", "FORWARD", "-j", "DOCKER-FORWARD"})
	ensureIptablesRule(ctx, []string{"-C", "DOCKER-FORWARD", "-j", "DOCKER-CT"}, []string{"-A", "DOCKER-FORWARD", "-j", "DOCKER-CT"})
	ensureIptablesRule(ctx, []string{"-C", "DOCKER-FORWARD", "-j", "DOCKER-INTERNAL"}, []string{"-A", "DOCKER-FORWARD", "-j", "DOCKER-INTERNAL"})
	ensureIptablesRule(ctx, []string{"-C", "DOCKER-FORWARD", "-j", "DOCKER-BRIDGE"}, []string{"-A", "DOCKER-FORWARD", "-j", "DOCKER-BRIDGE"})
}

func removeIptablesRule(ctx context.Context, chain string, ruleArgs ...string) {
	for {
		checkArgs := append([]string{"-C", chain}, ruleArgs...)
		cmd := exec.CommandContext(ctx, "iptables", checkArgs...)
		if err := cmd.Run(); err != nil {
			return
		}
		deleteArgs := append([]string{"-D", chain}, ruleArgs...)
		runIptables(ctx, deleteArgs...)
	}
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
