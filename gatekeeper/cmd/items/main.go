// Backend behind the authorizer. It never parses a JWT: the tenant comes from the
// authorizer's context, which only API Gateway can set — hence the narrow
// aws_lambda_permission that makes API Gateway the only allowed caller.
package main

import (
	"context"
	"encoding/json"
	"log/slog"
	"os"

	"github.com/aws/aws-lambda-go/events"
	"github.com/aws/aws-lambda-go/lambda"
)

var logger = slog.New(slog.NewJSONHandler(os.Stdout, nil))

func handler(ctx context.Context, req events.APIGatewayProxyRequest) (events.APIGatewayProxyResponse, error) {
	log := logger.With("request_id", req.RequestContext.RequestID, "path", req.Path)

	// Absent context means the route lost its authorizer, or something invoked us
	// directly — our misconfiguration (500), not a bad caller (403). Never default
	// the tenant: a multi-tenant backend must not guess whose data to serve.
	tenantID := contextString(req, "tenant_id")
	if tenantID == "" {
		log.ErrorContext(ctx, "no tenant in authorizer context")
		return jsonResponse(500, map[string]string{"message": "Internal Server Error"})
	}

	sub := contextString(req, "sub")
	log.InfoContext(ctx, "request", "tenant_id", tenantID, "sub", sub)

	// Step 5 replaces this with a DynamoDB read keyed by tenantID.
	return jsonResponse(200, map[string]string{"tenant_id": tenantID, "sub": sub})
}

// contextString reads one authorizer context value. API Gateway delivers them as
// any, so anything that isn't a string counts as absent.
func contextString(req events.APIGatewayProxyRequest, key string) string {
	s, _ := req.RequestContext.Authorizer[key].(string)
	return s
}

func jsonResponse(status int, body map[string]string) (events.APIGatewayProxyResponse, error) {
	encoded, err := json.Marshal(body)
	if err != nil {
		return events.APIGatewayProxyResponse{StatusCode: 500}, err
	}
	return events.APIGatewayProxyResponse{
		StatusCode: status,
		Headers:    map[string]string{"Content-Type": "application/json"},
		Body:       string(encoded),
	}, nil
}

func main() {
	lambda.Start(handler)
}
