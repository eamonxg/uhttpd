#!/usr/bin/env bash
#
# Black-box integration tests for on-the-fly gzip compression (-z level).
# Requires: a build environment with libubox/json-c so uhttpd can build & run.
#
# Usage:
#   ./tests/gzip-runtime-test.sh            # builds ./build/uhttpd if needed
#   UHTTPD_BIN=/path/to/uhttpd ./tests/gzip-runtime-test.sh
#
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${UHTTPD_BIN:-$ROOT/build/uhttpd}"
PORT="${UHTTPD_PORT:-18081}"
ADDR="127.0.0.1:$PORT"
DOCROOT=""
WORK=""
PID=""
FAILS=0

log()  { printf '%s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*"; FAILS=$((FAILS+1)); }
pass() { printf 'ok:   %s\n' "$*"; }

build_if_needed() {
	if [ -x "$BIN" ]; then return; fi
	log "building uhttpd..."
	mkdir -p "$ROOT/build"
	( cd "$ROOT/build" && cmake .. >/dev/null && make uhttpd >/dev/null ) \
		|| { log "build failed — set UHTTPD_BIN to a prebuilt binary"; exit 2; }
	BIN="$ROOT/build/uhttpd"
}

setup_docroot() {
	DOCROOT="$(mktemp -d)"
	WORK="$(mktemp -d)"
	# ~100KiB of repetitive css-ish text, ideal for gzip
	yes '.a{color:#123456;margin:0 auto;padding:1px 2px 3px 4px}' \
		| head -c 102400 > "$DOCROOT/big.css"
	# 1MiB text file to exercise the multi-callback streaming path
	yes 'the quick brown fox jumps over the lazy dog 0123456789' \
		| head -c 1048576 > "$DOCROOT/huge.txt"
	printf 'body{color:red}' > "$DOCROOT/tiny.css"            # < 256 bytes
	head -c 4096 /dev/urandom > "$DOCROOT/blob.bin"           # binary mime
}

# Launch uhttpd in the foreground (backgrounded here) against $DOCROOT.
# Extra arguments (e.g. -z 1) are passed through to uhttpd.
launch() {
	"$BIN" -f -p "$ADDR" -h "$DOCROOT" "$@" >/dev/null 2>&1 &
	PID=$!
	# wait for the port to accept connections
	for _ in $(seq 1 50); do
		if curl -s -o /dev/null "http://$ADDR/" ; then return; fi
		sleep 0.1
	done
	fail "uhttpd did not start"; exit 2
}

stop_uhttpd() {
	[ -n "$PID" ] && kill "$PID" 2>/dev/null
	wait "$PID" 2>/dev/null
	PID=""
	[ -n "$DOCROOT" ] && rm -rf "$DOCROOT"
	DOCROOT=""
	[ -n "$WORK" ] && rm -rf "$WORK"
	WORK=""
}

# curl helpers.
hdr() { # hdr <url> <header-name> [extra curl args...]
	local url="$1" name="$2"; shift 2
	curl -s -D - -o /dev/null "$@" "http://$ADDR/$url" \
		| tr -d '\r' | awk -v h="$(printf '%s' "$name" | tr A-Z a-z)" \
			'tolower($1)==h":"{ $1=""; sub(/^ /,""); print }'
}
status() { # status <url> [extra curl args...]
	local url="$1"; shift
	curl -s -o /dev/null -w '%{http_code}' "$@" "http://$ADDR/$url"
}

# ---- Test: compressed roundtrip with correct headers ----
test_roundtrip() {
	local ce te cl vary
	ce="$(hdr big.css Content-Encoding -H 'Accept-Encoding: gzip')"
	te="$(hdr big.css Transfer-Encoding -H 'Accept-Encoding: gzip')"
	cl="$(hdr big.css Content-Length -H 'Accept-Encoding: gzip')"
	vary="$(hdr big.css Vary -H 'Accept-Encoding: gzip')"
	[ "$ce" = "gzip" ] && pass "roundtrip: Content-Encoding gzip" \
	                    || fail "roundtrip: Content-Encoding was '$ce'"
	[ "$te" = "chunked" ] && pass "roundtrip: Transfer-Encoding chunked" \
	                       || fail "roundtrip: Transfer-Encoding was '$te'"
	[ -z "$cl" ] && pass "roundtrip: no Content-Length" \
	             || fail "roundtrip: unexpected Content-Length '$cl'"
	case "$vary" in *Accept-Encoding*) pass "roundtrip: Vary: Accept-Encoding" ;;
	                *) fail "roundtrip: Vary was '$vary'" ;; esac

	curl -s -H 'Accept-Encoding: gzip' -o "$WORK/big.css.gz" "http://$ADDR/big.css"
	if gzip -dc "$WORK/big.css.gz" > "$WORK/big.css" 2>/dev/null \
	   && cmp -s "$WORK/big.css" "$DOCROOT/big.css"; then
		pass "roundtrip: body gunzips to original bytes"
	else
		fail "roundtrip: decompressed body differs from original"
	fi

	local raw orig
	raw="$(wc -c < "$WORK/big.css.gz" | tr -d ' ')"
	orig="$(wc -c < "$DOCROOT/big.css" | tr -d ' ')"
	if [ "$raw" -lt $((orig * 15 / 100)) ]; then
		pass "roundtrip: compressed to <15% ($raw/$orig bytes)"
	else
		fail "roundtrip: poor ratio ($raw/$orig bytes)"
	fi
}

# ---- Test: identity responses when the client does not accept gzip ----
test_identity() {
	local ce cl vary ce_q0
	ce="$(hdr big.css Content-Encoding)"
	cl="$(hdr big.css Content-Length)"
	vary="$(hdr big.css Vary)"
	[ -z "$ce" ] && pass "identity: no Content-Encoding without Accept-Encoding" \
	             || fail "identity: unexpected Content-Encoding '$ce'"
	[ "$cl" = "102400" ] && pass "identity: Content-Length preserved" \
	                      || fail "identity: Content-Length was '$cl'"
	case "$vary" in *Accept-Encoding*) pass "identity: still sends Vary" ;;
	                *) fail "identity: Vary was '$vary'" ;; esac

	ce_q0="$(hdr big.css Content-Encoding -H 'Accept-Encoding: gzip;q=0')"
	[ -z "$ce_q0" ] && pass "identity: gzip;q=0 not compressed" \
	                || fail "identity: gzip;q=0 got Content-Encoding '$ce_q0'"

	if curl -s "http://$ADDR/big.css" | cmp -s - "$DOCROOT/big.css"; then
		pass "identity: body is verbatim original"
	else
		fail "identity: body differs from original"
	fi
}

# ---- Test: skip small files and non-compressible types ----
test_skip() {
	local ce_tiny ce_bin vary_bin
	ce_tiny="$(hdr tiny.css Content-Encoding -H 'Accept-Encoding: gzip')"
	ce_bin="$(hdr blob.bin Content-Encoding -H 'Accept-Encoding: gzip')"
	vary_bin="$(hdr blob.bin Vary -H 'Accept-Encoding: gzip')"
	[ -z "$ce_tiny" ] && pass "skip: file below min size not compressed" \
	                  || fail "skip: tiny file got Content-Encoding '$ce_tiny'"
	[ -z "$ce_bin" ] && pass "skip: binary mime not compressed" \
	                 || fail "skip: binary got Content-Encoding '$ce_bin'"
	[ -z "$vary_bin" ] && pass "skip: binary mime has no Vary" \
	                   || fail "skip: binary Vary was '$vary_bin'"
}

# ---- Test: HTTP/1.0 and HEAD keep the identity path ----
test_proto() {
	local ce10 head_hdrs
	ce10="$(hdr big.css Content-Encoding --http1.0 -H 'Accept-Encoding: gzip')"
	[ -z "$ce10" ] && pass "proto: HTTP/1.0 not compressed" \
	               || fail "proto: HTTP/1.0 got Content-Encoding '$ce10'"

	head_hdrs="$(curl -s -I -H 'Accept-Encoding: gzip' "http://$ADDR/big.css" | tr -d '\r')"
	if printf '%s\n' "$head_hdrs" | grep -qi '^content-length: 102400'; then
		pass "proto: HEAD has identity Content-Length"
	else
		fail "proto: HEAD Content-Length missing/wrong"
	fi
	if printf '%s\n' "$head_hdrs" | grep -qi '^content-encoding:'; then
		fail "proto: HEAD unexpectedly has Content-Encoding"
	else
		pass "proto: HEAD has no Content-Encoding"
	fi
}

# ---- Test: per-variant ETag and revalidation ----
test_etag() {
	local etag_gz etag_plain code
	etag_gz="$(hdr big.css ETag -H 'Accept-Encoding: gzip')"
	etag_plain="$(hdr big.css ETag)"
	case "$etag_gz" in *-gz\") pass "etag: gzip variant suffixed -gz" ;;
	                   *) fail "etag: gzip variant ETag was '$etag_gz'" ;; esac
	[ -n "$etag_plain" ] && [ "$etag_gz" != "$etag_plain" ] \
		&& pass "etag: variants have distinct ETags" \
		|| fail "etag: ETags not distinct ('$etag_gz' vs '$etag_plain')"

	code="$(status big.css -H 'Accept-Encoding: gzip' -H "If-None-Match: $etag_gz")"
	[ "$code" = "304" ] && pass "etag: If-None-Match on gz variant → 304" \
	                     || fail "etag: expected 304, got $code"

	code="$(status big.css -H "If-None-Match: $etag_plain")"
	[ "$code" = "304" ] && pass "etag: If-None-Match on plain variant → 304" \
	                     || fail "etag: expected 304, got $code"
}

# ---- Test: 1MiB file streams correctly through many write callbacks ----
test_large() {
	curl -s -H 'Accept-Encoding: gzip' -o "$WORK/huge.txt.gz" "http://$ADDR/huge.txt"
	if gzip -dc "$WORK/huge.txt.gz" > "$WORK/huge.txt" 2>/dev/null \
	   && cmp -s "$WORK/huge.txt" "$DOCROOT/huge.txt"; then
		pass "large: 1MiB body gunzips to original bytes"
	else
		fail "large: decompressed 1MiB body differs"
	fi
}

# ---- Test: keep-alive connection reuse with chunked compressed bodies ----
test_keepalive() {
	local verbose
	verbose="$(curl -sv -H 'Accept-Encoding: gzip' \
		-o "$WORK/k1.gz" "http://$ADDR/big.css" \
		-o "$WORK/k2.gz" "http://$ADDR/big.css" 2>&1)"
	if printf '%s\n' "$verbose" | grep -q 'Re-using existing connection'; then
		pass "keepalive: second request reuses connection"
	else
		fail "keepalive: connection not reused"
	fi
	if gzip -dc "$WORK/k1.gz" 2>/dev/null | cmp -s - "$DOCROOT/big.css" \
	   && gzip -dc "$WORK/k2.gz" 2>/dev/null | cmp -s - "$DOCROOT/big.css"; then
		pass "keepalive: both chunked bodies intact"
	else
		fail "keepalive: body corruption across keep-alive requests"
	fi
}

# ---- Test: compression is off by default (no -z) ----
test_default_off() {
	local ce vary
	ce="$(hdr big.css Content-Encoding -H 'Accept-Encoding: gzip')"
	vary="$(hdr big.css Vary -H 'Accept-Encoding: gzip')"
	[ -z "$ce" ] && pass "default-off: no Content-Encoding without -z" \
	             || fail "default-off: got Content-Encoding '$ce'"
	[ -z "$vary" ] && pass "default-off: no Vary without -z" \
	               || fail "default-off: Vary was '$vary'"
}

build_if_needed

setup_docroot
launch -z 1
test_roundtrip
test_identity
test_skip
test_proto
test_etag
test_large
test_keepalive
stop_uhttpd

setup_docroot
launch
test_default_off
stop_uhttpd

log "----"
[ "$FAILS" -eq 0 ] && { log "ALL PASS"; exit 0; } || { log "$FAILS failure(s)"; exit 1; }
