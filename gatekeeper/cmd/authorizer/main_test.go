package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"errors"
	"log/slog"
	"strings"
	"testing"
	"time"

	"github.com/aws/aws-lambda-go/events"
	"github.com/golang-jwt/jwt/v5"
)

const (
	testKID       = "test-key-1"
	testIssuer    = "https://tenant.example.auth0.com/"
	testAudience  = "https://gatekeeper/api"
	testSub       = "client123@clients"
	testMethodArn = "arn:aws:execute-api:us-east-1:123456789012:abc123/dev/GET/hello"
	testResource  = "arn:aws:execute-api:us-east-1:123456789012:abc123/dev/*/*"
)

var (
	signingKey = mustRSAKey()
	otherKey   = mustRSAKey()
)

func mustRSAKey() *rsa.PrivateKey {
	k, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		panic(err)
	}
	return k
}

// testKeyfunc stands in for keyfunc/v3: resolve the token's kid to a public key.
func testKeyfunc(t *jwt.Token) (any, error) {
	if kid, _ := t.Header["kid"].(string); kid != testKID {
		return nil, errors.New("unknown kid")
	}
	return &signingKey.PublicKey, nil
}

func validClaims() jwt.MapClaims {
	now := time.Now()
	// Mirrors a real token from the tenant: the add-tenant-id Action always adds
	// the tenant claim, so a token without one is the exception, not the baseline.
	return jwt.MapClaims{
		"iss":       testIssuer,
		"aud":       testAudience,
		"sub":       testSub,
		"iat":       now.Unix(),
		"exp":       now.Add(time.Hour).Unix(),
		tenantClaim: testTenant,
		"scope":     testScope,
	}
}

// claimsWith returns valid claims with overrides applied and the dropped keys removed.
func claimsWith(overrides map[string]any, drop ...string) jwt.MapClaims {
	c := validClaims()
	for k, v := range overrides {
		c[k] = v
	}
	for _, k := range drop {
		delete(c, k)
	}
	return c
}

func signRS256(t *testing.T, key *rsa.PrivateKey, kid string, claims jwt.MapClaims) string {
	t.Helper()
	tok := jwt.NewWithClaims(jwt.SigningMethodRS256, claims)
	if kid != "" {
		tok.Header["kid"] = kid
	}
	s, err := tok.SignedString(key)
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func publicKeyDER(t *testing.T) []byte {
	t.Helper()
	der, err := x509.MarshalPKIXPublicKey(&signingKey.PublicKey)
	if err != nil {
		t.Fatal(err)
	}
	return der
}

// signHS256WithPublicKey builds the classic key-confusion forgery: HMAC-signed
// using the RSA public key's bytes as the secret.
func signHS256WithPublicKey(t *testing.T) string {
	t.Helper()
	tok := jwt.NewWithClaims(jwt.SigningMethodHS256, validClaims())
	tok.Header["kid"] = testKID
	s, err := tok.SignedString(publicKeyDER(t))
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func signNone(t *testing.T) string {
	t.Helper()
	tok := jwt.NewWithClaims(jwt.SigningMethodNone, validClaims())
	tok.Header["kid"] = testKID
	s, err := tok.SignedString(jwt.UnsafeAllowNoneSignatureType)
	if err != nil {
		t.Fatal(err)
	}
	return s
}

// flipSignatureChar changes the first character of the signature segment. The last
// character is avoided on purpose: for a 2048-bit key it carries unused bits, so
// changing it can decode to the same signature bytes.
func flipSignatureChar(tok string) string {
	parts := strings.Split(tok, ".")
	sig := []byte(parts[2])
	if sig[0] == 'A' {
		sig[0] = 'B'
	} else {
		sig[0] = 'A'
	}
	parts[2] = string(sig)
	return strings.Join(parts, ".")
}

// tamperPayload swaps the subject but keeps the original header and signature.
func tamperPayload(t *testing.T, tok string) string {
	t.Helper()
	parts := strings.Split(tok, ".")
	raw, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		t.Fatal(err)
	}
	var claims map[string]any
	if err := json.Unmarshal(raw, &claims); err != nil {
		t.Fatal(err)
	}
	claims["sub"] = "attacker@clients"
	raw, err = json.Marshal(claims)
	if err != nil {
		t.Fatal(err)
	}
	parts[1] = base64.RawURLEncoding.EncodeToString(raw)
	return strings.Join(parts, ".")
}

func TestBearerToken(t *testing.T) {
	tests := []struct {
		name    string
		headers map[string]string
		want    string
		wantOK  bool
	}{
		{"standard", map[string]string{"Authorization": "Bearer abc"}, "abc", true},
		{"lowercase scheme", map[string]string{"Authorization": "bearer abc"}, "abc", true},
		{"uppercase scheme", map[string]string{"Authorization": "BEARER abc"}, "abc", true},
		{"lowercase header name", map[string]string{"authorization": "Bearer abc"}, "abc", true},
		{"uppercase header name", map[string]string{"AUTHORIZATION": "Bearer abc"}, "abc", true},
		{"surrounding and extra spaces", map[string]string{"Authorization": "  Bearer   abc  "}, "abc", true},
		{"wrong scheme", map[string]string{"Authorization": "Basic abc"}, "", false},
		{"scheme only", map[string]string{"Authorization": "Bearer"}, "", false},
		{"scheme and trailing space", map[string]string{"Authorization": "Bearer "}, "", false},
		{"scheme and many spaces", map[string]string{"Authorization": "Bearer     "}, "", false},
		{"no scheme", map[string]string{"Authorization": "abc"}, "", false},
		{"empty value", map[string]string{"Authorization": ""}, "", false},
		{"other headers only", map[string]string{"Content-Type": "application/json"}, "", false},
		{"empty map", map[string]string{}, "", false},
		{"nil map", nil, "", false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, ok := bearerToken(tt.headers)
			if got != tt.want || ok != tt.wantOK {
				t.Errorf("bearerToken() = (%q, %v), want (%q, %v)", got, ok, tt.want, tt.wantOK)
			}
		})
	}
}

func TestWildcardResource(t *testing.T) {
	tests := []struct {
		name    string
		arn     string
		want    string
		wantErr bool
	}{
		{"GET route", testMethodArn, testResource, false},
		{"POST nested route", "arn:aws:execute-api:us-east-1:123456789012:abc123/dev/POST/items/42", testResource, false},
		{"other stage", "arn:aws:execute-api:us-east-1:123456789012:abc123/prod/GET/hello", "arn:aws:execute-api:us-east-1:123456789012:abc123/prod/*/*", false},
		{"stage only", "arn:aws:execute-api:us-east-1:123456789012:abc123/dev", "arn:aws:execute-api:us-east-1:123456789012:abc123/dev/*/*", false},
		{"empty", "", "", true},
		{"no slash", "arn:aws:execute-api:us-east-1:123456789012:abc123", "", true},
		{"empty api part", "/dev/GET/hello", "", true},
		{"empty stage", "arn:aws:execute-api:us-east-1:123456789012:abc123//GET/hello", "", true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := wildcardResource(tt.arn)
			if (err != nil) != tt.wantErr {
				t.Fatalf("wildcardResource() error = %v, wantErr %v", err, tt.wantErr)
			}
			if got != tt.want {
				t.Errorf("wildcardResource() = %q, want %q", got, tt.want)
			}
		})
	}
}

func TestPolicy(t *testing.T) {
	for _, effect := range []string{"Allow", "Deny"} {
		t.Run(effect, func(t *testing.T) {
			resp := policy("someone", effect, testResource)
			if resp.PrincipalID != "someone" {
				t.Errorf("PrincipalID = %q, want %q", resp.PrincipalID, "someone")
			}
			doc := resp.PolicyDocument
			if doc.Version != "2012-10-17" {
				t.Errorf("Version = %q, want 2012-10-17", doc.Version)
			}
			if len(doc.Statement) != 1 {
				t.Fatalf("got %d statements, want 1", len(doc.Statement))
			}
			s := doc.Statement[0]
			if s.Effect != effect {
				t.Errorf("Effect = %q, want %q", s.Effect, effect)
			}
			if len(s.Action) != 1 || s.Action[0] != "execute-api:Invoke" {
				t.Errorf("Action = %v, want [execute-api:Invoke]", s.Action)
			}
			if len(s.Resource) != 1 || s.Resource[0] != testResource {
				t.Errorf("Resource = %v, want [%s]", s.Resource, testResource)
			}
		})
	}
}

func TestVerifyToken(t *testing.T) {
	tests := []struct {
		name    string
		token   func(t *testing.T) string
		wantErr error
	}{
		{
			name:  "valid",
			token: func(t *testing.T) string { return signRS256(t, signingKey, testKID, validClaims()) },
		},
		{
			name: "audience as array containing ours",
			token: func(t *testing.T) string {
				c := claimsWith(map[string]any{"aud": []string{"https://other/api", testAudience}})
				return signRS256(t, signingKey, testKID, c)
			},
		},
		{
			name: "expired",
			token: func(t *testing.T) string {
				c := claimsWith(map[string]any{"exp": time.Now().Add(-time.Hour).Unix()})
				return signRS256(t, signingKey, testKID, c)
			},
			wantErr: jwt.ErrTokenExpired,
		},
		{
			name: "no exp claim",
			token: func(t *testing.T) string {
				return signRS256(t, signingKey, testKID, claimsWith(nil, "exp"))
			},
			wantErr: jwt.ErrTokenRequiredClaimMissing,
		},
		{
			name: "not valid yet",
			token: func(t *testing.T) string {
				c := claimsWith(map[string]any{"nbf": time.Now().Add(time.Hour).Unix()})
				return signRS256(t, signingKey, testKID, c)
			},
			wantErr: jwt.ErrTokenNotValidYet,
		},
		{
			name: "issuer without trailing slash",
			token: func(t *testing.T) string {
				c := claimsWith(map[string]any{"iss": strings.TrimSuffix(testIssuer, "/")})
				return signRS256(t, signingKey, testKID, c)
			},
			wantErr: jwt.ErrTokenInvalidIssuer,
		},
		{
			name: "issuer from another tenant",
			token: func(t *testing.T) string {
				c := claimsWith(map[string]any{"iss": "https://evil.example.auth0.com/"})
				return signRS256(t, signingKey, testKID, c)
			},
			wantErr: jwt.ErrTokenInvalidIssuer,
		},
		{
			name: "audience for another API",
			token: func(t *testing.T) string {
				c := claimsWith(map[string]any{"aud": "https://other/api"})
				return signRS256(t, signingKey, testKID, c)
			},
			wantErr: jwt.ErrTokenInvalidAudience,
		},
		{
			name: "no aud claim",
			token: func(t *testing.T) string {
				return signRS256(t, signingKey, testKID, claimsWith(nil, "aud"))
			},
			wantErr: jwt.ErrTokenRequiredClaimMissing,
		},
		{
			name:    "signed by a different key",
			token:   func(t *testing.T) string { return signRS256(t, otherKey, testKID, validClaims()) },
			wantErr: jwt.ErrTokenSignatureInvalid,
		},
		{
			name: "tampered signature",
			token: func(t *testing.T) string {
				return flipSignatureChar(signRS256(t, signingKey, testKID, validClaims()))
			},
			wantErr: jwt.ErrTokenSignatureInvalid,
		},
		{
			name: "tampered payload",
			token: func(t *testing.T) string {
				return tamperPayload(t, signRS256(t, signingKey, testKID, validClaims()))
			},
			wantErr: jwt.ErrTokenSignatureInvalid,
		},
		{
			name:    "unknown kid",
			token:   func(t *testing.T) string { return signRS256(t, signingKey, "rotated-away", validClaims()) },
			wantErr: jwt.ErrTokenUnverifiable,
		},
		{
			name:    "no kid",
			token:   func(t *testing.T) string { return signRS256(t, signingKey, "", validClaims()) },
			wantErr: jwt.ErrTokenUnverifiable,
		},
		{
			name:    "HS256 signed with the public key",
			token:   signHS256WithPublicKey,
			wantErr: jwt.ErrTokenSignatureInvalid,
		},
		{
			name:    "alg none",
			token:   signNone,
			wantErr: jwt.ErrTokenSignatureInvalid,
		},
		{
			name:    "not a JWT",
			token:   func(*testing.T) string { return "not.a.jwt" },
			wantErr: jwt.ErrTokenMalformed,
		},
		{
			name:    "one segment",
			token:   func(*testing.T) string { return "garbage" },
			wantErr: jwt.ErrTokenMalformed,
		},
		{
			name:    "empty",
			token:   func(*testing.T) string { return "" },
			wantErr: jwt.ErrTokenMalformed,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			token, err := verifyToken(tt.token(t), testKeyfunc, testIssuer, testAudience)
			if tt.wantErr == nil {
				if err != nil {
					t.Fatalf("verifyToken() unexpected error: %v", err)
				}
				if sub, _ := token.Claims.GetSubject(); sub != testSub {
					t.Errorf("subject = %q, want %q", sub, testSub)
				}
				return
			}
			if !errors.Is(err, tt.wantErr) {
				t.Errorf("verifyToken() error = %v, want %v", err, tt.wantErr)
			}
		})
	}
}

// With a naive keyfunc that returns the same key bytes whatever the token's alg,
// the forged HS256 token verifies. Only the pin stops it.
func TestAlgorithmPinBlocksKeyConfusion(t *testing.T) {
	pub := publicKeyDER(t)
	naiveKeyfunc := func(*jwt.Token) (any, error) { return pub, nil }
	forged := signHS256WithPublicKey(t)

	if _, err := jwt.Parse(forged, naiveKeyfunc); err != nil {
		t.Fatalf("precondition: an unpinned parser should accept the forged token, got: %v", err)
	}
	if _, err := verifyToken(forged, naiveKeyfunc, testIssuer, testAudience); !errors.Is(err, jwt.ErrTokenSignatureInvalid) {
		t.Errorf("verifyToken() error = %v, want %v", err, jwt.ErrTokenSignatureInvalid)
	}
}

// With the real key type, golang-jwt refuses HMAC verification on its own,
// so the pin is a second layer here, not the only one.
func TestHS256FailsEvenWithoutPinWhenKeyIsRSA(t *testing.T) {
	_, err := jwt.Parse(signHS256WithPublicKey(t), testKeyfunc)
	if !errors.Is(err, jwt.ErrInvalidKeyType) {
		t.Errorf("unpinned parse error = %v, want %v", err, jwt.ErrInvalidKeyType)
	}
}

// setupHandler points the package-level config at the test key and captures logs.
func setupHandler(t *testing.T) *bytes.Buffer {
	t.Helper()
	oldKeyFunc, oldIssuer, oldAudience, oldLogger := keyFunc, issuer, audience, logger
	buf := &bytes.Buffer{}
	keyFunc, issuer, audience = testKeyfunc, testIssuer, testAudience
	logger = slog.New(slog.NewJSONHandler(buf, nil))
	t.Cleanup(func() { keyFunc, issuer, audience, logger = oldKeyFunc, oldIssuer, oldAudience, oldLogger })
	return buf
}

func request(headers map[string]string) events.APIGatewayCustomAuthorizerRequestTypeRequest {
	return events.APIGatewayCustomAuthorizerRequestTypeRequest{
		MethodArn: testMethodArn,
		Headers:   headers,
	}
}

func bearer(token string) map[string]string {
	return map[string]string{"Authorization": "Bearer " + token}
}

func assertPolicy(t *testing.T, resp events.APIGatewayCustomAuthorizerResponse, principal, effect string) {
	t.Helper()
	if resp.PrincipalID != principal {
		t.Errorf("PrincipalID = %q, want %q", resp.PrincipalID, principal)
	}
	if len(resp.PolicyDocument.Statement) != 1 {
		t.Fatalf("got %d statements, want 1", len(resp.PolicyDocument.Statement))
	}
	s := resp.PolicyDocument.Statement[0]
	if s.Effect != effect {
		t.Errorf("Effect = %q, want %q", s.Effect, effect)
	}
	if len(s.Resource) != 1 || s.Resource[0] != testResource {
		t.Errorf("Resource = %v, want [%s]: a cached decision must cover every route, not just this one", s.Resource, testResource)
	}
}

func TestHandlerAllowsValidToken(t *testing.T) {
	setupHandler(t)
	tok := signRS256(t, signingKey, testKID, validClaims())

	resp, err := handler(context.Background(), request(bearer(tok)))
	if err != nil {
		t.Fatalf("handler() error = %v", err)
	}
	assertPolicy(t, resp, testSub, "Allow")
}

const (
	testTenant = "tenant-a"
	testScope  = "read:items write:items"
)

func TestHandlerPassesTenantToBackend(t *testing.T) {
	setupHandler(t)
	tok := signRS256(t, signingKey, testKID, claimsWith(map[string]any{
		tenantClaim: testTenant,
		"scope":     testScope,
	}))

	resp, err := handler(context.Background(), request(bearer(tok)))
	if err != nil {
		t.Fatalf("handler() error = %v", err)
	}
	assertPolicy(t, resp, testSub, "Allow")

	want := map[string]any{"tenant_id": testTenant, "sub": testSub, "scope": testScope}
	for k, v := range want {
		if got := resp.Context[k]; got != v {
			t.Errorf("context[%q] = %v, want %v", k, got, v)
		}
	}
	// API Gateway only accepts strings, numbers and booleans here — and the raw
	// token must never travel to the backend's own log group.
	for k, v := range resp.Context {
		switch v.(type) {
		case string, int, int64, float64, bool:
		default:
			t.Errorf("context[%q] is %T; must be string, number or bool", k, v)
		}
		if s, ok := v.(string); ok && strings.Count(s, ".") == 2 && len(s) > 100 {
			t.Errorf("context[%q] looks like a JWT", k)
		}
	}
}

// A genuine, unexpired token for this API — but with no usable tenant. The Action
// shouldn't issue one, yet the authorizer can't assume the Action ran.
func TestHandlerDeniesTokenWithoutUsableTenant(t *testing.T) {
	tests := map[string]jwt.MapClaims{
		"claim absent":      claimsWith(nil, tenantClaim),
		"empty string":      claimsWith(map[string]any{tenantClaim: ""}),
		"whitespace only":   claimsWith(map[string]any{tenantClaim: "   "}),
		"number":            claimsWith(map[string]any{tenantClaim: 42}),
		"boolean":           claimsWith(map[string]any{tenantClaim: true}),
		"null":              claimsWith(map[string]any{tenantClaim: nil}),
		"array":             claimsWith(map[string]any{tenantClaim: []string{"tenant-a"}}),
		"object":            claimsWith(map[string]any{tenantClaim: map[string]any{"id": "tenant-a"}}),
		"unnamespaced only": claimsWith(map[string]any{"tenant_id": testTenant}, tenantClaim),
	}
	for name, claims := range tests {
		t.Run(name, func(t *testing.T) {
			setupHandler(t)

			resp, err := handler(context.Background(), request(bearer(signRS256(t, signingKey, testKID, claims))))
			if err != nil {
				t.Fatalf("handler() error = %v, want a Deny policy and no error (403)", err)
			}
			assertPolicy(t, resp, "anonymous", "Deny")
			if len(resp.Context) != 0 {
				t.Errorf("Context = %v, want empty: a denied request must carry nothing to the backend", resp.Context)
			}
		})
	}
}

func TestHandlerAcceptsLowercaseHeaderName(t *testing.T) {
	setupHandler(t)
	tok := signRS256(t, signingKey, testKID, validClaims())

	resp, err := handler(context.Background(), request(map[string]string{"authorization": "Bearer " + tok}))
	if err != nil {
		t.Fatalf("handler() error = %v", err)
	}
	assertPolicy(t, resp, testSub, "Allow")
}

func TestHandlerDeniesBadTokens(t *testing.T) {
	tests := map[string]func(t *testing.T) string{
		"expired": func(t *testing.T) string {
			return signRS256(t, signingKey, testKID, claimsWith(map[string]any{"exp": time.Now().Add(-time.Minute).Unix()}))
		},
		"wrong audience": func(t *testing.T) string {
			return signRS256(t, signingKey, testKID, claimsWith(map[string]any{"aud": "https://other/api"}))
		},
		"wrong issuer": func(t *testing.T) string {
			return signRS256(t, signingKey, testKID, claimsWith(map[string]any{"iss": "https://evil.example.auth0.com/"}))
		},
		"tampered signature": func(t *testing.T) string {
			return flipSignatureChar(signRS256(t, signingKey, testKID, validClaims()))
		},
		"HS256 forgery": signHS256WithPublicKey,
		"alg none":      signNone,
		"garbage":       func(*testing.T) string { return "anything" },
	}
	for name, mint := range tests {
		t.Run(name, func(t *testing.T) {
			setupHandler(t)

			resp, err := handler(context.Background(), request(bearer(mint(t))))
			if err != nil {
				t.Fatalf("handler() error = %v, want a Deny policy and no error (403, not 401 or 500)", err)
			}
			assertPolicy(t, resp, "anonymous", "Deny")
		})
	}
}

func TestHandlerReturnsUnauthorizedForBadHeader(t *testing.T) {
	tests := map[string]map[string]string{
		"no header":     {},
		"nil headers":   nil,
		"wrong scheme":  {"Authorization": "Basic abc"},
		"no token":      {"Authorization": "Bearer"},
		"blank token":   {"Authorization": "Bearer    "},
		"no scheme":     {"Authorization": "abc"},
		"empty header":  {"Authorization": ""},
		"other headers": {"Content-Type": "application/json"},
	}
	for name, headers := range tests {
		t.Run(name, func(t *testing.T) {
			setupHandler(t)

			_, err := handler(context.Background(), request(headers))
			if !errors.Is(err, errUnauthorized) {
				t.Fatalf("handler() error = %v, want errUnauthorized (401)", err)
			}
			if err.Error() != "Unauthorized" {
				t.Errorf("error text = %q; API Gateway only maps the exact string %q to 401", err.Error(), "Unauthorized")
			}
		})
	}
}

func TestHandlerFailsOnBadMethodArn(t *testing.T) {
	setupHandler(t)
	req := request(bearer(signRS256(t, signingKey, testKID, validClaims())))
	req.MethodArn = "garbage"

	_, err := handler(context.Background(), req)
	if err == nil {
		t.Fatal("handler() returned no error for a malformed method ARN")
	}
	if errors.Is(err, errUnauthorized) {
		t.Error("a malformed method ARN is our fault (500), not the caller's (401)")
	}
}

func TestHandlerNeverLogsTheToken(t *testing.T) {
	buf := setupHandler(t)
	valid := signRS256(t, signingKey, testKID, validClaims())
	tokens := []string{
		valid,
		flipSignatureChar(valid),
		signRS256(t, signingKey, testKID, claimsWith(map[string]any{"exp": time.Now().Add(-time.Minute).Unix()})),
		signHS256WithPublicKey(t),
	}

	for _, tok := range tokens {
		if _, err := handler(context.Background(), request(bearer(tok))); err != nil {
			t.Fatalf("handler() error = %v", err)
		}
	}
	_, _ = handler(context.Background(), request(map[string]string{"Authorization": "Basic secret-credentials"}))

	logs := buf.String()
	if !strings.Contains(logs, `"msg":"allow"`) || !strings.Contains(logs, `"msg":"deny"`) || !strings.Contains(logs, `"msg":"reject"`) {
		t.Fatalf("expected allow, deny and reject log lines, got:\n%s", logs)
	}
	for _, tok := range tokens {
		parts := strings.Split(tok, ".")
		for _, part := range parts {
			if strings.Contains(logs, part) {
				t.Fatalf("logs contain part of a token (%.20s…):\n%s", part, logs)
			}
		}
	}
	if strings.Contains(logs, "secret-credentials") {
		t.Errorf("logs contain the Authorization header value:\n%s", logs)
	}
}
