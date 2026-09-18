package main

import (
	"context"
	"log/slog"
	"os"

	"github.com/aws/aws-lambda-go/events"
	"github.com/aws/aws-lambda-go/lambda"
)

var logger = slog.New(slog.NewJSONHandler(os.Stdout, nil))

func handler(ctx context.Context, req events.APIGatewayProxyRequest) (events.APIGatewayProxyResponse, error) {
	// Log selected fields, never the whole event: from Step 3 it carries the bearer token.
	logger.InfoContext(ctx, "request",
		"method", req.HTTPMethod,
		"path", req.Path,
		"request_id", req.RequestContext.RequestID,
	)

	return events.APIGatewayProxyResponse{
		StatusCode: 200,
		Headers:    map[string]string{"Content-Type": "application/json"},
		Body:       `{"message":"hello from gatekeeper"}`,
	}, nil
}

func main() {
	lambda.Start(handler)
}
