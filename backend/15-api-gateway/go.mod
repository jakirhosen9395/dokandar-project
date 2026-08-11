module github.com/dokandar/dokandar-gateway

// Spec target is "Go 1.26 / Echo v5". Echo v5 is pre-GA and apmechov5 does not
// exist, so the buildable target is Echo v4 (github.com/labstack/echo/v4) — the
// same call shape the rest of the Go fleet (10-wallet/02-profile) compiles with.
// `go mod tidy` in the Dockerfile build stage resolves go.sum + the indirects.
go 1.25

require (
	github.com/golang-jwt/jwt/v5 v5.2.1
	github.com/google/uuid v1.6.0
	github.com/kelseyhightower/envconfig v1.4.0
	github.com/labstack/echo/v4 v4.13.3
	github.com/prometheus/client_golang v1.20.5
	github.com/redis/go-redis/v9 v9.7.0
	go.elastic.co/apm/v2 v2.6.2
	go.mongodb.org/mongo-driver v1.17.1
)
