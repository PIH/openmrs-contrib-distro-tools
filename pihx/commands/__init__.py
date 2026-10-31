"""pihx's commands."""


class CliError(Exception):
    """An error to report as `error: <message>` with a non-zero status."""

    def __init__(self, message, status=1):
        super().__init__(message)
        self.status = status
