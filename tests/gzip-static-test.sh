#!/usr/bin/env bash
#
# Black-box integration tests for gzip_static (pre-compressed file serving).
# Requires: a build environment with libubox/json-c so uhttpd can build & run.
#
# Usage:
#   ./tests/gzip-static-test.sh            # builds ./build/uhttpd if needed
#   UHTTPD_BIN=/path/to/uhttpd ./tests/gzip-static-test.sh
#
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${UHTTPD_BIN:-$ROOT/build/uhttpd}"
PORT="${UHTTPD_PORT:-18080}"
ADDR="127.0.0.1:$PORT"
DOCROOT=""
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

setup_docroot() { DOCROOT="$(mktemp -d)"; }

# Launch uhttpd in the foreground (backgrounded here) against $DOCROOT.
# Extra arguments are passed through to uhttpd (e.g. -S, -i, -x).
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
bodylen() { # bodylen <url> [extra curl args...]
	local url="$1"; shift
	curl -s "$@" "http://$ADDR/$url" | wc -c | tr -d ' '
}
body() { # body <url> [extra curl args...]
	local url="$1"; shift
	curl -s "$@" "http://$ADDR/$url"
}

# ---- Test: only the original file exists → output unchanged, no encoding ----
test_plain_only() {
	setup_docroot
	printf 'body{color:red}' > "$DOCROOT/a.css"
	launch

	local ce_gz ce_plain
	ce_gz="$(hdr a.css Content-Encoding -H 'Accept-Encoding: gzip')"
	ce_plain="$(hdr a.css Content-Encoding)"
	[ -z "$ce_gz" ]    && pass "plain-only: no Content-Encoding for gzip client" \
	                   || fail "plain-only: unexpected Content-Encoding '$ce_gz'"
	[ -z "$ce_plain" ] && pass "plain-only: no Content-Encoding for plain client" \
	                   || fail "plain-only: unexpected Content-Encoding '$ce_plain'"
	[ "$(status a.css)" = "200" ] && pass "plain-only: 200" || fail "plain-only: not 200"

	stop_uhttpd
}

# ---- Test: only the .gz exists ----
test_gz_only() {
	setup_docroot
	printf 'COMPRESSED-BYTES' > "$DOCROOT/a.css.gz"   # stand-in content
	launch

	local ce ct code_plain vary
	ce="$(hdr a.css Content-Encoding -H 'Accept-Encoding: gzip')"
	ct="$(hdr a.css Content-Type    -H 'Accept-Encoding: gzip')"
	[ "$ce" = "gzip" ] && pass "gz-only: Content-Encoding gzip" \
	                    || fail "gz-only: Content-Encoding was '$ce'"
	case "$ct" in text/css*) pass "gz-only: Content-Type from logical name" ;;
	              *) fail "gz-only: Content-Type was '$ct'" ;; esac
	[ "$(status a.css -H 'Accept-Encoding: gzip')" = "200" ] \
		&& pass "gz-only: 200 for gzip client" || fail "gz-only: not 200 for gzip client"

	code_plain="$(status a.css)"   # no Accept-Encoding: gzip
	[ "$code_plain" = "404" ] && pass "gz-only: 404 for non-gzip client" \
	                          || fail "gz-only: expected 404, got $code_plain"

	vary="$(hdr a.css Vary -H 'Accept-Encoding: gzip')"
	case "$vary" in *Accept-Encoding*) pass "gz-only: Vary: Accept-Encoding" ;;
	                *) fail "gz-only: Vary was '$vary'" ;; esac

	stop_uhttpd
}

# ---- Test: content-coding token is matched case-insensitively ----
test_ci() {
	setup_docroot
	printf 'X' > "$DOCROOT/a.css.gz"
	launch
	local code ce
	code="$(status a.css -H 'Accept-Encoding: GZIP')"
	ce="$(hdr a.css Content-Encoding -H 'Accept-Encoding: Gzip')"
	[ "$code" = "200" ] && pass "ci: uppercase GZIP accepted" \
	                     || fail "ci: GZIP got $code"
	[ "$ce" = "gzip" ] && pass "ci: mixed-case Gzip serves .gz" \
	                    || fail "ci: Content-Encoding was '$ce'"
	stop_uhttpd
}

# ---- Test: gzip;q=0 must be treated as not acceptable ----
test_q0() {
	setup_docroot
	printf 'X' > "$DOCROOT/a.css.gz"
	launch
	local code
	code="$(status a.css -H 'Accept-Encoding: gzip;q=0')"
	[ "$code" = "404" ] && pass "q0: gzip;q=0 → 404 (not served)" \
	                     || fail "q0: expected 404, got $code"
	stop_uhttpd
}

# ---- Test: both original and .gz exist ----
test_both() {
	setup_docroot
	printf 'PLAINDATA-1234567890' > "$DOCROOT/a.css"        # 20 bytes
	printf 'GZ' > "$DOCROOT/a.css.gz"                        # 2 bytes
	launch

	# gzip client → compressed variant (2-byte body, Content-Encoding gzip)
	local ce len ce2 len2
	ce="$(hdr a.css Content-Encoding -H 'Accept-Encoding: gzip')"
	len="$(bodylen a.css -H 'Accept-Encoding: gzip')"
	[ "$ce" = "gzip" ] && pass "both: gzip client gets Content-Encoding gzip" \
	                    || fail "both: Content-Encoding was '$ce'"
	[ "$len" = "2" ] && pass "both: gzip client gets .gz body (2 bytes)" \
	                 || fail "both: gzip body length was '$len'"

	# non-gzip client → original (20-byte body, no Content-Encoding)
	ce2="$(hdr a.css Content-Encoding)"
	len2="$(bodylen a.css)"
	[ -z "$ce2" ] && pass "both: plain client has no Content-Encoding" \
	              || fail "both: plain client Content-Encoding '$ce2'"
	[ "$len2" = "20" ] && pass "both: plain client gets original (20 bytes)" \
	                   || fail "both: plain body length was '$len2'"

	stop_uhttpd
}

# ---- Test: directory index exists only as .gz ----
test_index_gz() {
	setup_docroot
	mkdir -p "$DOCROOT/d"
	printf 'INDEXGZ' > "$DOCROOT/d/index.html.gz"
	launch

	local ce ct code
	ce="$(hdr d/ Content-Encoding -H 'Accept-Encoding: gzip')"
	ct="$(hdr d/ Content-Type     -H 'Accept-Encoding: gzip')"
	code="$(status d/ -H 'Accept-Encoding: gzip')"
	[ "$code" = "200" ] && pass "index-gz: 200 for gzip client" \
	                     || fail "index-gz: got $code"
	[ "$ce" = "gzip" ] && pass "index-gz: Content-Encoding gzip" \
	                    || fail "index-gz: Content-Encoding '$ce'"
	case "$ct" in text/html*) pass "index-gz: Content-Type text/html" ;;
	              *) fail "index-gz: Content-Type '$ct'" ;; esac

	stop_uhttpd
}

# ---- Test: ETag from .gz drives 304; HEAD keeps encoding, no body ----
test_conditional() {
	setup_docroot
	printf 'GZBYTES' > "$DOCROOT/a.css.gz"
	launch

	local etag code head_ce
	etag="$(hdr a.css ETag -H 'Accept-Encoding: gzip')"
	[ -n "$etag" ] && pass "cond: ETag present" || fail "cond: no ETag"

	code="$(status a.css -H 'Accept-Encoding: gzip' -H "If-None-Match: $etag")"
	[ "$code" = "304" ] && pass "cond: matching If-None-Match → 304" \
	                     || fail "cond: expected 304, got $code"

	head_ce="$(curl -s -I -H 'Accept-Encoding: gzip' "http://$ADDR/a.css" \
		| grep -ci 'content-encoding: gzip')"
	[ "$head_ce" -ge 1 ] && pass "cond: HEAD keeps Content-Encoding" \
	                     || fail "cond: HEAD missing Content-Encoding"

	stop_uhttpd
}

# ---- Test: -S (no_symlinks) must not follow a symlinked .gz variant ----
test_no_symlinks_gz_symlink() {
	setup_docroot
	local outside ce blen code
	outside="$(mktemp)"
	printf 'SECRET-OUTSIDE-DOCROOT' > "$outside"
	chmod 644 "$outside"
	printf 'PLAIN' > "$DOCROOT/a.css"                # 5 bytes
	ln -s "$outside" "$DOCROOT/a.css.gz"
	launch -S

	ce="$(hdr a.css Content-Encoding -H 'Accept-Encoding: gzip')"
	blen="$(bodylen a.css -H 'Accept-Encoding: gzip')"
	[ -z "$ce" ] && pass "noSymlinks: symlinked .gz not served as gzip" \
	             || fail "noSymlinks: symlinked .gz served (Content-Encoding '$ce')"
	[ "$blen" = "5" ] && pass "noSymlinks: gzip client falls back to plain body" \
	                  || fail "noSymlinks: body length was '$blen' (expected 5)"

	# without the plain file the lookup must fail, not leak the target
	rm "$DOCROOT/a.css"
	code="$(status a.css -H 'Accept-Encoding: gzip')"
	[ "$code" = "404" ] && pass "noSymlinks: gz-only symlink → 404" \
	                     || fail "noSymlinks: gz-only symlink got $code"

	stop_uhttpd
	rm -f "$outside"
}

# ---- Test: -S with a regular .gz file only (no symlinks involved) ----
test_no_symlinks_gz_only() {
	setup_docroot
	printf 'GZDATA' > "$DOCROOT/a.css.gz"
	launch -S

	local code ce
	code="$(status a.css -H 'Accept-Encoding: gzip')"
	ce="$(hdr a.css Content-Encoding -H 'Accept-Encoding: gzip')"
	[ "$code" = "200" ] && pass "noSymlinks: gz-only regular file → 200" \
	                     || fail "noSymlinks: gz-only got $code"
	[ "$ce" = "gzip" ] && pass "noSymlinks: gz-only Content-Encoding gzip" \
	                    || fail "noSymlinks: Content-Encoding '$ce'"
	stop_uhttpd
}

# ---- Test: the .gz fallback must never feed CGI/interpreter dispatch ----
test_script_no_gz_fallback() {
	setup_docroot
	printf 'FAKE' > "$DOCROOT/foo.php.gz"
	mkdir -p "$DOCROOT/cgi-bin"
	printf 'FAKE' > "$DOCROOT/cgi-bin/prog.gz"
	launch -i .php=/bin/sh -x /cgi-bin

	local code_php code_cgi
	code_php="$(status foo.php -H 'Accept-Encoding: gzip')"
	code_cgi="$(status cgi-bin/prog -H 'Accept-Encoding: gzip')"
	[ "$code_php" = "404" ] && pass "script: interpreter path with only .gz → 404" \
	                         || fail "script: foo.php got $code_php (expected 404)"
	[ "$code_cgi" = "404" ] && pass "script: cgi-bin path with only .gz → 404" \
	                         || fail "script: cgi-bin/prog got $code_cgi (expected 404)"
	stop_uhttpd
}

# ---- Test: multiple Accept-Encoding headers accumulate (RFC 9110 5.3) ----
test_multi_ae_headers() {
	setup_docroot
	printf 'GZ' > "$DOCROOT/a.css.gz"
	launch

	local c1 c2
	c1="$(status a.css -H 'Accept-Encoding: br' -H 'Accept-Encoding: gzip')"
	c2="$(status a.css -H 'Accept-Encoding: gzip' -H 'Accept-Encoding: br')"
	[ "$c1" = "200" ] && pass "multiAE: gzip in second header honored" \
	                  || fail "multiAE: br,gzip got $c1"
	[ "$c2" = "200" ] && pass "multiAE: gzip in first header survives later headers" \
	                  || fail "multiAE: gzip,br got $c2"
	stop_uhttpd
}

# ---- Test: Accept-Encoding: * wildcard (RFC 7231 5.3.4) ----
test_star() {
	setup_docroot
	printf 'GZ' > "$DOCROOT/a.css.gz"
	launch

	local c_star c_star_q0 c_explicit_q0
	c_star="$(status a.css -H 'Accept-Encoding: *')"
	c_star_q0="$(status a.css -H 'Accept-Encoding: *;q=0')"
	c_explicit_q0="$(status a.css -H 'Accept-Encoding: gzip;q=0, *')"
	[ "$c_star" = "200" ] && pass "star: * accepts gzip" \
	                       || fail "star: * got $c_star"
	[ "$c_star_q0" = "404" ] && pass "star: *;q=0 not acceptable" \
	                          || fail "star: *;q=0 got $c_star_q0"
	[ "$c_explicit_q0" = "404" ] && pass "star: explicit gzip;q=0 beats *" \
	                              || fail "star: 'gzip;q=0, *' got $c_explicit_q0"
	stop_uhttpd
}

# ---- Test: plain response carries Vary when a .gz sibling exists ----
test_vary_plain() {
	setup_docroot
	printf 'PLAINDATA' > "$DOCROOT/a.css"
	printf 'GZ' > "$DOCROOT/a.css.gz"
	printf 'ONLY' > "$DOCROOT/b.css"
	launch

	local vary_both vary_only
	vary_both="$(hdr a.css Vary)"                       # non-gzip client
	vary_only="$(hdr b.css Vary)"
	case "$vary_both" in *Accept-Encoding*) pass "vary: plain response advertises Vary" ;;
	                     *) fail "vary: plain response Vary was '$vary_both'" ;; esac
	[ -z "$vary_only" ] && pass "vary: no .gz sibling → no Vary" \
	                    || fail "vary: unexpected Vary '$vary_only'"
	stop_uhttpd
}

build_if_needed
test_plain_only
test_gz_only
test_ci
test_q0
test_both
test_index_gz
test_conditional
test_no_symlinks_gz_symlink
test_no_symlinks_gz_only
test_script_no_gz_fallback
test_multi_ae_headers
test_star
test_vary_plain

log "----"
[ "$FAILS" -eq 0 ] && { log "ALL PASS"; exit 0; } || { log "$FAILS failure(s)"; exit 1; }
