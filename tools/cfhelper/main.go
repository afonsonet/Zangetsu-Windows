// cfhelper — a tiny loopback HTTP helper that makes web requests with a real
// Chrome TLS/HTTP2 fingerprint.
//
// Why it exists: some sites (Cloudflare "bot fight") reject a client based on its
// TLS handshake fingerprint before looking at a single header. Dart's HttpClient
// has a fingerprint no browser has, so it gets a 403 on those sites. The Android
// build gets around this with the platform's native HTTP stack; Windows has no
// equivalent, so the app starts this helper and sends its requests through it.
//
// It listens on 127.0.0.1 only, on a random port, and every call must carry the
// per-launch token the app passes in ZANGETSU_TOKEN. It exits when its stdin
// closes (i.e. when the app goes away).
//
// It is stateless apart from a cookie jar: the app owns clearance cookies and
// passes them in the Cookie header.
package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net"
	nethttp "net/http"
	"os"
	"sort"
	"strings"
	"time"
	"unicode/utf8"

	fhttp "github.com/bogdanfinn/fhttp"
	tlsclient "github.com/bogdanfinn/tls-client"
	"github.com/bogdanfinn/tls-client/profiles"
)

const (
	maxBodyBytes = 32 << 20 // cap on a response body we are willing to buffer
	defaultUA    = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
)

type requestIn struct {
	URL             string            `json:"url"`
	Method          string            `json:"method"`
	Headers         map[string]string `json:"headers"`
	Body            string            `json:"body"`
	BodyBase64      string            `json:"bodyBase64"`
	TimeoutMs       int               `json:"timeoutMs"`
	FollowRedirects *bool             `json:"followRedirects"`
}

type responseOut struct {
	Status     int               `json:"status"`
	Headers    map[string]string `json:"headers"`
	Body       string            `json:"body"`
	Base64     bool              `json:"base64"`
	URL        string            `json:"url"`
	Cloudflare bool              `json:"cloudflare"`
	Error      string            `json:"error,omitempty"`
}

// Chrome sends headers in a stable order; some fingerprinting looks at it.
var chromeHeaderOrder = []string{
	"cache-control", "sec-ch-ua", "sec-ch-ua-mobile", "sec-ch-ua-platform",
	"upgrade-insecure-requests", "user-agent", "accept", "origin", "content-type",
	"sec-fetch-site", "sec-fetch-mode", "sec-fetch-user", "sec-fetch-dest",
	"referer", "accept-language", "cookie",
}

// Headers the transport must own (it sets/decodes them itself).
var skipHeaders = map[string]bool{
	"host": true, "content-length": true, "accept-encoding": true,
	"connection": true, "transfer-encoding": true,
}

type helper struct {
	token     string
	following tlsclient.HttpClient
	direct    tlsclient.HttpClient
}

func newClient(jar tlsclient.CookieJar, follow bool) (tlsclient.HttpClient, error) {
	opts := []tlsclient.HttpClientOption{
		tlsclient.WithTimeoutSeconds(60),
		tlsclient.WithClientProfile(profiles.Chrome_120),
		tlsclient.WithCookieJar(jar),
	}
	if !follow {
		opts = append(opts, tlsclient.WithNotFollowRedirects())
	}
	return tlsclient.NewHttpClient(tlsclient.NewNoopLogger(), opts...)
}

func main() {
	port := flag.Int("port", 0, "port to listen on (0 = pick a free one)")
	flag.Parse()

	token := os.Getenv("ZANGETSU_TOKEN")
	if token == "" {
		fmt.Fprintln(os.Stderr, "cfhelper: ZANGETSU_TOKEN is not set")
		os.Exit(2)
	}

	jar := tlsclient.NewCookieJar()
	following, err := newClient(jar, true)
	if err != nil {
		fmt.Fprintln(os.Stderr, "cfhelper: client:", err)
		os.Exit(3)
	}
	direct, err := newClient(jar, false)
	if err != nil {
		fmt.Fprintln(os.Stderr, "cfhelper: client:", err)
		os.Exit(3)
	}
	h := &helper{token: token, following: following, direct: direct}

	ln, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", *port))
	if err != nil {
		fmt.Fprintln(os.Stderr, "cfhelper: listen:", err)
		os.Exit(4)
	}

	// The app reads this line to learn the port (no bind-then-close race).
	fmt.Printf("READY %d\n", ln.Addr().(*net.TCPAddr).Port)

	// Die with the app: stdin is a pipe the app holds open.
	go func() {
		_, _ = io.Copy(io.Discard, os.Stdin)
		os.Exit(0)
	}()

	mux := nethttp.NewServeMux()
	mux.HandleFunc("/health", h.guard(func(w nethttp.ResponseWriter, r *nethttp.Request) {
		_, _ = w.Write([]byte("ok"))
	}))
	mux.HandleFunc("/request", h.guard(h.handleRequest))
	srv := &nethttp.Server{Handler: mux, ReadHeaderTimeout: 10 * time.Second}
	_ = srv.Serve(ln)
}

// guard rejects anything that is not the app: wrong token, or a Host header that
// is not loopback (blocks DNS-rebinding from a web page in the user's browser).
func (h *helper) guard(next nethttp.HandlerFunc) nethttp.HandlerFunc {
	return func(w nethttp.ResponseWriter, r *nethttp.Request) {
		if !strings.HasPrefix(r.Host, "127.0.0.1:") {
			nethttp.Error(w, "bad host", nethttp.StatusForbidden)
			return
		}
		if r.Header.Get("X-Zangetsu-Token") != h.token {
			nethttp.Error(w, "forbidden", nethttp.StatusForbidden)
			return
		}
		next(w, r)
	}
}

func writeJSON(w nethttp.ResponseWriter, out responseOut) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(out)
}

func (h *helper) handleRequest(w nethttp.ResponseWriter, r *nethttp.Request) {
	if r.Method != nethttp.MethodPost {
		nethttp.Error(w, "POST only", nethttp.StatusMethodNotAllowed)
		return
	}
	var in requestIn
	if err := json.NewDecoder(io.LimitReader(r.Body, 16<<20)).Decode(&in); err != nil {
		writeJSON(w, responseOut{Error: "bad request: " + err.Error()})
		return
	}
	if !strings.HasPrefix(in.URL, "http://") && !strings.HasPrefix(in.URL, "https://") {
		writeJSON(w, responseOut{Error: "only http(s) urls are allowed"})
		return
	}
	out, err := h.do(in)
	if err != nil {
		writeJSON(w, responseOut{Error: err.Error()})
		return
	}
	writeJSON(w, out)
}

func (h *helper) do(in requestIn) (responseOut, error) {
	method := strings.ToUpper(in.Method)
	if method == "" {
		method = "GET"
	}

	var body io.Reader
	switch {
	case in.BodyBase64 != "":
		raw, err := base64.StdEncoding.DecodeString(in.BodyBase64)
		if err != nil {
			return responseOut{}, fmt.Errorf("bad bodyBase64: %w", err)
		}
		body = strings.NewReader(string(raw))
	case in.Body != "":
		body = strings.NewReader(in.Body)
	}

	timeout := 30 * time.Second
	if in.TimeoutMs > 0 {
		timeout = time.Duration(in.TimeoutMs) * time.Millisecond
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	req, err := fhttp.NewRequestWithContext(ctx, method, in.URL, body)
	if err != nil {
		return responseOut{}, err
	}

	// Normalise incoming headers to lower case, drop the ones the transport owns.
	given := map[string]string{}
	for k, v := range in.Headers {
		lk := strings.ToLower(strings.TrimSpace(k))
		if lk == "" || skipHeaders[lk] {
			continue
		}
		given[lk] = v
	}
	if _, ok := given["user-agent"]; !ok {
		given["user-agent"] = defaultUA
	}
	if _, ok := given["accept"]; !ok {
		given["accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8"
	}
	if _, ok := given["accept-language"]; !ok {
		given["accept-language"] = "en-US,en;q=0.9"
	}

	// Known headers first in Chrome's order, anything else after, alphabetical.
	var order []string
	seen := map[string]bool{}
	for _, k := range chromeHeaderOrder {
		if _, ok := given[k]; ok {
			order = append(order, k)
			seen[k] = true
		}
	}
	var rest []string
	for k := range given {
		if !seen[k] {
			rest = append(rest, k)
		}
	}
	sort.Strings(rest)
	order = append(order, rest...)

	hdr := fhttp.Header{}
	for _, k := range order {
		hdr[k] = []string{given[k]}
	}
	hdr[fhttp.HeaderOrderKey] = order
	hdr[fhttp.PHeaderOrderKey] = []string{":method", ":authority", ":scheme", ":path"}
	req.Header = hdr

	client := h.following
	if in.FollowRedirects != nil && !*in.FollowRedirects {
		client = h.direct
	}
	resp, err := client.Do(req)
	if err != nil {
		return responseOut{}, err
	}
	defer resp.Body.Close()

	raw, err := io.ReadAll(io.LimitReader(resp.Body, maxBodyBytes))
	if err != nil {
		return responseOut{}, err
	}

	out := responseOut{
		Status:  resp.StatusCode,
		Headers: map[string]string{},
		URL:     in.URL,
	}
	if resp.Request != nil && resp.Request.URL != nil {
		out.URL = resp.Request.URL.String()
	}
	for k, vs := range resp.Header {
		out.Headers[strings.ToLower(k)] = strings.Join(vs, ", ")
	}
	if utf8.Valid(raw) {
		out.Body = string(raw)
	} else {
		out.Body = base64.StdEncoding.EncodeToString(raw)
		out.Base64 = true
	}
	out.Cloudflare = looksLikeChallenge(resp.StatusCode, out.Headers, raw)
	return out, nil
}

// looksLikeChallenge is true only for an interactive Cloudflare challenge — the
// kind a person can pass in a browser. A plain 403 from a site that merely sits
// behind Cloudflare, or an error-1020 "access denied" block, is NOT a challenge
// and solving it would never help, so those return false.
func looksLikeChallenge(status int, headers map[string]string, body []byte) bool {
	if strings.Contains(strings.ToLower(headers["cf-mitigated"]), "challenge") {
		return true
	}
	isCF := strings.Contains(strings.ToLower(headers["server"]), "cloudflare")
	n := min(len(body), 30000)
	b := strings.ToLower(string(body[:n]))
	// Some sites serve the interstitial with a 200; its <title> gives it away.
	if isCF && (strings.Contains(b, "<title>just a moment") ||
		strings.Contains(b, "<title>attention required")) {
		return true
	}
	if status != 403 && status != 429 && status != 503 {
		return false
	}
	if !isCF {
		return false
	}
	return strings.Contains(b, "just a moment") ||
		strings.Contains(b, "cf-chl") ||
		strings.Contains(b, "challenge-platform")
}
