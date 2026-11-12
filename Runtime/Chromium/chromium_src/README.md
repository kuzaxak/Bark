# Overrides

A file here at `<upstream path>` is compiled in place of upstream's `<upstream path>`, through
the redirect tool `../README.md` describes.

- A header override reaches upstream's header with `#include_next`.
- A source override includes upstream's file as `src/<upstream path>`, renaming the upstream
  symbol it replaces, so an upstream rename fails to compile.
- Adding or removing an override changes no compile command: touch the upstream file it
  covers, or the build keeps the old object.
- `budget.py` counts every file here but this one as an override file.
