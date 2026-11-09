"""pihx: runs instances made of self-contained services, from one tools directory, in a pinned container.

Runs only in the pihx-runtime image (bin/pihx, test/run): standard library plus PyYAML, and pip only
in the image's Dockerfile, pinned.
See CLAUDE.md and docs/development.md#dependencies before adding an import."""

__version__ = "0.1.0"
