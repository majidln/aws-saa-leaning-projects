package main

import (
	"bytes"
	"context"
	"encoding/json"
	"log/slog"
	"strings"
	"testing"

	"github.com/aws/aws-lambda-go/events"
)

const (
	testTenant = "tenant-a"
	testSub    = "client123@clients"
)

// captureLogs redirects the package logger so a test can assert on what was written.
func captureLogs(t *testing.T) *bytes.Buffer {
	t.Helper()
	old := logger
	buf := &bytes.Buffer{}
	logger = slog.New(slog.NewJSONHandler(buf, nil))
	t.Cleanup(func() { logger = old })
	return buf
}

// requestWithContext builds what API Gateway delivers after the authorizer allowed
// the request: context values arrive as any, not string.
func requestWithContext(authCtx map[string]any) events.APIGatewayProxyRequest {
	return events.APIGatewayProxyRequest{
		HTTPMethod: "GET",
		Path:       "/items",
		RequestContext: events.APIGatewayProxyRequestContext{
			RequestID:  "test-request-id",
			Authorizer: authCtx,
		},
	}
}

func allowedRequest() events.APIGatewayProxyRequest {
	return requestWithContext(map[string]any{
		"tenant_id": testTenant,
		"sub":       testSub,
		"scope":     "read:items write:items",
	})
}

func decodeBody(t *testing.T, resp events.APIGatewayProxyResponse) map[string]string {
	t.Helper()
	var body map[string]string
	if err := json.Unmarshal([]byte(resp.Body), &body); err != nil {
		t.Fatalf("body is not JSON (%q): %v", resp.Body, err)
	}
	return body
}

func TestHandlerReturnsTenantFromContext(t *testing.T) {
	captureLogs(t)

	resp, err := handler(context.Background(), allowedRequest())
	if err != nil {
		t.Fatalf("handler() error = %v", err)
	}
	if resp.StatusCode != 200 {
		t.Errorf("status = %d, want 200", resp.StatusCode)
	}
	if ct := resp.Headers["Content-Type"]; ct != "application/json" {
		t.Errorf("Content-Type = %q, want application/json", ct)
	}
	body := decodeBody(t, resp)
	if body["tenant_id"] != testTenant {
		t.Errorf("tenant_id = %q, want %q", body["tenant_id"], testTenant)
	}
	if body["sub"] != testSub {
		t.Errorf("sub = %q, want %q", body["sub"], testSub)
	}
}

func TestHandlerServesEachTenantItsOwn(t *testing.T) {
	for _, tenant := range []string{"tenant-a", "tenant-b"} {
		t.Run(tenant, func(t *testing.T) {
			captureLogs(t)

			resp, err := handler(context.Background(), requestWithContext(map[string]any{
				"tenant_id": tenant,
				"sub":       testSub,
			}))
			if err != nil {
				t.Fatalf("handler() error = %v", err)
			}
			if got := decodeBody(t, resp)["tenant_id"]; got != tenant {
				t.Errorf("tenant_id = %q, want %q", got, tenant)
			}
		})
	}
}

// No usable tenant means the route lost its authorizer, or we were invoked directly:
// our misconfiguration (500), never a guess at the tenant.
func TestHandlerFailsWithoutUsableTenant(t *testing.T) {
	tests := map[string]map[string]any{
		"nil context":       nil,
		"empty context":     {},
		"key absent":        {"sub": testSub},
		"empty string":      {"tenant_id": ""},
		"not a string":      {"tenant_id": 42},
		"null":              {"tenant_id": nil},
		"array":             {"tenant_id": []string{"tenant-a"}},
		"nested object":     {"tenant_id": map[string]any{"id": "tenant-a"}},
		"unexpected casing": {"Tenant_Id": testTenant},
	}
	for name, authCtx := range tests {
		t.Run(name, func(t *testing.T) {
			captureLogs(t)

			resp, err := handler(context.Background(), requestWithContext(authCtx))
			if err != nil {
				t.Fatalf("handler() error = %v, want a 500 response and no error", err)
			}
			if resp.StatusCode != 500 {
				t.Errorf("status = %d, want 500", resp.StatusCode)
			}
			if strings.Contains(resp.Body, "tenant_id") {
				t.Errorf("body %q leaks internals; it should be a bare error message", resp.Body)
			}
		})
	}
}

// The tenant comes from the authorizer context only. Anything the client sends about
// tenancy — header, query string, body — is data, never identity.
func TestHandlerIgnoresClientSuppliedTenant(t *testing.T) {
	captureLogs(t)
	req := allowedRequest()
	req.Headers = map[string]string{
		"X-Tenant-Id":   "tenant-b",
		"Authorization": "Bearer some.jwt.value",
	}
	req.QueryStringParameters = map[string]string{"tenant": "tenant-b", "tenant_id": "tenant-b"}
	req.Body = `{"tenant_id":"tenant-b"}`
	req.PathParameters = map[string]string{"tenant_id": "tenant-b"}

	resp, err := handler(context.Background(), req)
	if err != nil {
		t.Fatalf("handler() error = %v", err)
	}
	if got := decodeBody(t, resp)["tenant_id"]; got != testTenant {
		t.Errorf("tenant_id = %q, want %q: client input must not override the authorizer", got, testTenant)
	}
}

func TestHandlerLogsTenantButNotTheToken(t *testing.T) {
	buf := captureLogs(t)
	req := allowedRequest()
	req.Headers = map[string]string{"Authorization": "Bearer header.payload.signature"}

	if _, err := handler(context.Background(), req); err != nil {
		t.Fatalf("handler() error = %v", err)
	}

	logs := buf.String()
	if !strings.Contains(logs, testTenant) {
		t.Errorf("logs should name the tenant, got:\n%s", logs)
	}
	for _, secret := range []string{"Bearer", "header.payload.signature", "Authorization"} {
		if strings.Contains(logs, secret) {
			t.Errorf("logs contain %q — the event carries a bearer token on every request:\n%s", secret, logs)
		}
	}
}
