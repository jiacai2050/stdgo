package main

import (
	"encoding/binary"
	"flag"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"strconv"
	"time"
)

var hopHeaders = []string{
	"Connection",
	"Keep-Alive",
	"Proxy-Authenticate",
	"Proxy-Authorization",
	"Proxy-Connection",
	"Te",
	"Trailers",
	"Transfer-Encoding",
	"Upgrade",
}

func delHopHeaders(header http.Header) {
	for _, h := range hopHeaders {
		header.Del(h)
	}
}

func handleConnect(w http.ResponseWriter, r *http.Request) {
	log.Printf("handleConnect started for host=%s", r.Host)
	destConn, err := net.DialTimeout("tcp", r.Host, 10*time.Second)
	if err != nil {
		log.Printf("handleConnect: dial error: %v", err)
		http.Error(w, err.Error(), http.StatusServiceUnavailable)
		return
	}
	defer destConn.Close()

	hijacker, ok := w.(http.Hijacker)
	if !ok {
		log.Printf("handleConnect: hijacker not supported")
		http.Error(w, "Hijacking not supported", http.StatusInternalServerError)
		return
	}

	clientConn, brw, err := hijacker.Hijack()
	if err != nil {
		log.Printf("handleConnect: hijack error: %v", err)
		http.Error(w, err.Error(), http.StatusServiceUnavailable)
		return
	}
	defer clientConn.Close()

	_, err = clientConn.Write([]byte("HTTP/1.1 200 Connection Established\r\n\r\n"))
	if err != nil {
		log.Printf("handleConnect: write 200 error: %v", err)
		return
	}

	done := make(chan struct{}, 2)
	go func() {
		var src io.Reader = clientConn
		if brw != nil && brw.Reader.Buffered() > 0 {
			src = io.MultiReader(brw.Reader, clientConn)
		}
		n, err := io.Copy(destConn, src)
		log.Printf("handleConnect: copied %d bytes from client to dest, err=%v", n, err)
		if tc, ok := destConn.(*net.TCPConn); ok {
			_ = tc.CloseWrite()
		}
		done <- struct{}{}
	}()
	go func() {
		n, err := io.Copy(clientConn, destConn)
		log.Printf("handleConnect: copied %d bytes from dest to client, err=%v", n, err)
		if tc, ok := clientConn.(*net.TCPConn); ok {
			_ = tc.CloseWrite()
		}
		done <- struct{}{}
	}()
	<-done
	log.Printf("handleConnect: done")
}

var proxyTransport = &http.Transport{
	Proxy: nil,
	DialContext: (&net.Dialer{
		Timeout:   10 * time.Second,
		KeepAlive: 30 * time.Second,
	}).DialContext,
	MaxIdleConns:          100,
	IdleConnTimeout:       90 * time.Second,
	TLSHandshakeTimeout:   10 * time.Second,
	ExpectContinueTimeout: 1 * time.Second,
}

func handleHTTP(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path == "/healthz" {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok\n"))
		return
	}

	outReq := r.Clone(r.Context())
	if outReq.URL.Scheme == "" {
		outReq.URL.Scheme = "http"
	}
	if outReq.URL.Host == "" {
		outReq.URL.Host = r.Host
	}
	outReq.RequestURI = ""

	delHopHeaders(outReq.Header)

	resp, err := proxyTransport.RoundTrip(outReq)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()

	delHopHeaders(resp.Header)

	for k, vv := range resp.Header {
		for _, v := range vv {
			w.Header().Add(k, v)
		}
	}
	w.WriteHeader(resp.StatusCode)
	_, _ = io.Copy(w, resp.Body)
}

func handleSocks5Connection(c net.Conn) {
	defer c.Close()

	_ = c.SetDeadline(time.Now().Add(10 * time.Second))

	// 1. Negotiation: [VER=0x05, NMETHODS, METHODS...]
	buf := make([]byte, 256)
	if _, err := io.ReadFull(c, buf[:2]); err != nil {
		return
	}
	if buf[0] != 0x05 {
		return
	}

	numMethods := int(buf[1])
	methods := make([]byte, numMethods)
	if _, err := io.ReadFull(c, methods); err != nil {
		return
	}

	hasNoAuth := false
	hasUserPass := false
	for _, m := range methods {
		if m == 0x00 {
			hasNoAuth = true
		} else if m == 0x02 {
			hasUserPass = true
		}
	}

	if hasNoAuth {
		if _, err := c.Write([]byte{0x05, 0x00}); err != nil {
			return
		}
	} else if hasUserPass {
		if _, err := c.Write([]byte{0x05, 0x02}); err != nil {
			return
		}
		// Subnegotiation: [0x01, ulen, uname..., plen, passwd...]
		if _, err := io.ReadFull(c, buf[:2]); err != nil || buf[0] != 0x01 {
			return
		}
		uLen := int(buf[1])
		uname := make([]byte, uLen)
		if _, err := io.ReadFull(c, uname); err != nil {
			return
		}
		if _, err := io.ReadFull(c, buf[:1]); err != nil {
			return
		}
		pLen := int(buf[0])
		passwd := make([]byte, pLen)
		if _, err := io.ReadFull(c, passwd); err != nil {
			return
		}
		if _, err := c.Write([]byte{0x01, 0x00}); err != nil {
			return
		}
	} else {
		_, _ = c.Write([]byte{0x05, 0xff})
		return
	}

	// 2. Request: [VER=0x05, CMD=0x01, RSV=0x00, ATYP]
	if _, err := io.ReadFull(c, buf[:4]); err != nil {
		return
	}
	if buf[0] != 0x05 || buf[1] != 0x01 {
		_, _ = c.Write([]byte{0x05, 0x07, 0x00, 0x01, 0, 0, 0, 0, 0, 0})
		return
	}

	var host string
	switch buf[3] {
	case 0x01: // IPv4
		if _, err := io.ReadFull(c, buf[:4]); err != nil {
			return
		}
		host = net.IP(buf[:4]).String()
	case 0x03: // Domain name
		if _, err := io.ReadFull(c, buf[:1]); err != nil {
			return
		}
		domainLen := int(buf[0])
		domain := make([]byte, domainLen)
		if _, err := io.ReadFull(c, domain); err != nil {
			return
		}
		host = string(domain)
	case 0x04: // IPv6
		if _, err := io.ReadFull(c, buf[:16]); err != nil {
			return
		}
		host = net.IP(buf[:16]).String()
	default:
		_, _ = c.Write([]byte{0x05, 0x08, 0x00, 0x01, 0, 0, 0, 0, 0, 0})
		return
	}

	if _, err := io.ReadFull(c, buf[:2]); err != nil {
		return
	}
	port := binary.BigEndian.Uint16(buf[:2])
	target := net.JoinHostPort(host, strconv.Itoa(int(port)))

	// 3. Dial upstream target
	dest, err := net.DialTimeout("tcp", target, 10*time.Second)
	if err != nil {
		_, _ = c.Write([]byte{0x05, 0x04, 0x00, 0x01, 0, 0, 0, 0, 0, 0})
		return
	}
	defer dest.Close()

	_ = c.SetDeadline(time.Time{})

	// 4. Success reply
	if _, err := c.Write([]byte{0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0}); err != nil {
		return
	}

	// 5. Bidirectional Relay
	done := make(chan struct{}, 2)
	go func() {
		_, _ = io.Copy(dest, c)
		if tc, ok := dest.(*net.TCPConn); ok {
			_ = tc.CloseWrite()
		}
		done <- struct{}{}
	}()
	go func() {
		_, _ = io.Copy(c, dest)
		if tc, ok := c.(*net.TCPConn); ok {
			_ = tc.CloseWrite()
		}
		done <- struct{}{}
	}()
	<-done
}

func startSocks5Server(addr string) {
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		log.Fatalf("SOCKS5 listen error on %s: %v", addr, err)
	}
	defer ln.Close()
	log.Printf("Starting SOCKS5 proxy server on %s\n", addr)

	for {
		conn, err := ln.Accept()
		if err != nil {
			log.Printf("SOCKS5 accept error: %v", err)
			continue
		}
		go handleSocks5Connection(conn)
	}
}

func main() {
	defaultHTTP := ":38888"
	if p := os.Getenv("STDGO_HTTP_PROXY_PORT"); p != "" {
		defaultHTTP = ":" + p
	}
	defaultSOCKS := ":31080"
	if p := os.Getenv("STDGO_SOCKS_PROXY_PORT"); p != "" {
		defaultSOCKS = ":" + p
	}

	addr := flag.String("addr", defaultHTTP, "HTTP proxy listen address (alias for -http-addr)")
	httpAddr := flag.String("http-addr", "", "HTTP proxy listen address")
	socksAddr := flag.String("socks-addr", defaultSOCKS, "SOCKS5 proxy listen address")
	flag.Parse()

	targetHTTP := *addr
	if *httpAddr != "" {
		targetHTTP = *httpAddr
	}

	go startSocks5Server(*socksAddr)

	server := &http.Server{
		Addr: targetHTTP,
		Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.Method == http.MethodConnect {
				handleConnect(w, r)
			} else {
				handleHTTP(w, r)
			}
		}),
	}

	log.Printf("Starting HTTP proxy server on %s\n", targetHTTP)
	if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatalf("HTTP proxy server error: %v", err)
	}
}
