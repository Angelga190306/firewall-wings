package router

import (
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"

	"github.com/pterodactyl/wings/router/middleware"
)

func postServerFirewallSync(c *gin.Context) {
	s := middleware.ExtractServer(c)

	if err := s.SyncFirewallFromPanel(c.Request.Context()); err != nil {
		message := err.Error()
		status := http.StatusBadRequest

		if stringsContainsAny(message,
			"firewall backend is not available",
			"wings must run as root",
			"invalid remote ip",
			"invalid allocation ip",
			"invalid action",
			"invalid protocol",
			"invalid port",
			"address family mismatch",
		) {
			c.AbortWithStatusJSON(status, gin.H{"error": message})
			return
		}

		middleware.CaptureAndAbort(c, err)
		return
	}

	c.Status(http.StatusNoContent)
}

func stringsContainsAny(value string, needles ...string) bool {
	for _, needle := range needles {
		if needle != "" && strings.Contains(value, needle) {
			return true
		}
	}

	return false
}
