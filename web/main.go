// Command cx-web serves cx live: one page that watches and steers every cx
// session, and the JSON routes behind it. See docs/WEB.md.
//
// It is started by `cx web`, which finds or builds this binary and passes it
// where cx, the page and the token are. Everything it knows comes from
// running the cx CLI. It holds no state of its own and runs nothing on a
// timer: each request runs one-shot cx verbs and returns, and the browser is
// the loop (invariant 11). Killing it loses nothing.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"
)

// version is the cx release this binary was built for, set by the release
// build with -ldflags "-X main.version=X.Y.Z". cx web compares it with its
// own and builds from source instead when they differ.
var version = "dev"

// config is everything cx web is told on its command line.
type config struct {
	listen     string
	cxPath     string
	pagePath   string
	tokenFile  string
	interval   int
	allowHosts []string
	version    string
}

type stringList []string

func (s *stringList) String() string     { return strings.Join(*s, ",") }
func (s *stringList) Set(v string) error { *s = append(*s, v); return nil }

func main() {
	var cfg config
	var allow stringList
	var rotate, printURL, showVersion bool
	flag.StringVar(&cfg.listen, "listen", "127.0.0.1:8377", "address to listen on")
	flag.StringVar(&cfg.cxPath, "cx", "cx", "the cx command to run")
	flag.StringVar(&cfg.pagePath, "page", "", "the page, index.html")
	flag.StringVar(&cfg.tokenFile, "token-file", "", "where the token is kept (0600)")
	flag.IntVar(&cfg.interval, "interval", 10, "seconds between board refreshes, in the page")
	flag.Var(&allow, "allow-host", "another Host header to answer to, e.g. a reverse proxy's name (repeatable)")
	flag.StringVar(&cfg.version, "cx-version", "", "the cx version, shown in the page")
	flag.BoolVar(&rotate, "rotate-token", false, "replace the token, print the new URL, and exit")
	flag.BoolVar(&printURL, "print-url", false, "print the URL to open, with the token, and exit")
	flag.BoolVar(&showVersion, "version", false, "print the release this was built for, and exit")
	flag.Parse()
	cfg.allowHosts = allow

	if showVersion {
		fmt.Println(version)
		return
	}
	if cfg.tokenFile == "" || cfg.pagePath == "" {
		fatal(3, "--token-file and --page are required (cx web passes both)")
	}
	if cfg.interval < 2 || cfg.interval > 3600 {
		fatal(3, "--interval must be 2 to 3600 seconds")
	}

	tokens, err := newTokenStore(cfg.tokenFile)
	if err != nil {
		fatal(1, err.Error())
	}
	if rotate {
		if err := tokens.rotate(); err != nil {
			fatal(1, err.Error())
		}
		fmt.Fprintln(os.Stderr, "cx web: the token is replaced; every page signed in with the old one is signed out")
		fmt.Println(pageURL(cfg.listen, tokens.current()))
		return
	}
	if printURL {
		fmt.Println(pageURL(cfg.listen, tokens.current()))
		return
	}

	host, _, err := net.SplitHostPort(cfg.listen)
	if err != nil {
		fatal(3, "--listen wants host:port, e.g. 127.0.0.1:8377")
	}
	if !isLoopback(host) {
		fmt.Fprintf(os.Stderr, "cx web: WARNING: listening on %s, not only on this machine.\n", cfg.listen)
		fmt.Fprintln(os.Stderr, "        Anyone who can reach it and has the token can type into your sessions,")
		fmt.Fprintln(os.Stderr, "        and a no-perms session runs what it is told. Put TLS in front of it.")
	}

	srv := newServer(cfg, tokens)
	httpSrv := &http.Server{
		Addr:              cfg.listen,
		Handler:           srv,
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      150 * time.Second,
		IdleTimeout:       60 * time.Second,
		ErrorLog:          log.New(os.Stderr, "cx web: ", 0),
	}
	ln, err := net.Listen("tcp", cfg.listen)
	if err != nil {
		fatal(1, "cannot listen on "+cfg.listen+": "+err.Error())
	}
	fmt.Fprintln(os.Stderr, "cx web: serving on http://"+cfg.listen+"  (Ctrl-C to stop)")
	fmt.Fprintln(os.Stderr, "cx web: open this once to sign in; the token is in the #fragment, which is never sent anywhere:")
	fmt.Println(pageURL(cfg.listen, tokens.current()))

	done := make(chan struct{})
	go func() {
		sig := make(chan os.Signal, 1)
		signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
		<-sig
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = httpSrv.Shutdown(ctx)
		close(done)
	}()
	if err := httpSrv.Serve(ln); err != nil && !errors.Is(err, http.ErrServerClosed) {
		fatal(1, err.Error())
	}
	<-done
}

// pageURL is what to open. The token rides in the fragment: a browser never
// sends that part of a URL to any server, so it stays out of access logs,
// proxies and Referer headers. The page reads it once and drops it.
func pageURL(listen, token string) string {
	host, port, err := net.SplitHostPort(listen)
	if err != nil {
		return "http://" + listen + "/#token=" + token
	}
	if host == "" || host == "0.0.0.0" || host == "::" {
		host = "127.0.0.1"
	}
	return "http://" + net.JoinHostPort(host, port) + "/#token=" + token
}

func isLoopback(host string) bool {
	if host == "localhost" {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

func fatal(code int, msg string) {
	fmt.Fprintln(os.Stderr, "cx web: "+msg)
	os.Exit(code)
}
