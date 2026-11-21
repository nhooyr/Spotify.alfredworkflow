// The Alfred hotkey runs this small POSIX client, without loading the AppKit
// host.
#include "Bridge.h"
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

extern char **environ;
static const char *command = "show";
static char directory[PATH_MAX],
    endpoint[sizeof(((struct sockaddr_un *)0)->sun_path)];

static int append(char **end, size_t *remaining, const char *value) {
  size_t length = strlen(value);
  if (length >= *remaining)
    return -1;
  memcpy(*end, value, length + 1);
  *end += length;
  *remaining -= length;
  return 0;
}

static int json_string(char **end, size_t *remaining, const char *value) {
  if (append(end, remaining, "\""))
    return -1;
  for (const unsigned char *p = (const unsigned char *)value; *p; p++) {
    char escaped[7] = {0};
    if (*p == '"' || *p == '\\') {
      escaped[0] = '\\';
      escaped[1] = (char)*p;
    } else if (*p < 0x20)
      snprintf(escaped, sizeof(escaped), "\\u%04x", *p);
    else
      escaped[0] = (char)*p;
    if (append(end, remaining, escaped))
      return -1;
  }
  return append(end, remaining, "\"");
}

// 0 = ready, 1 = old build is exiting, -1 = no server.
static int send_command(void) {
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0)
    return -1;
  fcntl(fd, F_SETFD, FD_CLOEXEC);
  int enabled = 1;
  setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled));
  struct timeval timeout = {.tv_sec = 2};
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
  struct sockaddr_un address = {.sun_family = AF_UNIX};
  address.sun_len = sizeof(address);
  strlcpy(address.sun_path, endpoint, sizeof(address.sun_path));
  if (connect(fd, (struct sockaddr *)&address, sizeof(address)) < 0) {
    close(fd);
    return -1;
  }
  char packet[16384], *end = packet;
  size_t remaining = sizeof(packet);
  if (append(&end, &remaining, "{\"command\":") ||
      json_string(&end, &remaining, command) ||
      append(&end, &remaining, ",\"build\":\"" BUILD_ID "\",\"theme\":{")) {
    close(fd);
    return -1;
  }
  const char *keys[] = {"id", "background", "selection", "preferences",
                        "localhash"};
  const char *names[] = {"alfred_theme", "alfred_theme_background",
                         "alfred_theme_selection_background",
                         "alfred_preferences", "alfred_preferences_localhash"};
  int first = 1;
  for (size_t i = 0; i < sizeof(keys) / sizeof(*keys); i++) {
    const char *value = getenv(names[i]);
    if (!value || !*value)
      continue;
    if ((!first && append(&end, &remaining, ",")) ||
        json_string(&end, &remaining, keys[i]) ||
        append(&end, &remaining, ":") || json_string(&end, &remaining, value)) {
      close(fd);
      return -1;
    }
    first = 0;
  }
  if (append(&end, &remaining, "}}\n")) {
    close(fd);
    return -1;
  }
  const char *message = packet;
  size_t left = strlen(message);
  while (left) {
    ssize_t count = write(fd, message, left);
    if (count <= 0) {
      close(fd);
      return -1;
    }
    message += count;
    left -= count;
  }
  char response[2048];
  size_t used = 0;
  while (used < sizeof(response) - 1) {
    ssize_t count = read(fd, response + used, sizeof(response) - used - 1);
    if (count <= 0)
      break;
    used += count;
    if (memchr(response, '\n', used))
      break;
  }
  response[used] = 0;
  close(fd);
  return strstr(response, "\"status\":\"ok\"") ? 0
         : strstr(response, "\"restart\"")     ? 1
                                               : -1;
}

static int launch(void) {
  char executable[PATH_MAX], resolved[PATH_MAX], host[PATH_MAX];
  uint32_t length = sizeof(executable);
  if (_NSGetExecutablePath(executable, &length) != 0 ||
      !realpath(executable, resolved))
    return -1;
  char *slash = strrchr(resolved, '/');
  if (!slash)
    return -1;
  *slash = 0;
  if (snprintf(host, sizeof(host),
               "%s/Spotify Mini Player.app/Contents/MacOS/SpotifyMiniPlayer",
               resolved) >= (int)sizeof(host))
    return -1;
  posix_spawn_file_actions_t actions;
  posix_spawn_file_actions_init(&actions);
  posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null",
                                   O_RDONLY, 0);
  posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null",
                                   O_WRONLY, 0);
  posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null",
                                   O_WRONLY, 0);
  char *argv[] = {host, "--serve", NULL};
  pid_t pid;
  int result = posix_spawn(&pid, host, &actions, NULL, argv, environ);
  posix_spawn_file_actions_destroy(&actions);
  return result;
}

int main(int argc, char **argv) {
  if (argc > 1) {
    const char *choices[] = {"hotkey",    "like",       "unlike", "shuffle",
                             "noshuffle", "screenshot", "refresh"};
    int found = 0;
    for (size_t i = 0; i < sizeof(choices) / sizeof(*choices); i++) {
      if (strncmp(argv[1], "--", 2) == 0 &&
          strcmp(argv[1] + 2, choices[i]) == 0) {
        command = choices[i];
        found = 1;
        break;
      }
    }
    if (!found || argc != 2) {
      fputs("Unknown Spotify command.\n", stderr);
      return 1;
    }
  }
  const char *override = getenv("SPOTIFY_NATIVE_SOCKET_DIR");
  if (override)
    strlcpy(directory, override, sizeof(directory));
  else
    snprintf(directory, sizeof(directory), "/tmp/spotify-alfred-%u", getuid());
  if (snprintf(endpoint, sizeof(endpoint), "%s/player.sock", directory) >=
      (int)sizeof(endpoint))
    return 1;
  if (send_command() == 0)
    return 0;
  if (mkdir(directory, 0700) && errno != EEXIST)
    return 1;
  struct stat stat;
  if (lstat(directory, &stat) || !S_ISDIR(stat.st_mode) ||
      stat.st_uid != getuid())
    return 1;
  if (chmod(directory, 0700))
    return 1;
  char lock_path[PATH_MAX];
  if (snprintf(lock_path, sizeof(lock_path), "%s/launch.lock", directory) >=
      (int)sizeof(lock_path))
    return 1;
  int lock = open(lock_path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0600);
  if (lock < 0 || flock(lock, LOCK_EX))
    return 1;
  int state = send_command();
  if (state == 0) {
    close(lock);
    return 0;
  }
  for (int i = 0; state == 1 && i < 100; i++) {
    usleep(10000);
    state = send_command();
  }
  if (state != 0 && launch() != 0) {
    close(lock);
    return 1;
  }
  for (int i = 0; state != 0 && i < 300; i++) {
    usleep(10000);
    state = send_command();
  }
  close(lock);
  if (state == 0)
    return 0;
  fputs("Spotify Mini Player could not start. Reimport the workflow and try "
        "again.\n",
        stderr);
  return 1;
}
