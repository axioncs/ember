/* ember-cdpd — one-shot CDP client for Steam's webhelper.
 *
 * Steam renders store pages, settings panels and themes in steamwebhelper, and
 * the only way in is Chromium's DevTools protocol over a WebSocket. Doing that
 * needs a socket and a WS handshake, which the Lua CLI cannot do without a
 * dependency, so it lives here: connect, evaluate one expression, print the
 * response, exit.
 *
 * Scope is deliberately small: text frames only, no continuation reassembly
 * beyond what a single CDP response needs, one request per run. Everything a
 * session needs beyond that (bindings, event handling) is the next step and
 * belongs in a different mode, not in a bigger one-shot.
 *
 *   ember-cdpd --ws ws://127.0.0.1:8080/devtools/page/<id> --eval "1+1"
 *   ember-cdpd --ws <url> --eval-file script.js [--timeout-ms 15000]
 */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <netdb.h>
#include <netinet/in.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

/* ------------------------------------------------------------------ base64 */
static const char B64[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

static void b64_encode(const unsigned char *in, size_t len, char *out)
{
	size_t i = 0, o = 0;
	for (; i + 2 < len; i += 3) {
		out[o++] = B64[in[i] >> 2];
		out[o++] = B64[((in[i] & 3) << 4) | (in[i + 1] >> 4)];
		out[o++] = B64[((in[i + 1] & 15) << 2) | (in[i + 2] >> 6)];
		out[o++] = B64[in[i + 2] & 63];
	}
	if (i < len) {
		out[o++] = B64[in[i] >> 2];
		if (i + 1 < len) {
			out[o++] = B64[((in[i] & 3) << 4) | (in[i + 1] >> 4)];
			out[o++] = B64[(in[i + 1] & 15) << 2];
		} else {
			out[o++] = B64[(in[i] & 3) << 4];
			out[o++] = '=';
		}
		out[o++] = '=';
	}
	out[o] = '\0';
}

/* -------------------------------------------------------------------- sha1 */
typedef struct {
	uint32_t h[5];
	uint64_t len;
	unsigned char buf[64];
	size_t used;
} sha1_t;

static uint32_t rol(uint32_t v, int n) { return (v << n) | (v >> (32 - n)); }

static void sha1_block(sha1_t *s, const unsigned char *p)
{
	uint32_t w[80];
	for (int i = 0; i < 16; i++)
		w[i] = (uint32_t)p[i * 4] << 24 | (uint32_t)p[i * 4 + 1] << 16 |
		       (uint32_t)p[i * 4 + 2] << 8 | p[i * 4 + 3];
	for (int i = 16; i < 80; i++)
		w[i] = rol(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);

	uint32_t a = s->h[0], b = s->h[1], c = s->h[2], d = s->h[3], e = s->h[4];
	for (int i = 0; i < 80; i++) {
		uint32_t f, k;
		if (i < 20) {
			f = (b & c) | (~b & d);
			k = 0x5A827999;
		} else if (i < 40) {
			f = b ^ c ^ d;
			k = 0x6ED9EBA1;
		} else if (i < 60) {
			f = (b & c) | (b & d) | (c & d);
			k = 0x8F1BBCDC;
		} else {
			f = b ^ c ^ d;
			k = 0xCA62C1D6;
		}
		uint32_t tmp = rol(a, 5) + f + e + k + w[i];
		e = d;
		d = c;
		c = rol(b, 30);
		b = a;
		a = tmp;
	}
	s->h[0] += a;
	s->h[1] += b;
	s->h[2] += c;
	s->h[3] += d;
	s->h[4] += e;
}

static void sha1_init(sha1_t *s)
{
	s->h[0] = 0x67452301;
	s->h[1] = 0xEFCDAB89;
	s->h[2] = 0x98BADCFE;
	s->h[3] = 0x10325476;
	s->h[4] = 0xC3D2E1F0;
	s->len = 0;
	s->used = 0;
}

static void sha1_update(sha1_t *s, const void *data, size_t n)
{
	const unsigned char *p = data;
	s->len += n * 8;
	while (n > 0) {
		size_t take = 64 - s->used;
		if (take > n)
			take = n;
		memcpy(s->buf + s->used, p, take);
		s->used += take;
		p += take;
		n -= take;
		if (s->used == 64) {
			sha1_block(s, s->buf);
			s->used = 0;
		}
	}
}

static void sha1_final(sha1_t *s, unsigned char out[20])
{
	uint64_t bits = s->len;
	unsigned char pad = 0x80;
	sha1_update(s, &pad, 1);
	unsigned char zero = 0;
	while (s->used != 56)
		sha1_update(s, &zero, 1);
	unsigned char lenbuf[8];
	for (int i = 0; i < 8; i++)
		lenbuf[i] = (unsigned char)(bits >> (56 - i * 8));
	sha1_update(s, lenbuf, 8);
	for (int i = 0; i < 5; i++) {
		out[i * 4] = (unsigned char)(s->h[i] >> 24);
		out[i * 4 + 1] = (unsigned char)(s->h[i] >> 16);
		out[i * 4 + 2] = (unsigned char)(s->h[i] >> 8);
		out[i * 4 + 3] = (unsigned char)s->h[i];
	}
}

/* ------------------------------------------------------------------ socket */
static int tcp_connect(const char *host, int port, int timeout_ms)
{
	struct addrinfo hints = { 0 }, *res = NULL;
	hints.ai_family = AF_INET;
	hints.ai_socktype = SOCK_STREAM;
	char service[16];
	snprintf(service, sizeof service, "%d", port);
	if (getaddrinfo(host, service, &hints, &res) != 0)
		return -1;

	int fd = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
	if (fd < 0) {
		freeaddrinfo(res);
		return -1;
	}

	struct timeval tv = { timeout_ms / 1000, (timeout_ms % 1000) * 1000 };
	setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
	setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);

	if (connect(fd, res->ai_addr, res->ai_addrlen) != 0) {
		close(fd);
		freeaddrinfo(res);
		return -1;
	}
	freeaddrinfo(res);
	return fd;
}

static int send_all(int fd, const void *buf, size_t len)
{
	const char *p = buf;
	while (len > 0) {
		ssize_t n = send(fd, p, len, 0);
		if (n <= 0)
			return -1;
		p += n;
		len -= (size_t)n;
	}
	return 0;
}

/* Reads until `needle` appears in buf (headers, handshake response). */
static ssize_t read_until(int fd, char *buf, size_t cap, const char *needle)
{
	size_t used = 0;
	while (used + 1 < cap) {
		ssize_t n = recv(fd, buf + used, cap - used - 1, 0);
		if (n <= 0)
			return -1;
		used += (size_t)n;
		buf[used] = '\0';
		if (strstr(buf, needle) != NULL)
			return (ssize_t)used;
	}
	return -1;
}

static ssize_t read_exact(int fd, void *buf, size_t len)
{
	unsigned char *p = buf;
	size_t got = 0;
	while (got < len) {
		ssize_t n = recv(fd, p + got, len - got, 0);
		if (n <= 0)
			return -1;
		got += (size_t)n;
	}
	return (ssize_t)got;
}

/* -------------------------------------------------------- websocket frames */
static int ws_send_text(int fd, const char *text)
{
	size_t len = strlen(text);
	unsigned char head[14];
	size_t head_len;

	head[0] = 0x81; /* FIN + text */
	if (len < 126) {
		head[1] = 0x80 | (unsigned char)len;
		head_len = 2;
	} else if (len < 65536) {
		head[1] = 0x80 | 126;
		head[2] = (unsigned char)(len >> 8);
		head[3] = (unsigned char)len;
		head_len = 4;
	} else {
		head[1] = 0x80 | 127;
		for (int i = 0; i < 8; i++)
			head[2 + i] = (unsigned char)((uint64_t)len >> (56 - i * 8));
		head_len = 10;
	}

	unsigned char mask[4];
	if (getentropy(mask, sizeof mask) != 0) {
		mask[0] = 0x12;
		mask[1] = 0x34;
		mask[2] = 0x56;
		mask[3] = 0x78;
	}
	memcpy(head + head_len, mask, 4);
	head_len += 4;

	char *payload = malloc(len);
	if (!payload)
		return -1;
	for (size_t i = 0; i < len; i++)
		payload[i] = (char)(text[i] ^ mask[i % 4]);

	int rc = send_all(fd, head, head_len) == 0 && send_all(fd, payload, len) == 0 ? 0 : -1;
	free(payload);
	return rc;
}

/* Reads one complete data frame into out (NUL-terminated). Pings are answered.
 * Fragmented frames are rejected rather than half-handled: a truncated CDP
 * response would be reported as "no answer" and cost a debugging round. */
static ssize_t ws_read_message(int fd, char *out, size_t cap)
{
	for (;;) {
		unsigned char head[2];
		if (read_exact(fd, head, 2) < 0)
			return -1;

		int fin = head[0] & 0x80;
		int opcode = head[0] & 0x0F;
		int masked = head[1] & 0x80;
		uint64_t len = head[1] & 0x7F;

		if (len == 126) {
			unsigned char ext[2];
			if (read_exact(fd, ext, 2) < 0)
				return -1;
			len = (uint64_t)ext[0] << 8 | ext[1];
		} else if (len == 127) {
			unsigned char ext[8];
			if (read_exact(fd, ext, 8) < 0)
				return -1;
			len = 0;
			for (int i = 0; i < 8; i++)
				len = (len << 8) | ext[i];
		}

		unsigned char mask[4] = { 0 };
		if (masked && read_exact(fd, mask, 4) < 0)
			return -1;

		if (len + 1 > cap)
			return -1;
		if (len > 0 && read_exact(fd, out, len) < 0)
			return -1;
		for (uint64_t i = 0; i < len && masked; i++)
			out[i] ^= (char)mask[i % 4];
		out[len] = '\0';

		if (opcode == 0x9) { /* ping → pong (unmasked payload copy is fine) */
			unsigned char pong[2 + 4] = { 0x8A, 0x80, 0, 0, 0, 0 };
			send_all(fd, pong, sizeof pong);
			continue;
		}
		if (opcode == 0x8) /* close */
			return -1;
		if (opcode == 0x1 || opcode == 0x2) {
			if (!fin) {
				fprintf(stderr, "ember-cdpd: fragmented response, unsupported\n");
				return -1;
			}
			return (ssize_t)len;
		}
		/* anything else (pong, control) is not a message */
	}
}

/* ------------------------------------------------------------------- json */
/* The response is one CDP message; only the value of interest is extracted, so
 * a tiny scan beats a parser that would have to guess at 64-bit tweaks. */
static const char *find_key(const char *json, const char *key)
{
	char pattern[64];
	snprintf(pattern, sizeof pattern, "\"%s\"", key);
	return strstr(json, pattern);
}

static int json_string_after(const char *json, const char *key, char *out, size_t cap);

/* Copies the literal that follows `"key":` — a string unescaped, or the raw
 * token for numbers, booleans and null, which is what Runtime.evaluate returns
 * for anything that is not a string. */
static int json_value_after(const char *json, const char *key, char *out, size_t cap)
{
	const char *p = find_key(json, key);
	if (!p)
		return -1;
	p = strchr(p + strlen(key) + 2, ':');
	if (!p)
		return -1;
	p++;
	while (*p == ' ')
		p++;
	if (*p == '"')
		return json_string_after(json, key, out, cap);

	/* Objects and arrays: scan to the matching bracket so a JSON literal is not
	 * truncated at its first inner brace. */
	if (*p == '{' || *p == '[') {
		int depth = 0, in_string = 0;
		size_t o = 0;
		for (; *p && o + 1 < cap; p++) {
			char c = *p;
			if (in_string) {
				if (c == '\\' && p[1]) {
					out[o++] = c;
					p++;
					out[o++] = *p;
					continue;
				}
				if (c == '"')
					in_string = 0;
			} else if (c == '"') {
				in_string = 1;
			} else if (c == '{' || c == '[') {
				depth++;
			} else if (c == '}' || c == ']') {
				depth--;
				out[o++] = c;
				if (depth == 0)
					break;
				continue;
			}
			out[o++] = c;
		}
		out[o] = '\0';
		return o > 0 ? 0 : -1;
	}

	size_t o = 0;
	while (*p && *p != ',' && *p != '}' && o + 1 < cap)
		out[o++] = *p++;
	while (o > 0 && (out[o - 1] == ' ' || out[o - 1] == '\n'))
		o--;
	out[o] = '\0';
	return o > 0 ? 0 : -1;
}

/* Copies the string literal that follows `"key":`, unescaping \" and \\. */
static int json_string_after(const char *json, const char *key, char *out, size_t cap)
{
	const char *p = find_key(json, key);
	if (!p)
		return -1;
	p = strchr(p + strlen(key) + 2, ':');
	if (!p)
		return -1;
	p++;
	while (*p == ' ')
		p++;
	if (*p != '"')
		return -1;
	p++;
	size_t o = 0;
	while (*p && *p != '"' && o + 1 < cap) {
		if (*p == '\\' && p[1]) {
			p++;
			switch (*p) {
			case 'n': out[o++] = '\n'; break;
			case 't': out[o++] = '\t'; break;
			case 'r': out[o++] = '\r'; break;
			case 'u': /* keep it readable: emit the escape as-is */
				out[o++] = '\\';
				if (o + 1 < cap) out[o++] = 'u';
				break;
			default: out[o++] = *p; break;
			}
			p++;
			continue;
		}
		out[o++] = *p++;
	}
	out[o] = '\0';
	return 0;
}

/* ------------------------------------------------------------------- main */
static char *read_file(const char *path, size_t *len)
{
	FILE *f = fopen(path, "rb");
	if (!f)
		return NULL;
	fseek(f, 0, SEEK_END);
	long size = ftell(f);
	fseek(f, 0, SEEK_SET);
	if (size < 0) {
		fclose(f);
		return NULL;
	}
	char *buf = malloc((size_t)size + 1);
	if (!buf) {
		fclose(f);
		return NULL;
	}
	size_t got = fread(buf, 1, (size_t)size, f);
	buf[got] = '\0';
	fclose(f);
	*len = got;
	return buf;
}

/* JSON-escapes a JS expression so it can be embedded in the CDP request. */
static char *json_escape(const char *in)
{
	size_t cap = strlen(in) * 6 + 1, o = 0;
	char *out = malloc(cap);
	if (!out)
		return NULL;
	for (const unsigned char *p = (const unsigned char *)in; *p; p++) {
		switch (*p) {
		case '"': out[o++] = '\\'; out[o++] = '"'; break;
		case '\\': out[o++] = '\\'; out[o++] = '\\'; break;
		case '\n': out[o++] = '\\'; out[o++] = 'n'; break;
		case '\r': out[o++] = '\\'; out[o++] = 'r'; break;
		case '\t': out[o++] = '\\'; out[o++] = 't'; break;
		default:
			if (*p < 0x20)
				o += (size_t)sprintf(out + o, "\\u%04x", *p);
			else
				out[o++] = (char)*p;
		}
	}
	out[o] = '\0';
	return out;
}

static int usage(void)
{
	fprintf(stderr,
		"usage: ember-cdpd --ws <ws://host:port/devtools/...> (--eval <js> | --eval-file <path>)\n"
		"                 [--timeout-ms <n>] [--raw]\n");
	return 2;
}

int main(int argc, char **argv)
{
	const char *ws = NULL, *expr = NULL, *file = NULL;
	int timeout_ms = 15000, raw = 0;

	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--ws") && i + 1 < argc)
			ws = argv[++i];
		else if (!strcmp(argv[i], "--eval") && i + 1 < argc)
			expr = argv[++i];
		else if (!strcmp(argv[i], "--eval-file") && i + 1 < argc)
			file = argv[++i];
		else if (!strcmp(argv[i], "--timeout-ms") && i + 1 < argc)
			timeout_ms = atoi(argv[++i]);
		else if (!strcmp(argv[i], "--raw"))
			raw = 1;
		else
			return usage();
	}
	if (!ws || (!expr && !file))
		return usage();

	char *owned = NULL;
	if (file) {
		size_t len = 0;
		owned = read_file(file, &len);
		if (!owned) {
			fprintf(stderr, "ember-cdpd: cannot read %s\n", file);
			return 1;
		}
		expr = owned;
	}

	/* ws://host:port/path */
	const char *p = strstr(ws, "://");
	if (!p || strncmp(ws, "ws://", 5) != 0) {
		fprintf(stderr, "ember-cdpd: only ws:// URLs are supported\n");
		return 1;
	}
	p += 3;
	char host[256] = { 0 };
	const char *colon = strchr(p, ':');
	const char *slash = strchr(p, '/');
	if (!colon || (slash && colon > slash)) {
		fprintf(stderr, "ember-cdpd: URL needs an explicit port\n");
		return 1;
	}
	size_t host_len = (size_t)(colon - p);
	if (host_len >= sizeof host)
		return 1;
	memcpy(host, p, host_len);
	int port = atoi(colon + 1);
	const char *path = slash ? slash : "/";

	int fd = tcp_connect(host, port, timeout_ms);
	if (fd < 0) {
		fprintf(stderr, "ember-cdpd: cannot connect to %s:%d\n", host, port);
		return 1;
	}

	/* Handshake: random key, verify Sec-WebSocket-Accept. */
	unsigned char rnd[16];
	if (getentropy(rnd, sizeof rnd) != 0) {
		fprintf(stderr, "ember-cdpd: no entropy for the handshake key\n");
		close(fd);
		return 1;
	}
	char key[32];
	b64_encode(rnd, sizeof rnd, key);

	char request[1024];
	snprintf(request, sizeof request,
		"GET %s HTTP/1.1\r\n"
		"Host: %s:%d\r\n"
		"Upgrade: websocket\r\n"
		"Connection: Upgrade\r\n"
		"Sec-WebSocket-Key: %s\r\n"
		"Sec-WebSocket-Version: 13\r\n"
		"\r\n",
		path, host, port, key);

	if (send_all(fd, request, strlen(request)) != 0) {
		fprintf(stderr, "ember-cdpd: handshake write failed\n");
		close(fd);
		return 1;
	}

	char head[4096];
	if (read_until(fd, head, sizeof head, "\r\n\r\n") < 0 || strstr(head, " 101 ") == NULL) {
		fprintf(stderr, "ember-cdpd: endpoint rejected the upgrade\n");
		close(fd);
		return 1;
	}

	char accept_src[128];
	snprintf(accept_src, sizeof accept_src, "%s258EAFA5-E914-47DA-95CA-C5AB0DC85B11", key);
	sha1_t sha;
	sha1_init(&sha);
	sha1_update(&sha, accept_src, strlen(accept_src));
	unsigned char digest[20];
	sha1_final(&sha, digest);
	char expected[40];
	b64_encode(digest, sizeof digest, expected);

	char *accept = strstr(head, "Sec-WebSocket-Accept:");
	if (!accept) {
		fprintf(stderr, "ember-cdpd: no Sec-WebSocket-Accept in the response\n");
		close(fd);
		return 1;
	}
	accept += strlen("Sec-WebSocket-Accept:");
	while (*accept == ' ')
		accept++;
	if (strncmp(accept, expected, strlen(expected)) != 0) {
		fprintf(stderr, "ember-cdpd: handshake accept mismatch\n");
		close(fd);
		return 1;
	}

	char *escaped = json_escape(expr);
	if (!escaped) {
		close(fd);
		return 1;
	}
	size_t need = strlen(escaped) + 512;
	char *msg = malloc(need);
	if (!msg) {
		free(escaped);
		close(fd);
		return 1;
	}
	snprintf(msg, need,
		"{\"id\":1,\"method\":\"Runtime.evaluate\",\"params\":"
		"{\"expression\":\"%s\",\"returnByValue\":true,\"awaitPromise\":true}}",
		escaped);
	free(escaped);

	int rc = 1;
	if (ws_send_text(fd, msg) != 0) {
		fprintf(stderr, "ember-cdpd: send failed\n");
	} else {
		size_t cap = 1 << 20;
		char *reply = malloc(cap);
		if (!reply) {
			free(msg);
			close(fd);
			return 1;
		}
		for (;;) {
			ssize_t n = ws_read_message(fd, reply, cap);
			if (n < 0) {
				fprintf(stderr, "ember-cdpd: no response\n");
				break;
			}
			if (find_key(reply, "id") && strstr(reply, "\"id\":1")) {
				if (raw) {
					fwrite(reply, 1, (size_t)n, stdout);
					fputc('\n', stdout);
				} else {
					char value[65536];
					if (json_value_after(reply, "value", value, sizeof value) == 0)
						printf("%s\n", value);
					else
						printf("%s\n", reply);
				}
				rc = 0;
				break;
			}
		}
		free(reply);
	}

	free(msg);
	close(fd);
	free(owned);
	return rc;
}
