package router

import (
	"net/http"

	"github.com/gin-gonic/gin"
	"github.com/pterodactyl/wings/router/middleware"
	"github.com/pterodactyl/wings/system"
)

func getSystemResources(c *gin.Context) {
	resources, err := system.GetResourceUsage()
	if err != nil {
		middleware.CaptureAndAbort(c, err)
		return
	}

	c.JSON(http.StatusOK, resources)
}
