package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"strings"

	"github.com/MicahParks/keyfunc/v3"
	"github.com/aws/aws-lambda-go/events"
	"github.com/aws/aws-lambda-go/lambda"
	"github.com/golang-jwt/jwt/v5"
)

var logger = slog.New(slog.NewJSONHandler(os.Stdout, nil))

// Must be exactly "Unauthorized": API Gateway maps that string to 401.
var errUnauthorized = errors.New("Unauthorized")

// Set once per cold start in main(): resolves a token's kid to Auth0's public key.
var keyFunc jwt.Keyfunc

// Set once per cold start in main(). issuer must match Auth0's iss exactly, trailing slash included.
var issuer, audience string

func handler(ctx context.Context, req events.APIGatewayCustomAuthorizerRequestTypeRequest) (events.APIGatewayCustomAuthorizerResponse, error) {
	log := logger.With("request_id", req.RequestContext.RequestID, "method_arn", req.MethodArn)

	resource, err := wildcardResource(req.MethodArn)
	if err != nil {
		return events.APIGatewayCustomAuthorizerResponse{}, err
	}

	raw, ok := bearerToken(req.Headers)
	if !ok {
		log.InfoContext(ctx, "reject", "reason", "missing or malformed Authorization header")
		return events.APIGatewayCustomAuthorizerResponse{}, errUnauthorized
	}

	// A token was presented but is wrong: 403. Never log the token itself.
	token, err := verifyToken(raw, keyFunc, issuer, audience)
	if err != nil {
		log.InfoContext(ctx, "deny", "reason", err.Error())
		return policy("anonymous", "Deny", resource), nil
	}

	sub, _ := token.Claims.GetSubject()
	log.InfoContext(ctx, "allow", "sub", sub)
	return policy(sub, "Allow", resource), nil
}

// verifyToken checks the signature against the key kf returns for the token's kid,
// then iss, aud and exp. The algorithm is pinned to RS256: the token's own header
// must not choose it. exp is required so a token with no expiry can't pass.
func verifyToken(raw string, kf jwt.Keyfunc, iss, aud string) (*jwt.Token, error) {
	return jwt.Parse(raw, kf,
		jwt.WithValidMethods([]string{"RS256"}),
		jwt.WithIssuer(iss),
		jwt.WithAudience(aud),
		jwt.WithExpirationRequired(),
	)
}

func bearerToken(headers map[string]string) (string, bool) {
	for k, v := range headers {
		if !strings.EqualFold(k, "Authorization") {
			continue
		}
		scheme, token, found := strings.Cut(strings.TrimSpace(v), " ")
		if !found || !strings.EqualFold(scheme, "Bearer") {
			return "", false
		}
		token = strings.TrimSpace(token)
		return token, token != ""
	}
	return "", false
}

func policy(principal, effect, resource string) events.APIGatewayCustomAuthorizerResponse {
	return events.APIGatewayCustomAuthorizerResponse{
		PrincipalID: principal,
		PolicyDocument: events.APIGatewayCustomAuthorizerPolicy{
			Version: "2012-10-17",
			Statement: []events.IAMPolicyStatement{{
				Action:   []string{"execute-api:Invoke"},
				Effect:   effect,
				Resource: []string{resource},
			}},
		},
	}
}

// wildcardResource turns ".../apiId/stage/GET/hello" into ".../apiId/stage/*/*",
// so a cached decision covers every route, not just the one that triggered it.
func wildcardResource(methodArn string) (string, error) {
	parts := strings.SplitN(methodArn, "/", 3)
	if len(parts) < 2 || parts[0] == "" || parts[1] == "" {
		return "", fmt.Errorf("unexpected method ARN %q", methodArn)
	}
	return parts[0] + "/" + parts[1] + "/*/*", nil
}

func main() {
	domain := os.Getenv("AUTH0_DOMAIN")
	audience = os.Getenv("AUTH0_AUDIENCE")
	if domain == "" || audience == "" {
		logger.Error("AUTH0_DOMAIN and AUTH0_AUDIENCE must be set")
		os.Exit(1)
	}
	issuer = "https://" + domain + "/"

	// Built once per cold start; keyfunc caches the JWKS and refetches on an unknown kid.
	jwks, err := keyfunc.NewDefaultCtx(context.Background(), []string{"https://" + domain + "/.well-known/jwks.json"})
	if err != nil {
		logger.Error("jwks init failed", "error", err)
		os.Exit(1)
	}
	keyFunc = jwks.Keyfunc

	lambda.Start(handler)
}
