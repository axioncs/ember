/* ember-cef — enables Steam's CEF remote-debugging endpoint.
 *
 * Why this exists: the store page, settings panels and themes are rendered by
 * steamwebhelper, so anything that changes them needs a DevTools connection to
 * that process. Chromium only opens that port when it is told to on its command
 * line, and the 64-bit Steam client never adds the flag — it has no
 * remote-debugging code at all (checked against the binary: `-cef-*` flags
 * appear, none of them the debugging ones, and the string does not occur).
 *
 * So this is preloaded into the client process and interposes the exec family.
 * When the child is steamwebhelper the flags are appended and the port is
 * published to the CLI; every other exec is passed through untouched.
 *
 * Opt-in: the launcher sets LD_PRELOAD only when EMBER_CEF=1, because it is
 * inherited by everything Steam spawns (games included) and opens a local port
 * that any process on the machine can connect to.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#define HELPER "steamwebhelper"
#define PORT_ENV "EMBER_CEF_PORT"
#define DEFAULT_PORT "8080"

static int base_is_helper(const char *path)
{
	if (!path)
		return 0;
	const char *base = strrchr(path, '/');
	base = base ? base + 1 : path;
	return strncmp(base, HELPER, strlen(HELPER)) == 0;
}

static int already_flagged(char *const argv[])
{
	for (int i = 0; argv && argv[i]; i++)
		if (strstr(argv[i], "--remote-debugging-port") != NULL)
			return 1;
	return 0;
}

static const char *cef_port(void)
{
	const char *port = getenv(PORT_ENV);
	return (port && *port) ? port : DEFAULT_PORT;
}

/* Publishes "<port>\nowner <pid> <startTicks>" the way a self-invalidating
 * contract file should: the tick field (22 of /proc/self/stat) makes a stale
 * file from a previous session detectable, and pid reuse cannot fake it. */
static void publish_contract(const char *port)
{
	const char *home = getenv("HOME");
	if (!home)
		return;

	char dir[4096];
	snprintf(dir, sizeof dir, "%s/.config", home);
	mkdir(dir, 0700);
	snprintf(dir, sizeof dir, "%s/.config/ember", home);
	mkdir(dir, 0700);

	char path[4200];
	snprintf(path, sizeof path, "%s/cef_port", dir);

	unsigned long long ticks = 0;
	if (FILE *stat = fopen("/proc/self/stat", "r")) {
		char buf[4096];
		if (fgets(buf, sizeof buf, stat)) {
			char *close = strrchr(buf, ')');
			if (close) {
				/* fields after the comm field: state is 1, so field 22 is
				 * the 20th token after the closing paren. */
				char *p = close + 1;
				for (int field = 3; field <= 22 && p; field++) {
					while (*p == ' ')
						p++;
					char *end = p;
					while (*end && *end != ' ')
						end++;
					if (field == 22) {
						*end = '\0';
						ticks = strtoull(p, NULL, 10);
						break;
					}
					p = (*end == ' ') ? end + 1 : NULL;
				}
			}
		}
		fclose(stat);
	}

	if (FILE *out = fopen(path, "w")) {
		fprintf(out, "%s\nowner %ld %llu\n", port, (long)getpid(), ticks);
		fclose(out);
	}
}

/* Returns a malloc'd argv with the two flags appended, or NULL to pass through. */
static char **augment(char *const argv[])
{
	size_t count = 0;
	while (argv && argv[count])
		count++;

	static char port_flag[64];
	snprintf(port_flag, sizeof port_flag, "--remote-debugging-port=%s", cef_port());

	char **grown = calloc(count + 3, sizeof(char *));
	if (!grown)
		return NULL;
	for (size_t i = 0; i < count; i++)
		grown[i] = argv[i];
	grown[count] = port_flag;
	grown[count + 1] = "--remote-debugging-address=127.0.0.1";
	grown[count + 2] = NULL;
	return grown;
}

/* Starts the badge agent once per client process. The client is the only process
 * guaranteed to run, so it is also the natural parent: no unit, no wrapper.
 * fork() in a threaded process is only safe for async-signal-safe calls in the
 * child until exec, which is all this does. */
static void start_agent(void)
{
	static int started = 0;
	if (started)
		return;
	const char *agent = getenv("EMBER_AGENT");
	if (!agent || !*agent)
		return;
	started = 1;

	pid_t pid = fork();
	if (pid != 0)
		return; /* parent, or fork failed: the endpoint still works, the badge waits */

	setsid();
	unsetenv("LD_PRELOAD");
	unsetenv("LD_AUDIT");
	execl(agent, agent, "ui", "watch", "--quiet", (char *)NULL);
	_exit(127);
}

static char **rewrite(const char *path, char *const argv[])
{
	if (!base_is_helper(path) || already_flagged(argv))
		return NULL;
	char **grown = augment(argv);
	if (grown) {
		publish_contract(cef_port());
		start_agent();
	}
	return grown;
}

typedef int (*execve_t)(const char *, char *const[], char *const[]);
typedef int (*execv_t)(const char *, char *const[]);
typedef int (*execvp_t)(const char *, char *const[]);

int execve(const char *path, char *const argv[], char *const envp[])
{
	static execve_t real;
	if (!real)
		real = (execve_t)dlsym(RTLD_NEXT, "execve");
	char **grown = rewrite(path, argv);
	return real(path, grown ? grown : argv, envp);
}

int execv(const char *path, char *const argv[])
{
	static execv_t real;
	if (!real)
		real = (execv_t)dlsym(RTLD_NEXT, "execv");
	char **grown = rewrite(path, argv);
	return real(path, grown ? grown : argv);
}

int execvp(const char *file, char *const argv[])
{
	static execvp_t real;
	if (!real)
		real = (execvp_t)dlsym(RTLD_NEXT, "execvp");
	char **grown = rewrite(file, argv);
	return real(file, grown ? grown : argv);
}
