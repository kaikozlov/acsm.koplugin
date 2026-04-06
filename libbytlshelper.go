package main

import (
	"bytes"
	"compress/gzip"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/url"
	"os"
	"strings"
	"time"

	http "github.com/bogdanfinn/fhttp"
	tls_client "github.com/bogdanfinn/tls-client"
	"github.com/bogdanfinn/tls-client/profiles"
)

const (
	apiBase   = "https://sentry.libbyapp.com/"
	userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36"
	secChUA   = `"Chromium";v="146", "Not-A.Brand";v="24", "Brave";v="146"`
)

type helperClient struct {
	http tls_client.HttpClient
}

type helperResult struct {
	Success bool `json:"success"`

	InitialChipPayload map[string]any `json:"initial_chip_payload,omitempty"`
	RetryChipPayload   map[string]any `json:"retry_chip_payload,omitempty"`

	CodeResult     map[string]any `json:"code_result,omitempty"`
	RedeemResult   map[string]any `json:"redeem_result,omitempty"`
	BlessingResult map[string]any `json:"blessing_result,omitempty"`
	CloneResult    map[string]any `json:"clone_result,omitempty"`
	SyncResult     map[string]any `json:"sync_result,omitempty"`
	FulfillResult  map[string]any `json:"fulfill_result,omitempty"`

	FailureStep string         `json:"failure_step,omitempty"`
	FailureBody map[string]any `json:"failure_body,omitempty"`
	FailureErr  string         `json:"failure_err,omitempty"`
}

func newChromeClient() (*helperClient, error) {
	jar := tls_client.NewCookieJar()
	client, err := tls_client.NewHttpClient(
		tls_client.NewNoopLogger(),
		tls_client.WithTimeoutSeconds(30),
		tls_client.WithNotFollowRedirects(),
		tls_client.WithForceHttp1(),
		tls_client.WithDisableHttp3(),
		tls_client.WithClientProfile(profiles.Chrome_146),
		tls_client.WithRandomTLSExtensionOrder(),
		tls_client.WithCookieJar(jar),
	)
	if err != nil {
		return nil, err
	}
	return &helperClient{http: client}, nil
}

func buildHeaders(acceptLanguage, token string, jsonBody bool) http.Header {
	headers := http.Header{}
	headers.Set("Accept", "application/json")
	headers.Set("Accept-Encoding", "gzip, deflate, br, zstd")
	headers.Set("Accept-Language", acceptLanguage)
	headers.Set("Connection", "keep-alive")
	headers.Set("Origin", "https://libbyapp.com")
	headers.Set("Sec-Fetch-Dest", "empty")
	headers.Set("Sec-Fetch-Mode", "cors")
	headers.Set("Sec-Fetch-Site", "same-site")
	headers.Set("Sec-GPC", "1")
	headers.Set("User-Agent", userAgent)
	headers.Set("sec-ch-ua", secChUA)
	headers.Set("sec-ch-ua-mobile", "?0")
	headers.Set("sec-ch-ua-platform", `"macOS"`)
	if token != "" {
		headers.Set("Authorization", "Bearer "+token)
	}
	if jsonBody {
		headers.Set("Content-Type", "application/json")
	}
	order := []string{
		"Accept",
		"Accept-Encoding",
		"Accept-Language",
	}
	if token != "" {
		order = append(order, "Authorization")
	}
	if jsonBody {
		order = append(order, "Content-Type")
	}
	order = append(order,
		"Connection",
		"Origin",
		"Sec-Fetch-Dest",
		"Sec-Fetch-Mode",
		"Sec-Fetch-Site",
		"Sec-GPC",
		"User-Agent",
		"sec-ch-ua",
		"sec-ch-ua-mobile",
		"sec-ch-ua-platform",
	)
	headers[http.HeaderOrderKey] = order
	return headers
}

func decodeBody(resp *http.Response) ([]byte, error) {
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	switch strings.ToLower(resp.Header.Get("Content-Encoding")) {
	case "", "identity":
		return body, nil
	case "gzip":
		reader, err := gzip.NewReader(bytes.NewReader(body))
		if err != nil {
			return nil, err
		}
		defer reader.Close()
		return io.ReadAll(reader)
	default:
		return nil, fmt.Errorf("unsupported content-encoding %q", resp.Header.Get("Content-Encoding"))
	}
}

func (c *helperClient) do(ctx context.Context, method, endpoint string, query url.Values, headers http.Header, body any) (int, map[string]any, error) {
	requestURL := apiBase + endpoint
	if len(query) > 0 {
		requestURL += "?" + query.Encode()
	}

	var bodyReader io.Reader
	if body != nil {
		encoded, err := json.Marshal(body)
		if err != nil {
			return 0, nil, err
		}
		bodyReader = bytes.NewReader(encoded)
	}

	req, err := http.NewRequestWithContext(ctx, method, requestURL, bodyReader)
	if err != nil {
		return 0, nil, err
	}
	for key, values := range headers {
		for _, value := range values {
			req.Header.Add(key, value)
		}
	}
	if body == nil && method == http.MethodPost {
		req.ContentLength = 0
	}
	req.Close = false

	resp, err := c.http.Do(req)
	if err != nil {
		return 0, nil, err
	}
	decodedBody, err := decodeBody(resp)
	if err != nil {
		return resp.StatusCode, nil, err
	}
	var parsed map[string]any
	if len(decodedBody) > 0 {
		if err := json.Unmarshal(decodedBody, &parsed); err != nil {
			return resp.StatusCode, nil, fmt.Errorf("decode response: %w: %s", err, string(decodedBody))
		}
	}
	return resp.StatusCode, parsed, nil
}

func decodeJWTPayload(token string) (map[string]any, error) {
	parts := strings.Split(token, ".")
	if len(parts) < 2 {
		return nil, errors.New("invalid jwt")
	}
	segment := parts[1]
	if pad := len(segment) % 4; pad != 0 {
		segment += strings.Repeat("=", 4-pad)
	}
	decoded, err := base64.URLEncoding.DecodeString(segment)
	if err != nil {
		return nil, err
	}
	var payload map[string]any
	if err := json.Unmarshal(decoded, &payload); err != nil {
		return nil, err
	}
	return payload, nil
}

func chipPayload(token string) map[string]any {
	payload, err := decodeJWTPayload(token)
	if err != nil {
		return nil
	}
	chip, _ := payload["chip"].(map[string]any)
	return chip
}

func chipVersion(chipID string) string {
	if index := strings.IndexByte(chipID, '-'); index > 0 {
		return chipID[:index]
	}
	if len(chipID) > 8 {
		return chipID[:8]
	}
	return chipID
}

func fail(step string, body map[string]any, err error) {
	result := helperResult{
		Success:     false,
		FailureStep: step,
		FailureBody: body,
	}
	if err != nil {
		result.FailureErr = err.Error()
	}
	_ = json.NewEncoder(os.Stdout).Encode(result)
	os.Exit(1)
}

func main() {
	sourceToken := os.Getenv("LIBBY_SOURCE_TOKEN")
	if sourceToken == "" {
		fmt.Fprintln(os.Stderr, "LIBBY_SOURCE_TOKEN is required")
		os.Exit(2)
	}

	cardID := os.Getenv("LIBBY_CARD_ID")
	if cardID == "" {
		cardID = "85287774"
	}
	loanID := os.Getenv("LIBBY_LOAN_ID")
	if loanID == "" {
		loanID = "1009122"
	}

	ctx := context.Background()
	sourceClient, err := newChromeClient()
	if err != nil {
		fail("source_client_init", nil, err)
	}
	targetClient, err := newChromeClient()
	if err != nil {
		fail("target_client_init", nil, err)
	}
	result := helperResult{}

	initialStatus, initialChip, err := targetClient.do(ctx, http.MethodPost, "chip", url.Values{
		"c": {"d:21.1.2"},
		"s": {"0"},
	}, buildHeaders("bh", "", false), nil)
	if err != nil || initialStatus != 200 {
		fail("target_initial_chip", initialChip, err)
	}
	targetToken, _ := initialChip["identity"].(string)
	targetChipID, _ := initialChip["chip"].(string)
	result.InitialChipPayload = chipPayload(targetToken)

	codeStatus, codeResult, err := targetClient.do(ctx, http.MethodGet, "chip/clone/code", url.Values{
		"role": {"pointer"},
	}, buildHeaders("en-US", targetToken, false), nil)
	if err != nil || codeStatus != 200 {
		fail("target_generate_code", codeResult, err)
	}
	result.CodeResult = codeResult
	code, _ := codeResult["code"].(string)

	redeemStatus, redeemResult, err := sourceClient.do(ctx, http.MethodPost, "chip/clone/code", nil, buildHeaders("en-US", sourceToken, true), map[string]any{
		"code": code,
		"role": "primary",
	})
	if err != nil || redeemStatus != 200 {
		fail("source_redeem_code", redeemResult, err)
	}
	result.RedeemResult = redeemResult

	var blessing string
	for range 20 {
		pollStatus, blessingResult, pollErr := targetClient.do(ctx, http.MethodGet, "chip/clone/code", url.Values{
			"code": {code},
			"role": {"pointer"},
		}, buildHeaders("en-US", targetToken, false), nil)
		if pollErr != nil {
			fail("target_poll_blessing", blessingResult, pollErr)
		}
		if pollStatus != 200 {
			fail("target_poll_blessing", blessingResult, fmt.Errorf("unexpected status %d", pollStatus))
		}
		result.BlessingResult = blessingResult
		if value, _ := blessingResult["blessing"].(string); value != "" {
			blessing = value
			break
		}
		time.Sleep(500 * time.Millisecond)
	}
	if blessing == "" {
		fail("target_poll_blessing", result.BlessingResult, errors.New("blessing not fulfilled"))
	}

	cloneStatus, cloneResult, err := targetClient.do(ctx, http.MethodPost, "chip/clone", nil, buildHeaders("en-US", targetToken, true), map[string]any{
		"blessing": blessing,
	})
	if err != nil {
		fail("target_clone_initial", cloneResult, err)
	}

	if cloneStatus == 403 {
		retryStatus, retryChip, retryErr := targetClient.do(ctx, http.MethodPost, "chip", url.Values{
			"c": {"d:21.1.2"},
			"s": {"0"},
			"v": {chipVersion(targetChipID)},
		}, buildHeaders("ag", targetToken, false), nil)
		if retryErr != nil || retryStatus != 200 {
			fail("target_retry_chip", retryChip, retryErr)
		}
		targetToken, _ = retryChip["identity"].(string)
		result.RetryChipPayload = chipPayload(targetToken)

		cloneStatus, cloneResult, err = targetClient.do(ctx, http.MethodPost, "chip/clone", nil, buildHeaders("en-US", targetToken, true), map[string]any{
			"blessing": blessing,
		})
		if err != nil {
			fail("target_clone_retry", cloneResult, err)
		}
	}

	if cloneStatus != 200 {
		fail("target_clone", cloneResult, fmt.Errorf("unexpected status %d", cloneStatus))
	}
	result.CloneResult = cloneResult

	syncStatus, syncResult, err := targetClient.do(ctx, http.MethodGet, "chip/sync", nil, buildHeaders("en-US", targetToken, false), nil)
	if err != nil || syncStatus != 200 {
		fail("target_sync", syncResult, err)
	}
	result.SyncResult = syncResult

	fulfillStatus, fulfillResult, err := targetClient.do(ctx, http.MethodGet, fmt.Sprintf("card/%s/loan/%s/fulfill/ebook-epub-adobe", cardID, loanID), nil, buildHeaders("en-US", targetToken, false), nil)
	if err != nil || fulfillStatus != 200 {
		fail("target_fulfill", fulfillResult, err)
	}
	result.FulfillResult = fulfillResult
	result.Success = true

	encoder := json.NewEncoder(os.Stdout)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(result); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
