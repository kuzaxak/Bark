// GN's cc_wrapper for Bark's chromium_src overrides. Runs as
//   override_cc COMPILER ARGS...
// from the build directory, two levels below src. Every compile gets
// ../../chromium_src first on its include path, so an override header there
// shadows the upstream one and reaches it with #include_next. When
// ../../chromium_src holds a file at the source's path, that file is compiled
// instead, with the checkout's parent last on the include path so it can
// #include "src/<the upstream path>".

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static const char kRoot[] = "../../";
static const char kOverrides[] = "../../chromium_src/";

int main(int argc, char** argv) {
  if (argc < 2) {
    fputs("override_cc: no compiler given\n", stderr);
    return 2;
  }
  int source = -1;
  for (int i = 2; i + 1 < argc; ++i) {
    if (strcmp(argv[i], "-c") == 0) {
      source = i + 1;
      break;
    }
  }
  if (source < 0) {
    execv(argv[1], argv + 1);
    perror(argv[1]);
    return 127;
  }
  char** args = calloc((size_t)argc + 3, sizeof(char*));
  if (!args) return 127;
  int n = 0;
  args[n++] = argv[1];
  args[n++] = "-I../../chromium_src";
  char* override_path = NULL;
  const char* path = argv[source];
  if (strncmp(path, kRoot, sizeof(kRoot) - 1) == 0) {
    const char* relative = path + sizeof(kRoot) - 1;
    size_t length = sizeof(kOverrides) + strlen(relative);
    override_path = malloc(length);
    if (!override_path) return 127;
    snprintf(override_path, length, "%s%s", kOverrides, relative);
    if (access(override_path, R_OK) != 0) {
      free(override_path);
      override_path = NULL;
    }
  }
  for (int i = 2; i < argc; ++i) {
    args[n++] = (i == source && override_path) ? override_path : argv[i];
  }
  if (override_path) args[n++] = "-I../../..";
  execv(args[0], args);
  perror(args[0]);
  return 127;
}
